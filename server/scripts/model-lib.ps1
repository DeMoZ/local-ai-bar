$script:Root = Split-Path $PSScriptRoot -Parent
# Runs in Windows PowerShell 5.1 (the PC) and in PowerShell 7 on macOS / Linux (models on the same Mac).
$script:OnWindows = [IO.Path]::DirectorySeparatorChar -eq '\'
$script:CfgPath = Join-Path $script:Root 'config.json'
$script:PidFile = Join-Path $script:Root 'llama.pid'
$script:LogDir = Join-Path $script:Root 'logs'
$script:Proc = $null          # the llama-server we started (keeps its exit code after a crash)
$script:LastCrash = $null     # @{ at; exitCode; count; restarted } of the last unexpected exit
$script:CrashTimes = @()      # recent crash times, to stop auto-restarting a model that keeps crashing

# Re-read config.json from disk (called before every model start, so edits apply without a reboot).
function Read-Config {
    $script:Cfg = Get-Content $script:CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

# Write $script:Cfg back to config.json: UTF-8 without BOM, all fields kept, via a temp file.
function Save-Config {
    $json = $script:Cfg | ConvertTo-Json -Depth 10
    $tmp = "$script:CfgPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))
    Move-Item -Force $tmp $script:CfgPath -ErrorAction Stop
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

# ---------------------------------------------------------------- models
# Layout (docs/models.md): <modelsDir>\<folder>\<model>.gguf, optionally with mmproj-*.gguf (image input) and
# localai.json (per-model settings) next to it. Files straight in <modelsDir> work too, without companions.

function Get-ModelsDir { [IO.Path]::GetFullPath((Get-ConfigValue 'modelsDir' (Join-Path $script:Root 'models'))).TrimEnd('\', '/') }

# Model id: the path relative to <modelsDir> with "/" separators, or $null for a file outside it.
function Get-ModelId([string]$path) {
    $dir = Get-ModelsDir
    $full = [IO.Path]::GetFullPath($path)
    if (-not $full.StartsWith($dir + [IO.Path]::DirectorySeparatorChar, 'OrdinalIgnoreCase')) { return $null }
    return $full.Substring($dir.Length + 1).Replace('\', '/')
}

function Read-ModelSettings([string]$folder) {
    $f = Join-Path $folder 'localai.json'
    if (-not (Test-Path $f)) { return $null }
    try { return Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-SettingValue($settings, [string]$name) {
    if ($settings -and $settings.PSObject.Properties[$name]) { return $settings.$name }
    return $null
}

# The mmproj file for a model: localai.json "mmproj" (file name, or false to turn it off), else the only
# mmproj*.gguf in the model's own folder. Never guessed for files lying straight in <modelsDir>.
function Find-Mmproj([string]$modelPath) {
    $folder = Split-Path $modelPath -Parent
    $s = Read-ModelSettings $folder
    $m = Get-SettingValue $s 'mmproj'
    if ($m -is [bool] -and -not $m) { return $null }
    if ($m -is [string] -and $m) {
        $p = Join-Path $folder $m
        if (Test-Path $p) { return $p }
        return $null
    }
    if ($folder.TrimEnd('\', '/') -ieq (Get-ModelsDir)) { return $null }
    $c = @(Get-ChildItem $folder -Filter 'mmproj*.gguf' -File -ErrorAction SilentlyContinue)
    if ($c.Count -eq 1) { return $c[0].FullName }
    return $null
}

# Every model in <modelsDir>: mmproj files and the 2nd..Nth parts of split models are not separate models.
function Get-Models {
    $dir = Get-ModelsDir
    if (-not (Test-Path $dir)) { return @() }
    $current = [IO.Path]::GetFullPath($script:Cfg.modelPath)
    $out = @()
    foreach ($f in Get-ChildItem $dir -Filter '*.gguf' -File -Recurse -ErrorAction SilentlyContinue) {
        if ($f.Name -like 'mmproj*') { continue }
        $size = $f.Length
        $base = $f.BaseName
        if ($f.Name -match '^(.*)-(\d{5})-of-(\d{5})\.gguf$') {
            if ($Matches[2] -ne '00001') { continue }
            $prefix = $Matches[1]
            $base = $prefix
            $size = (Get-ChildItem $f.DirectoryName -Filter "$prefix-*-of-$($Matches[3]).gguf" -File |
                Measure-Object Length -Sum).Sum
        }
        $s = Read-ModelSettings $f.DirectoryName
        $name = Get-SettingValue $s 'name'
        $out += [ordered]@{
            id        = (Get-ModelId $f.FullName)
            name      = $(if ($name) { "$name" } else { $base })
            sizeBytes = [int64]$size
            vision    = [bool](Find-Mmproj $f.FullName)
            current   = ($f.FullName -ieq $current)
        }
    }
    return $out
}

# Full path of a model id from Get-Models, or $null if it is not one of them (no paths outside <modelsDir>).
function Resolve-ModelId([string]$id) {
    foreach ($m in Get-Models) {
        if ($m.id -eq $id) { return [IO.Path]::Combine((Get-ModelsDir), $id.Replace('/', [IO.Path]::DirectorySeparatorChar)) }
    }
    return $null
}

# Switch config.json to another model; its localai.json ctx / ngl / parallel / ubatch become the settings.
function Set-Model([string]$path) {
    Set-ConfigValue 'modelPath' $path
    $s = Read-ModelSettings (Split-Path $path -Parent)
    foreach ($k in 'ctx', 'ngl', 'parallel', 'ubatch') {
        $v = Get-SettingValue $s $k
        if ($null -ne $v) { Set-ConfigValue $k ([int]$v) }
    }
}

# ---------------------------------------------------------------- llama-server process

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
    if (Get-ConfigValue 'mmproj' $true) {
        $mm = Find-Mmproj $c.modelPath
        if ($mm) { $llamaArgs += @('--mmproj', "`"$mm`"") }
    }
    $extra = Get-SettingValue (Read-ModelSettings (Split-Path $c.modelPath -Parent)) 'extraArgs'
    if ($extra) { $llamaArgs += @($extra | ForEach-Object { "$_" }) }
    $run = @{
        FilePath = $c.llamaServerPath; ArgumentList = $llamaArgs; PassThru = $true
        RedirectStandardOutput = (Join-Path $script:LogDir 'llama.out.log')
        RedirectStandardError  = (Join-Path $script:LogDir 'llama.err.log')
    }
    if ($script:OnWindows) { $run.WindowStyle = 'Hidden' }
    $p = Start-Process @run
    Set-Content $script:PidFile $p.Id
    $script:Proc = $p
    # A bad flag or a busy port makes llama-server exit at once; report it instead of claiming success.
    Start-Sleep -Seconds 2
    if ($p.HasExited) {
        Remove-Item $script:PidFile -ErrorAction SilentlyContinue
        throw "llama-server exited at start (code $($p.ExitCode)), see $(Join-Path $script:LogDir 'llama.err.log')"
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

# ---------------------------------------------------------------- crash watchdog

# Called every few seconds. llama.pid without its process means llama-server exited without Stop-Model:
# a crash. It is recorded (GET /status "crash", logs\crashes.log) and, with "autoRestart": true in config.json,
# the model is started again — at most 3 times in 10 minutes, so a model that cannot run does not loop.
function Test-ModelCrash {
    if (-not (Test-Path $script:PidFile) -or (Get-LlamaProcess)) { return }
    $id = [int](Get-Content $script:PidFile -Raw)
    Remove-Item $script:PidFile -ErrorAction SilentlyContinue
    $code = $null
    if ($script:Proc -and $script:Proc.Id -eq $id -and $script:Proc.HasExited) { $code = $script:Proc.ExitCode }
    $now = Get-Date
    $script:CrashTimes = @($script:CrashTimes | Where-Object { ($now - $_).TotalMinutes -lt 10 }) + $now
    $count = if ($script:LastCrash) { $script:LastCrash.count + 1 } else { 1 }
    $script:LastCrash = [ordered]@{ at = $now.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'"); exitCode = $code; count = $count; restarted = $false }
    New-Item -ItemType Directory -Force $script:LogDir | Out-Null
    Add-Content (Join-Path $script:LogDir 'crashes.log') "$($now.ToString('s')) llama-server exited, code $code"
    Read-Config
    if ((Get-ConfigValue 'autoRestart' $false) -and $script:CrashTimes.Count -le 3) {
        try { Start-Model; $script:LastCrash.restarted = $true }
        catch { Add-Content (Join-Path $script:LogDir 'crashes.log') "$($now.ToString('s')) restart failed: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------- PC load

$script:MetricsCache = $null
$script:MetricsAt = [datetime]::MinValue

# RAM, CPU, GPU load and GPU memory of the PC, cached for 5 s (performance counters take about a second).
# Fields the PC cannot report are null.
function Get-PcMetrics {
    if ($script:MetricsCache -and ((Get-Date) - $script:MetricsAt).TotalSeconds -lt 5) { return $script:MetricsCache }
    $m = [ordered]@{ cpu = $null; gpu = $null; ramTotal = $null; ramUsed = $null
                     gpuDedicated = $null; gpuShared = $null; llamaRam = $null }
    if (-not $script:OnWindows) { return (Get-UnixMetrics $m) }
    try {
        $os = Get-CimInstance Win32_OperatingSystem
        $m.ramTotal = [int64]$os.TotalVisibleMemorySize * 1024
        $m.ramUsed = ([int64]$os.TotalVisibleMemorySize - [int64]$os.FreePhysicalMemory) * 1024
    } catch {}
    try {
        $samples = (Get-Counter -ErrorAction SilentlyContinue -Counter @(
            '\Processor(_Total)\% Processor Time',
            '\GPU Engine(*)\Utilization Percentage',
            '\GPU Adapter Memory(*)\Dedicated Usage',
            '\GPU Adapter Memory(*)\Shared Usage')).CounterSamples
        $cpu = $samples | Where-Object { $_.Path -like '*\processor(_total)\*' }
        if ($cpu) { $m.cpu = [math]::Round($cpu[0].CookedValue, 1) }
        # GPU load: the busiest engine type (3D, Compute, ...), summed over its engines.
        $eng = $samples | Where-Object { $_.Path -like '*\gpu engine(*' -and $_.InstanceName -match 'engtype_(\w+)' } |
            Group-Object { ($_.InstanceName -split 'engtype_')[1] } |
            ForEach-Object { ($_.Group | Measure-Object CookedValue -Sum).Sum }
        if ($eng) { $m.gpu = [math]::Round([math]::Min(100, ($eng | Measure-Object -Maximum).Maximum), 1) }
        $ded = $samples | Where-Object { $_.Path -like '*\dedicated usage' }
        if ($ded) { $m.gpuDedicated = [int64]($ded | Measure-Object CookedValue -Sum).Sum }
        $sh = $samples | Where-Object { $_.Path -like '*\shared usage' }
        if ($sh) { $m.gpuShared = [int64]($sh | Measure-Object CookedValue -Sum).Sum }
    } catch {}
    $p = Get-LlamaProcess
    if ($p) { $m.llamaRam = [int64]$p.WorkingSet64 }
    $script:MetricsCache = $m
    $script:MetricsAt = Get-Date
    return $m
}

# macOS: RAM from sysctl / vm_stat, CPU from ps; GPU memory is the same RAM (unified), so no GPU fields.
function Get-UnixMetrics($m) {
    try {
        $m.ramTotal = [int64](sysctl -n hw.memsize)
        $vm = vm_stat
        $page = [int64](($vm[0] -replace '\D+(\d+).*', '$1'))
        $pages = 0
        foreach ($k in 'Pages active', 'Pages wired down', 'Pages occupied by compressor') {
            $line = $vm | Where-Object { $_ -like "$k*" }
            if ($line) { $pages += [int64](($line -split ':')[1].Trim().TrimEnd('.')) }
        }
        $m.ramUsed = $pages * $page
        $cores = [int](sysctl -n hw.ncpu)
        $sum = (ps -A -o %cpu= | ForEach-Object { [double]($_.Trim() -replace ',', '.') } | Measure-Object -Sum).Sum
        $m.cpu = [math]::Round([math]::Min(100, $sum / $cores), 1)
    } catch {}
    $p = Get-LlamaProcess
    if ($p) { $m.llamaRam = [int64]$p.WorkingSet64 }
    $script:MetricsCache = $m
    $script:MetricsAt = Get-Date
    return $m
}
