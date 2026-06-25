@echo off
setlocal
set "EXE="
if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "EXE=%ProgramFiles%\PowerShell\7\pwsh.exe"
if "%EXE%"=="" if exist "%ProgramW6432%\PowerShell\7\pwsh.exe" set "EXE=%ProgramW6432%\PowerShell\7\pwsh.exe"
if "%EXE%"=="" if exist "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" set "EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if "%EXE%"=="" set "EXE=powershell.exe"
"%EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
set "ERR=%ERRORLEVEL%"
if not "%ERR%"=="0" (
    echo.
    echo Install failed (exit code %ERR%). Check the messages above.
    pause
)
endlocal & exit /b %ERR%
