$ErrorActionPreference = "SilentlyContinue"
$taskName = "Codex Usage HUD Watcher"
$startupShortcut = Join-Path ([Environment]::GetFolderPath("Startup")) "Codex Usage HUD Watcher.lnk"

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false | Out-Null
Remove-Item -LiteralPath $startupShortcut -Force

$rows = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object {
  $_.CommandLine -like "*Start-CodexUsageHudWatcher.ps1*"
})
foreach ($row in $rows) {
  Stop-Process -Id $row.ProcessId -Force
}

Write-Host "Uninstalled Codex Usage HUD autostart."