# Makes a drive appear by itself every time you log in - or stops that again.
# You can have more than one (say Y: with shortened names and K: with the full ones, or
# drives from two servers); each is looked after on its own, and no other drive is
# touched.
#
#     .\rar2fs.ps1 autostart              set it up. With one drive, or none yet, it just
#                                         does it (Y: unless you say otherwise); with
#                                         several it lists them and asks which you mean
#     .\rar2fs.ps1 autostart X:           set up X: - new, or again if it is there already
#     .\rar2fs.ps1 autostart list         show the drives and whether each is mounted
#     .\rar2fs.ps1 autostart off          stop: the one drive, or it asks which
#     .\rar2fs.ps1 autostart off X:       stop X: only          (-All: every one)
#
# On another PC (one without the container) there is no rar2fs.ps1; run this file itself:
#     .\windows\autostart.ps1 -Url https://192.168.1.10:8765
#     .\windows\autostart.ps1 -Remove
#
# Each drive is a scheduled task, "rar2fs-dock mount X", that runs mount.ps1 in the
# background at login. Run this from a normal (non-admin) PowerShell. Setting a drive up
# again replaces its task and remounts it, so that is also how to change its address.
#
# When X: is new and another drive is already set up, it asks whether X: should take
# its place or be added beside it. -Add and -Replace answer that in advance.
# -Refresh sets up again every drive that is already there, as it is, without asking -
# the other scripts use it after an update or a changed certificate.
#
# The login normally comes from ..\.env, read each time the drive is mounted. -User and
# -Pass override that, but are stored in the task's settings in plain text - prefer a
# .env file next to the "windows" folder (on another PC: two lines, WEBDAV_USER and
# WEBDAV_PASS).
param(
    [string]$Drive = "",     # the letter, e.g. X:   (default Y: for a first drive)
    [string]$Url = "",       # default: chosen by mount.ps1 from ..\.env
    [string]$User = "",
    [string]$Pass = "",
    [switch]$Original,       # use the full-length names even when SHORT_PATHS=1 in ..\.env
    [switch]$Remove,         # stop mounting at login, and unmount
    [switch]$All,            # with -Remove, or when it would ask which: all of them
    [switch]$Add,            # a new letter goes beside the drives already set up
    [switch]$Replace,        # a new letter takes the place of the drives already set up
    [switch]$Refresh,        # set up again every drive that is there, unchanged
    [switch]$List,           # show the drives
    [switch]$Objects         # for other scripts: return the drives instead of printing them
)

$Prefix = "rar2fs-dock mount"       # tasks are "<prefix> X"; one from an older version is just "<prefix>"

function Format-Letter($text) { if ($text) { return $text.Substring(0, 1).ToUpper() + ":" } else { return "" } }

# Every rar2fs drive on this PC: the ones started at login (a scheduled task each) and
# any that are only mounted by hand in a window right now.
function Get-Drives {
    $mounted = @{}
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" | Where-Object { $_.CommandLine -like "*:webdav:*" })) {
        if ($process.CommandLine -match ' mount \S+ ([A-Za-z]):') { $mounted[$Matches[1].ToUpper() + ":"] = $process.ProcessId }
    }
    $found = @()
    foreach ($task in @(Get-ScheduledTask -TaskName "$Prefix*" -ErrorAction SilentlyContinue)) {
        $arguments = [string]$task.Actions.Arguments
        $letter = if ($arguments -match '-Drive ([A-Za-z]:)') { $Matches[1].ToUpper() } else { "Y:" }
        $found += [pscustomobject]@{
            Drive = $letter; AtLogin = $true; Task = $task.TaskName
            Url = $(if ($arguments -match '-Url (\S+)') { $Matches[1] } else { "" })
            Original = [bool]($arguments -match '-Original')
            User = $(if ($arguments -match '-User "([^"]*)"') { $Matches[1] } else { "" })
            Pass = $(if ($arguments -match '-Pass "([^"]*)"') { $Matches[1] } else { "" })
            Mounted = $mounted.ContainsKey($letter); ProcessId = $mounted[$letter]
        }
    }
    foreach ($letter in $mounted.Keys) {
        if (-not ($found | Where-Object { $_.Drive -eq $letter })) {
            $found += [pscustomobject]@{ Drive = $letter; AtLogin = $false; Task = ""; Url = ""; Original = $false; User = ""; Pass = ""; Mounted = $true; ProcessId = $mounted[$letter] }
        }
    }
    return @($found | Sort-Object { -not $_.AtLogin }, Drive)
}
function Show-Drives($drives, [switch]$Numbered) {
    $n = 0
    foreach ($d in $drives) {
        $n++
        $where = if ($d.Url) { $d.Url } elseif ($d.AtLogin) { "this PC" + $(if ($d.Original) { ", full names" } else { "" }) } else { "" }
        $kind = if ($d.AtLogin) { "at login" } else { "by hand, in a window - not started at login" }
        $state = if ($d.Mounted) { "mounted" } else { "not mounted right now" }
        $mark = if ($Numbered -and $d.AtLogin) { "{0,2} " -f $n } else { "   " }
        Write-Host ("  {0}{1}  {2,-9} {3}   {4}" -f $mark, $d.Drive, $kind, $where, $state).TrimEnd()
    }
}
# Lets the user pick from the drives that start at login. Returns the chosen ones.
function Select-Drives($drives, $question) {
    $choices = @($drives | Where-Object { $_.AtLogin })
    Write-Host "rar2fs drives on this PC:"
    Show-Drives $choices -Numbered
    $others = @($drives | Where-Object { -not $_.AtLogin })
    if ($others) { Show-Drives $others }
    $answer = (Read-Host "$question Numbers or letters with spaces between, 'all', or Enter for none").Trim()
    if (-not $answer) { return @() }
    if ($answer -match '^(all|a|\*)$') { return $choices }
    $picked = @()
    foreach ($word in ($answer -split '[\s,]+' | Where-Object { $_ })) {
        $match = $null
        if ($word -match '^\d+$' -and [int]$word -ge 1 -and [int]$word -le $choices.Count) { $match = $choices[[int]$word - 1] }
        elseif ($word -match '^[A-Za-z]:?$') { $match = $choices | Where-Object { $_.Drive -eq (Format-Letter $word) } }
        if (-not $match) { Write-Host "'$word' isn't one of them - nothing was changed." -ForegroundColor Red; exit 1 }
        $picked += $match
    }
    return @($picked | Sort-Object Drive -Unique)
}

# Unmounts ONE drive (if it is mounted) and tells Explorer it has gone. Stopping the
# mount this way doesn't tell Explorer by itself, so it would keep showing the letter as
# a disconnected drive.
function Stop-Mount($letter) {
    $bare = $letter.Substring(0, 1)
    $stopped = $false
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" | Where-Object { $_.CommandLine -like "*:webdav:*" -and $_.CommandLine -match " mount \S+ ${bare}:" })) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
        $stopped = $true
    }
    if (-not $stopped) { return }
    if (-not ("Rar2fsDock.Shell" -as [type])) {
        Add-Type -Namespace Rar2fsDock -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet=CharSet.Unicode)] public static extern void SHChangeNotify(int wEventId, uint uFlags, string dwItem1, IntPtr dwItem2);'
    }
    $cache = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\MountPoints2"
    foreach ($entry in @($bare, "##server#rar2fs-$bare")) {
        $key = Join-Path $cache $entry
        if (Test-Path -LiteralPath $key) { Remove-Item -LiteralPath $key -Recurse -Force -ErrorAction SilentlyContinue }
    }
    [Rar2fsDock.Shell]::SHChangeNotify(0x00000080, 0x0005, "${bare}:\", [IntPtr]::Zero)    # drive removed
}
# Takes one drive away: its task (so it no longer starts at login) and its mount.
function Remove-Drive($drive) {
    if ($drive.Task) {
        Stop-ScheduledTask -TaskName $drive.Task -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $drive.Task -Confirm:$false -ErrorAction SilentlyContinue
    }
    Stop-Mount $drive.Drive
}
# Sets one drive up: replaces what is on that letter, registers its task and starts it.
function Install-Drive($letter, $address, [bool]$fullNames, $loginUser, $loginPass, $oldTask) {
    if ($oldTask) {
        Stop-ScheduledTask -TaskName $oldTask -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $oldTask -Confirm:$false -ErrorAction SilentlyContinue
    }
    Stop-Mount $letter
    Start-Sleep -Seconds 1
    if (Test-Path "$letter\") {
        Write-Host "$letter is used by something else on this PC, so it was left alone. Choose another letter: autostart X:" -ForegroundColor Red
        return $false
    }
    $script = Join-Path $PSScriptRoot "mount.ps1"
    $argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`" -Drive $letter"
    if ($address) { $argList += " -Url $address" }
    if ($fullNames) { $argList += " -Original" }
    if ($loginUser) { $argList += " -User `"$loginUser`" -Pass `"$loginPass`"" }
    $name = "$Prefix " + $letter.Substring(0, 1)
    $action   = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList
    $trigger  = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                  -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $name -Action $action -Trigger $trigger -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $name
    Write-Host "$letter is set up: it should appear in a few seconds and will come back at every login."
    return $true
}
# The same drive again, with anything given on the command line taking over.
function Update-Drive($drive) {
    $address = if ($Url) { $Url } else { $drive.Url }
    $fullNames = if ($script:OriginalGiven) { [bool]$Original } else { $drive.Original }
    $loginUser = if ($User) { $User } else { $drive.User }
    $loginPass = if ($User) { $Pass } else { $drive.Pass }
    return (Install-Drive $drive.Drive $address $fullNames $loginUser $loginPass $drive.Task)
}

$script:OriginalGiven = $PSBoundParameters.ContainsKey('Original')
$Drive = Format-Letter $Drive
$drives = @(Get-Drives)
$atLogin = @($drives | Where-Object { $_.AtLogin })

# ---------------------------------------------------------------- list
if ($Objects) { return $drives }        # for the other scripts
if ($List) {
    if (-not $drives) { Write-Host "No rar2fs drive is set up on this PC. Set one up with: autostart"; exit 0 }
    Write-Host "rar2fs drives on this PC:"
    Show-Drives $drives
    exit 0
}

# ---------------------------------------------------------------- refresh
if ($Refresh) {
    if (-not $atLogin) { Write-Host "No drive is set to start at login, so there is nothing to set up again."; exit 0 }
    $ok = $true
    foreach ($d in $atLogin) { if (-not (Update-Drive $d)) { $ok = $false } }
    if ($ok) { exit 0 } else { exit 1 }
}

# ---------------------------------------------------------------- remove
if ($Remove) {
    if ($All) { $targets = $drives }
    elseif ($Drive) {
        $targets = @($drives | Where-Object { $_.Drive -eq $Drive })
        if (-not $targets) { Write-Host "$Drive isn't a rar2fs drive on this PC. See: autostart list" -ForegroundColor Red; exit 1 }
    }
    elseif ($atLogin.Count -eq 1) { $targets = $atLogin }                   # one drive: no need to ask
    elseif ($atLogin.Count -gt 1) { $targets = @(Select-Drives $drives "Which should stop?") }
    else {
        $targets = @()
        if ($drives) {
            Write-Host ("No drive starts at login. Mounted by hand: " + (($drives | ForEach-Object { $_.Drive }) -join ", ") + " - close its window, or name it: autostart off X:")
        } else { Write-Host "No rar2fs drive is set up on this PC." }
        exit 0
    }
    if (-not $targets) { Write-Host "Nothing was changed."; exit 0 }
    foreach ($d in $targets) { Remove-Drive $d }
    Write-Host ("Stopped and unmounted: " + (($targets | ForEach-Object { $_.Drive }) -join ", ") + ".")
    exit 0
}

# ---------------------------------------------------------------- set up
$ok = $true
if ($Drive) {
    $same = $drives | Where-Object { $_.Drive -eq $Drive } | Select-Object -First 1
    if ($same -and $same.AtLogin) {
        $ok = Update-Drive $same                                    # that drive, again
    } else {
        # A new letter. If other drives already start at login: beside them, or instead of them?
        if ($atLogin -and -not $Add -and -not $Replace) {
            Write-Host ("Already set up to start at login: " + (($atLogin | ForEach-Object { $_.Drive }) -join ", ") + ".")
            $answer = (Read-Host "Should $Drive take its place (r), or be added beside it (a)? [a]").Trim()
            if ($answer -match '^(r|replace)') { $Replace = $true }
        }
        if ($Replace) { foreach ($d in $atLogin) { Remove-Drive $d } }
        $ok = Install-Drive $Drive $Url ([bool]$Original) $User $Pass ""
    }
} elseif ($atLogin.Count -eq 0) {
    $ok = Install-Drive "Y:" $Url ([bool]$Original) $User $Pass ""           # the first drive
} elseif ($atLogin.Count -eq 1) {
    $ok = Update-Drive $atLogin[0]                                           # the one drive: just do it
} else {
    $targets = if ($All) { $atLogin } else { @(Select-Drives $drives "Which should be set up again?") }
    if (-not $targets) { Write-Host "Nothing was changed."; exit 0 }
    foreach ($d in $targets) { if (-not (Update-Drive $d)) { $ok = $false } }
}
if ($ok) { exit 0 } else { exit 1 }
