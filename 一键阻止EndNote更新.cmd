@echo off
rem EndNote auto-update blocker - launcher (block mode)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0EndNote-BlockUpdate.ps1" -KeepWindowOpen
echo.
pause
