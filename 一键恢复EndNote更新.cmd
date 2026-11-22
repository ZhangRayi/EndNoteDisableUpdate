@echo off
rem EndNote auto-update blocker - launcher (restore mode)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EndNote-BlockUpdate.ps1" -Undo -KeepWindowOpen
echo.
pause
