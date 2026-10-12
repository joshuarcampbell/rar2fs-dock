# Makes the drive appear by itself every time you log in - or stops that again.
#
#     .\rar2fs.ps1 autostart              mount now, and at every login (drive Y:)
#     .\rar2fs.ps1 autostart X:           the same, on another letter
#     .\rar2fs.ps1 autostart off          unmount, and stop mounting at login
#
# On another PC (one without the container) there is no rar2fs.ps1; run this file itself:
#     .\windows\autostart.ps1 -Url https://192.168.1.10:8765
#     .\windows\autostart.ps1 -Remove
#
# It registers a scheduled task, "rar2fs-dock mount", that runs mount.ps1 in the
# background at login. Run it from a normal (non-admin) PowerShell. Running it again
# replaces the task and remounts the drive, so that is also how to change the letter
# or the address.
#
# The login normally comes from ..\.env, read each time the drive is mounted. -User and
# -Pass override that, but are stored in the task's settings in plain text - prefer a
# .env file next to the "windows" folder (on another PC: two lines, WEBDAV_USER and
# WEBDAV_PASS).
param(
    [string]$Drive = "Y:",
    [string]$Url = "",   # default: chosen by mount.ps1 from ..\.env
    [string]$User = "",
    [string]$Pass = "",
    [switch]$Original,   # use the full-length names even when SHORT_PATHS=1 in ..\.env
    [switch]$Remove      # unmount the drive and remove the login task
)

$TaskName = "rar2fs-dock mount"

# Stops the task and the mount it started, and tells Explorer the drive has gone.
function Remove-Mount {
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
}

if ($Remove) {
    Remove-Mount
    Write-Host "Removed '$TaskName' and unmounted the drive."
    exit 0
}

# Out with the old one first: registering the task again would replace it, but the mount
# it started would carry on with the old letter or address.
Remove-Mount
Start-Sleep -Seconds 1

$Drive = $Drive.Substring(0, 1).ToUpper() + ":"
$script = Join-Path $PSScriptRoot "mount.ps1"
$argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Drive $Drive"
if ($Url) { $argList += " -Url $Url" }
if ($Original) { $argList += " -Original" }
if ($User) { $argList += " -User `"$User`" -Pass `"$Pass`"" }

$action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
$trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName
Write-Host "Installed '$TaskName'. $Drive should appear in a few seconds and will remount at every login."
exit 0
