@echo off
REM Quarantine Review Assistant v2 - run this on the HOST PC (double-click).
REM Opens the launcher: PC readiness checks, Defender download guide, Sandbox launch.
REM -ExecutionPolicy Bypass applies to this process only; it does not change machine policy.
REM "start /min" opens PowerShell minimised, so no PowerShell window appears (the launcher hides it from the taskbar too).
start "" /min powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\Launcher.ps1"
