# LocalAIBar: update of the control service (GET/POST /config, --parallel 1, -ub 256)
$ErrorActionPreference = 'Stop'
$dir = 'D:\Ai\scripts'
$pidFile = 'D:\Ai\llama.pid'
$wasRunning = [bool](Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
if (([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Note: this window runs as Administrator; that is fine, the model is started by the service.'
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
    # A bad flag or a busy port makes llama-server exit at once; report it instead of claiming success.
    Start-Sleep -Seconds 2
    if ($p.HasExited) {
        Remove-Item $script:PidFile -ErrorAction SilentlyContinue
        throw "llama-server exited at start (code $($p.ExitCode)), see $script:LogDir\llama.err.log"
    }
}

# Stops the llama-server from llama.pid and any stray llama-server.exe (e.g. one started from another window),
# and fails loudly if one cannot be stopped (another user or an elevated window) instead of starting a second one.
function Stop-Model {
    $procs = @(Get-LlamaProcess) + @(Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue) |
        Where-Object { $_ } | Sort-Object Id -Unique
    foreach ($p in $procs) {
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop }
        catch { throw "cannot stop llama-server (PID $($p.Id)): $($_.Exception.Message). Was it started from an Administrator window? Stop it there or reboot." }
    }
    foreach ($p in $procs) {
        # Wait until it is gone so the port and GPU memory are free before a restart.
        if (-not $p.WaitForExit(15000)) { throw "llama-server (PID $($p.Id)) did not exit in 15 s" }
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
# Stop every llama-server here; the model is started again by the service itself (its own user and rights),
# never from this window, so the service can always stop it later.
try { Stop-Model } catch { Write-Warning "$_ Run this script from an Administrator PowerShell window, or reboot the PC." }
Start-ScheduledTask -TaskName 'LocalAI-Control'
Start-Sleep -Seconds 3
$h = @{ Authorization = "Bearer $($script:Cfg.token)" }
$base = "http://127.0.0.1:$($script:Cfg.controlPort)"
if ($wasRunning) { Invoke-RestMethod "$base/start" -Method Post -Headers $h | Out-Null; Write-Host 'Model started by the service.' }
$r = Invoke-RestMethod "$base/config" -Headers $h
Write-Host "OK: control service updated. ctx=$($r.ctx) ngl=$($r.ngl) parallel=$($r.parallel) ubatch=$($r.ubatch)"
Write-Host "Backups: $dir\model-lib.ps1.bak, $dir\control-server.ps1.bak"
