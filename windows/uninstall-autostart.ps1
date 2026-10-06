# Removes the login task and unmounts the drive.
$TaskName = "rar2fs-dock mount"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" |
    Where-Object { $_.CommandLine -like "*:webdav:*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Write-Host "Removed '$TaskName' and unmounted the drive."
