@echo off
setlocal
if /i "%~1"=="--foreground" goto run
start "Codex Usage HUD" /min powershell.exe -WindowStyle Hidden -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-CodexUsageHud.ps1"
exit /b

:run
powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-CodexUsageHud.ps1"