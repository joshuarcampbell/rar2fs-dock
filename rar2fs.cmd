@echo off
rem rar2fs-dock on Windows: the same as rar2fs.ps1, for a Command Prompt or for when
rem PowerShell refuses to run scripts.    rar2fs doctor     rar2fs limit 4     rar2fs help
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rar2fs.ps1" %*
exit /b %ERRORLEVEL%
