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
