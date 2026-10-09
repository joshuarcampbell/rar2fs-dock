# Starts the tray icon now and at every login (a shortcut in your Startup folder).
# Remove it again with .\windows\uninstall-tray.ps1.
$script = Join-Path $PSScriptRoot "tray.ps1"
$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "rar2fs-dock tray.lnk"
$arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""

$shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
$shortcut.TargetPath = (Get-Command powershell.exe).Source
$shortcut.Arguments = $arguments
$shortcut.WorkingDirectory = Split-Path $PSScriptRoot -Parent
$shortcut.WindowStyle = 7        # minimised: no window flashes up at login
$shortcut.Description = "rar2fs-dock tray icon"
$shortcut.Save()

Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
Write-Host "The tray icon is running and will start at every login."
Write-Host "Look for a coloured dot next to the clock (it may be behind the ^ arrow)."
