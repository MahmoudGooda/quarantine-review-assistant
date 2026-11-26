@echo off
REM Fallback: run INSIDE Windows Sandbox only, if the review window did not open by itself.
REM Shows a console so any error is visible.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0app\QuarantineReview.ps1"
if errorlevel 1 pause
