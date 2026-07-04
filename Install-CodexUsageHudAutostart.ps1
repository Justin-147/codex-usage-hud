param(
  [switch]$StartNow
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$watcher = Join-Path $root "Start-CodexUsageHudWatcher.ps1"
$taskName = "Codex Usage HUD Watcher"
$powershell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Usage HUD Watcher.lnk"
$watcherArgs = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $watcher + '"'

if (-not (Test-Path -LiteralPath $watcher)) {
  throw "Watcher script was not found: $watcher"
}

$installed = $false
try {
  $action = New-ScheduledTaskAction -Execute $powershell -Argument $watcherArgs -WorkingDirectory $root
  $trigger = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Days 3650)

  Register-ScheduledTask `
    -TaskName $taskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Description "Starts the Codex usage HUD when Codex is detected." `
    -Force | Out-Null
  $installed = $true
  Write-Host "Installed scheduled task: $taskName"
} catch {
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($startupShortcut)
  $shortcut.TargetPath = $powershell
  $shortcut.Arguments = $watcherArgs
  $shortcut.WorkingDirectory = $root
  $shortcut.WindowStyle = 7
  $shortcut.Description = "Starts the Codex usage HUD when Codex is detected."
  $shortcut.Save()
  $installed = $true
  Write-Host "Installed startup shortcut: $startupShortcut"
}

if ($StartNow) {
  Start-Process -FilePath $powershell `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $watcher) `
    -WorkingDirectory $root `
    -WindowStyle Hidden | Out-Null
}

if (-not $installed) { throw "Autostart was not installed." }