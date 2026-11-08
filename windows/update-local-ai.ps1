# LocalAIBar: update of the control service (GET/POST /config, --parallel 1, -ub 256)
$ErrorActionPreference = 'Stop'
$dir = 'D:\Ai\scripts'
$pidFile = 'D:\Ai\llama.pid'
$wasRunning = $false
if (Test-Path $pidFile) {
    $p = Get-Process -Id ([int](Get-Content $pidFile -Raw)) -ErrorAction SilentlyContinue
    $wasRunning = [bool]($p -and $p.ProcessName -like 'llama-server*')
}
foreach ($f in 'model-lib.ps1', 'control-server.ps1') { Copy-Item "$dir\$f" "$dir\$f.bak" -Force }
Stop-ScheduledTask -TaskName 'LocalAI-Control' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

Set-Content -Encoding UTF8 "$dir\model-lib.ps1" -Value @'
$script:Root = Split-Path $PSScriptRoot -Parent
$script:CfgPath = "$script:Root\config.json"
$script:PidFile = "$script:Root\llama.pid"
$script:LogDir = "$script:Root\logs"

# Re-read config.json from disk (called before every model start, so edits apply without a reboot).
function Read-Config {
    $script:Cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Write $script:Cfg back to config.json: UTF-8 without BOM, all fields kept, via a temp file.
function Save-Config {
    $json = $script:Cfg | ConvertTo-Json -Depth 10
    $tmp = "$script:CfgPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -Force $tmp $script:CfgPath
}

function Set-ConfigValue([string]$name, $value) {
    if ($script:Cfg.PSObject.Properties[$name]) { $script:Cfg.$name = $value }
    else { $script:Cfg | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# Optional config field with a default.
function Get-ConfigValue([string]$name, $default) {
    if ($script:Cfg.PSObject.Properties[$name] -and $null -ne $script:Cfg.$name) { return $script:Cfg.$name }
    return $default
}

Read-Config

function Get-LlamaProcess {
    if (-not (Test-Path $script:PidFile)) { return $null }
    $id = [int](Get-Content $script:PidFile -Raw)
    $p = Get-Process -Id $id -ErrorAction SilentlyContinue
    if ($p -and $p.ProcessName -like 'llama-server*') { return $p }
    return $null
}

function Start-Model {
    if (Get-LlamaProcess) { return }
    Read-Config
    New-Item -ItemType Directory -Force $script:LogDir | Out-Null
    $c = $script:Cfg
    $llamaArgs = @(
        '-m', "`"$($c.modelPath)`"",
        '--host', '0.0.0.0',
        '--port', $c.llamaPort,
        '-c', $c.ctx,
        '-ngl', $c.ngl,
        '--parallel', (Get-ConfigValue 'parallel' 1),
        '-ub', (Get-ConfigValue 'ubatch' 256),
        '--jinja',
        '--api-key', $c.token
    )
    $p = Start-Process -FilePath $c.llamaServerPath -ArgumentList $llamaArgs -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput "$script:LogDir\llama.out.log" -RedirectStandardError "$script:LogDir\llama.err.log"
    Set-Content $script:PidFile $p.Id
}

function Stop-Model {
    $p = Get-LlamaProcess
    if ($p) {
        Stop-Process -Id $p.Id -Force
        # Wait until it is gone so the port and GPU memory are free before a restart.
        $p.WaitForExit(15000) | Out-Null
    }
    Remove-Item $script:PidFile -ErrorAction SilentlyContinue
}

# stopped | loading | running
function Get-ModelStatus {
    if (-not (Get-LlamaProcess)) { return 'stopped' }
    try {
        $r = Invoke-WebRequest "http://127.0.0.1:$($script:Cfg.llamaPort)/health" -UseBasicParsing -TimeoutSec 2
        if ($r.StatusCode -eq 200) { return 'running' }
    } catch {}
    return 'loading'
}
'@

Set-Content -Encoding UTF8 "$dir\control-server.ps1" -Value @'
. "$PSScriptRoot\model-lib.ps1"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add("http://+:$($script:Cfg.controlPort)/")
$listener.Start()

$script:MinCtx = 2048
$script:MaxCtx = 262144

function Send-Json($res, [int]$code, $obj) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Compress))
    $res.StatusCode = $code
    $res.ContentType = 'application/json; charset=utf-8'
    $res.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Read-JsonBody($req) {
    $reader = [IO.StreamReader]::new($req.InputStream, [Text.Encoding]::UTF8)
    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    try { return $text | ConvertFrom-Json } catch { return $null }
}

# Launch settings without the token.
function Get-PublicConfig {
    $c = $script:Cfg
    @{
        ctx      = [int]$c.ctx
        ngl      = [int]$c.ngl
        parallel = [int](Get-ConfigValue 'parallel' 1)
        ubatch   = [int](Get-ConfigValue 'ubatch' 256)
        model    = [IO.Path]::GetFileName($c.modelPath)
    }
}

function Set-Context($res, $body) {
    $n = 0
    if ($null -eq $body -or -not [int]::TryParse("$($body.ctx)", [ref]$n)) {
        Send-Json $res 400 @{ error = 'ctx must be an integer' }; return
    }
    if ($n -lt $script:MinCtx -or $n -gt $script:MaxCtx) {
        Send-Json $res 400 @{ error = "ctx must be between $($script:MinCtx) and $($script:MaxCtx)" }; return
    }
    Read-Config
    Set-ConfigValue 'ctx' $n
    Save-Config
    # Restart only if the model is on; a stopped model picks the value up on the next start.
    $restarted = $false
    if (Get-LlamaProcess) {
        Stop-Model
        Start-Model
        $restarted = $true
    }
    Send-Json $res 200 @{ status = (Get-ModelStatus); ctx = $n; restarted = $restarted }
}

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response
    try {
        $res.Headers.Add('Access-Control-Allow-Origin', '*')
        $res.Headers.Add('Access-Control-Allow-Headers', 'Authorization, Content-Type')
        $res.Headers.Add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS')
        $res.Headers.Add('Access-Control-Allow-Private-Network', 'true')

        if ($req.HttpMethod -eq 'OPTIONS') { $res.StatusCode = 204; continue }

        if ($req.Headers['Authorization'] -ne "Bearer $($script:Cfg.token)") {
            Send-Json $res 401 @{ error = 'unauthorized' }; continue
        }

        switch ($req.Url.AbsolutePath) {
            '/start'  { Start-Model; Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/stop'   { Stop-Model;  Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/status' { Send-Json $res 200 @{ status = (Get-ModelStatus) } }
            '/config' {
                if ($req.HttpMethod -eq 'POST') { Set-Context $res (Read-JsonBody $req) }
                else { Read-Config; Send-Json $res 200 (Get-PublicConfig) }
            }
            default   { Send-Json $res 404 @{ error = 'not found' } }
        }
    } catch {
        try { Send-Json $res 500 @{ error = $_.Exception.Message } } catch {}
    } finally {
        $res.Close()
    }
}
'@

. "$dir\model-lib.ps1"
if ($wasRunning) { Stop-Model; Start-Model; Write-Host 'Model restarted with the new flags.' }
Start-ScheduledTask -TaskName 'LocalAI-Control'
Start-Sleep -Seconds 3
$h = @{ Authorization = "Bearer $($script:Cfg.token)" }
$r = Invoke-RestMethod "http://127.0.0.1:$($script:Cfg.controlPort)/config" -Headers $h
Write-Host "OK: control service updated. ctx=$($r.ctx) ngl=$($r.ngl) parallel=$($r.parallel) ubatch=$($r.ubatch)"
Write-Host "Backups: $dir\model-lib.ps1.bak, $dir\control-server.ps1.bak"
