# LocalAIBar: updates the control service on a Windows PC to the latest version (scripts from github.com/DeMoZ/local-ai-bar).
# Run in PowerShell on the PC, preferably "Run as Administrator":
#   irm https://raw.githubusercontent.com/DeMoZ/local-ai-bar/main/server/update-windows.ps1 | iex
# A specific version: set $env:LOCALAI_REF = 'v0.4.0' first. Old scripts are kept as *.bak.
$ErrorActionPreference = 'Stop'
$ref = if ($env:LOCALAI_REF) { $env:LOCALAI_REF } else { 'main' }
$base = "https://raw.githubusercontent.com/DeMoZ/local-ai-bar/$ref/server/scripts"
# The installed scripts folder: from the LocalAI-Control task's -File argument, else D:\Ai\scripts.
$task = Get-ScheduledTask -TaskName 'LocalAI-Control' -ErrorAction SilentlyContinue
if (-not $task) { throw 'Scheduled task LocalAI-Control not found: this updates an installed service (see docs/models.md for a new install).' }
$dir = if ("$($task.Actions[0].Arguments)" -match '-File\s+"?([^"]+\.ps1)') { Split-Path $Matches[1] -Parent } else { 'D:\Ai\scripts' }
$files = 'model-lib.ps1', 'control-server.ps1'

# Download and syntax-check everything before touching the installed scripts.
$new = @{}
foreach ($f in $files) {
    $text = (Invoke-WebRequest "$base/$f" -UseBasicParsing).Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    $errs = $null
    [void][Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errs)
    if ($errs) { throw "$f from $ref does not parse: $($errs[0].Message)" }
    $new[$f] = $text
}

$wasRunning = [bool](Get-Process -Name 'llama-server' -ErrorAction SilentlyContinue)
Stop-ScheduledTask -TaskName 'LocalAI-Control' -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1
foreach ($f in $files) {
    if (Test-Path "$dir\$f") { Copy-Item "$dir\$f" "$dir\$f.bak" -Force }
    [IO.File]::WriteAllText("$dir\$f", $new[$f], [Text.UTF8Encoding]::new($true))
}

. "$dir\model-lib.ps1"
# Stop every llama-server here; the model is started again by the service itself (its own user and rights),
# never from this window, so the service can always stop it later.
try { Stop-Model } catch { Write-Warning "$_ Run this script from an Administrator PowerShell window, or reboot the PC." }
Start-ScheduledTask -TaskName 'LocalAI-Control'
Start-Sleep -Seconds 3
$h = @{ Authorization = "Bearer $($script:Cfg.token)" }
$api = "http://127.0.0.1:$($script:Cfg.controlPort)"
if ($wasRunning) { Invoke-RestMethod "$api/start" -Method Post -Headers $h | Out-Null; Write-Host 'Model started by the service.' }
$r = Invoke-RestMethod "$api/config" -Headers $h
$m = Invoke-RestMethod "$api/models" -Headers $h
Write-Host "OK: control service updated from $ref. ctx=$($r.ctx) model=$($r.model) autoRestart=$($r.autoRestart)"
Write-Host "Models found in $($m.modelsDir): $(@($m.models).Count)"
Write-Host "Backups: $dir\*.ps1.bak"
