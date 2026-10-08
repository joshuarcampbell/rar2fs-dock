# Removes the login task and unmounts the drive.
$TaskName = "rar2fs-dock mount"
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue

$mounts = @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" |
    Where-Object { $_.CommandLine -like "*:webdav:*" })
$letters = @()
foreach ($mount in $mounts) {
    if ($mount.CommandLine -match ' mount \S+ ([A-Za-z]):') { $letters += $Matches[1].ToUpper() }
    Stop-Process -Id $mount.ProcessId -Force
}

# Stopping the mount this way doesn't tell Explorer the drive has gone, so it would keep
# showing the letter as a disconnected drive. Tell it, and drop its cached entries.
if ($letters) {
    Add-Type -Namespace Rar2fsDock -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);'
    $cache = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
    foreach ($letter in $letters) {
        foreach ($entry in @($letter, "##server#rar2fs-$letter")) {
            $key = Join-Path $cache $entry
            if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
        }
        [Rar2fsDock.Shell]::SHChangeNotify(0x00000080, 0x0005, "${letter}:\", [IntPtr]::Zero)    # drive removed
    }
}
Write-Host "Removed '$TaskName' and unmounted the drive."
