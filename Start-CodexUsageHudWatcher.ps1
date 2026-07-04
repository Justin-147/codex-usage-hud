param(
  [int]$PollSeconds = 5,
  [string]$HudScript = ""
)

$ErrorActionPreference = "SilentlyContinue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $HudScript) { $HudScript = Join-Path $root "Start-CodexUsageHud.ps1" }

function Get-ProcessRows {
  param([string]$Filter)
  try { return @(Get-CimInstance Win32_Process -Filter $Filter) } catch { return @() }
}

function Test-CodexRunning {
  $rows = Get-ProcessRows "Name='codex.exe' OR Name='Codex.exe'"
  foreach ($row in $rows) {
    $cmd = [string]$row.CommandLine
    if ($cmd -match "\bapp-server\b") { continue }
    if ($cmd -like "*OpenAI*Codex*" -or $cmd -like "*\Codex\*") { return $true }
  }

  $desktopRows = Get-ProcessRows "Name='OpenAI.Codex.exe' OR Name='OpenAI Codex.exe' OR Name='Codex Desktop.exe'"
  return ($desktopRows.Count -gt 0)
}

function Test-HudRunning {
  $rows = Get-ProcessRows "Name='powershell.exe' OR Name='node.exe'"
  foreach ($row in $rows) {
    $cmd = [string]$row.CommandLine
    if ($cmd -like "*Start-CodexUsageHud.ps1*" -or $cmd -like "*codex-usage-hud*backend.js*") { return $true }
  }
  return $false
}

function Start-Hud {
  if (-not (Test-Path -LiteralPath $HudScript)) { return }
  Start-Process -FilePath "powershell.exe" `
    -ArgumentList @("-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $HudScript) `
    -WorkingDirectory $root `
    -WindowStyle Hidden | Out-Null
}

$startedForCurrentCodexSession = $false
while ($true) {
  $codexRunning = Test-CodexRunning
  if (-not $codexRunning) {
    $startedForCurrentCodexSession = $false
  } elseif (-not $startedForCurrentCodexSession) {
    if (-not (Test-HudRunning)) { Start-Hud }
    $startedForCurrentCodexSession = $true
  }
  Start-Sleep -Seconds ([Math]::Max(2, $PollSeconds))
}