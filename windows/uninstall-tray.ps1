# Stops the tray icon and removes it from your Startup folder.
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "rar2fs-dock tray.lnk"
if (Test-Path -LiteralPath $shortcutPath) { [IO.File]::Delete($shortcutPath) }
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*tray.ps1*" -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Write-Host "The tray icon is stopped and won't start at login."
