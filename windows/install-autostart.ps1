# Registers a scheduled task that mounts the drive in the background each time you log in.
# Run once from a normal (non-admin) PowerShell. Re-run to change settings.
param(
    [string]$Drive = "Y:",
    [string]$Url = "",   # default: chosen by mount.ps1 from ..\.env
    [string]$User = "",
    [string]$Pass = "",
    [switch]$Original    # use the full-length names even when SHORT_PATHS=1 in ..\.env
)

$TaskName = "rar2fs-dock mount"
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
