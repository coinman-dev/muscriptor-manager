@echo off
setlocal EnableExtensions DisableDelayedExpansion

rem Total Commander and some Windows .ps1 associations discard command-line arguments.
rem Invoke PowerShell explicitly and forward every argument to the manager script.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0muscriptor_manager.ps1" %*
set "exit_code=%ERRORLEVEL%"

echo.
pause
exit /b %exit_code%
