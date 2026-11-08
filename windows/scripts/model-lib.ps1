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
