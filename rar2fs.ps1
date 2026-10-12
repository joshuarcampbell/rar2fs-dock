# rar2fs-dock on Windows: one command for everything.
#
#     .\rar2fs.ps1                    list what it can do
#     .\rar2fs.ps1 setup              set it all up (safe to run again)
#     .\rar2fs.ps1 doctor             find out why something isn't working
#     .\rar2fs.ps1 help limit         how one command is used
#
# Each command is carried out by a script in the windows\ folder; this file only finds
# the right one and passes your words on. Anything starting with "-" goes to that script
# as it is (.\rar2fs.ps1 setup -Yes -Drive R:), and plain words fill in its usual
# options in order (.\rar2fs.ps1 limit 4   is   windows\limit.ps1 -Cpu 4).
#
# If PowerShell refuses to run scripts, use rar2fs.cmd instead (rar2fs doctor), or run
# once:  Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
param(
    [Parameter(Position = 0)][string]$Command = "help",
    [Parameter(ValueFromRemainingArguments)][object[]]$Rest = @()
)

$scripts = Join-Path $PSScriptRoot "windows"

# What each command means: the script that does it, what plain words stand for, any
# option that is always passed, and words that are shorthand for an option.
#   Script      file in windows\
#   Words       option names that plain words fill, in order
#   Always      options passed every time
#   Shorthand   word -> option, for the first plain word
$commands = [ordered]@{
    "setup"         = @{ Script = "setup.ps1";        Text = "Set everything up on this PC, or finish or repair a setup" }
    "update"        = @{ Script = "update.ps1";       Text = "Get the newest version, rebuild and restart" }
    "doctor"        = @{ Script = "doctor.ps1";       Text = "Check the setup and say what is wrong and how to fix it" }
    "status"        = @{ Script = "tray.ps1";         Text = "Say in one line whether it is healthy"; Always = @{ Once = $true } }
    "in-use"        = @{ Script = "in-use.ps1";       Text = "Show what is being read from the drive right now" }
    "limit"         = @{ Script = "limit.ps1";        Text = "Show or change how much processor it may use:  limit 4 | half | none"; Words = @("Cpu") }
    "mount"         = @{ Script = "mount.ps1";        Text = "Mount the drive in this window, until the window closes:  mount [X:]"; Words = @("Drive") }
    "autostart"     = @{ Script = "autostart.ps1";    Text = "Mount the drive now and at every login:  autostart [X:]  |  autostart off"; Words = @("Drive")
                         Shorthand = @{ "off" = "Remove"; "remove" = "Remove"; "on" = "" } }
    "tray"          = @{ Script = "tray.ps1";         Text = "The tray icon:  tray on | off | status"
                         Shorthand = @{ "on" = "Install"; "off" = "Remove"; "status" = "Once" } }
    "folders"       = @{ Script = "add-folder.ps1";   Text = "List the folders on the drive"; Always = @{ List = $true } }
    "add-folder"    = @{ Script = "add-folder.ps1";   Text = "Add a folder without a restart:  add-folder E:\Concerts [name]"; Words = @("Path", "Name") }
    "remove-folder" = @{ Script = "add-folder.ps1";   Text = "Remove a folder added that way:  remove-folder concerts"; Words = @("Remove") }
    "add-user"      = @{ Script = "add-user.ps1";     Text = "Give another person or device its own login:  add-user plex <password>"; Words = @("Name", "Pass") }
    "connect-plex"  = @{ Script = "connect-plex.ps1"; Text = "Set up Plex on another Windows PC:  connect-plex [its address]"; Words = @("PlexHost") }
    "backup"        = @{ Script = "backup.ps1";       Text = "Save your settings, folders, logins and certificate to a zip:  backup [folder]"; Words = @("To") }
    "restore"       = @{ Script = "backup.ps1";       Text = "Put a backup zip back:  restore <zip> [-Force]"; Words = @("Restore") }
}

function Show-Help {
    Write-Host "rar2fs-dock - use:  .\rar2fs.ps1 <command> [options]"
    Write-Host ""
    foreach ($name in $commands.Keys) { Write-Host ("  {0,-14} {1}" -f $name, $commands[$name].Text) }
    Write-Host ""
    Write-Host "  help <command>  how that command is used, with its options"
}
# The explanation at the top of a script: its leading comment lines.
function Show-CommandHelp($name) {
    $file = Join-Path $scripts $commands[$name].Script
    foreach ($line in Get-Content $file) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
    $options = @((Get-Command $file).Parameters.Values | Where-Object { $_.Name -notin [System.Management.Automation.PSCmdlet]::CommonParameters })
    if ($options) {
        Write-Host ""
        Write-Host ("Options: " + (($options | ForEach-Object { "-" + $_.Name + $(if ($_.SwitchParameter) { "" } else { " <...>" }) }) -join "  "))
    }
}

$Command = $Command.ToLower().TrimStart('-')
if ($Command -in "help", "h", "?", "") {
    $about = if ($Rest.Count) { ([string]$Rest[0]).ToLower() } else { "" }
    if ($about -and $commands.Contains($about)) { Show-CommandHelp $about } else { Show-Help }
    exit 0
}
if (-not $commands.Contains($Command)) {
    Write-Host "'$Command' isn't something this can do." -ForegroundColor Red
    Write-Host ""
    Show-Help
    exit 1
}

$entry = $commands[$Command]
$file = Join-Path $scripts $entry.Script
$known = (Get-Command $file).Parameters          # the options that script really has
$options = @{}
if ($entry.Always) { foreach ($key in $entry.Always.Keys) { $options[$key] = $entry.Always[$key] } }
$words = @()

for ($i = 0; $i -lt $Rest.Count; $i++) {
    $token = $Rest[$i]
    if ($token -is [string] -and $token -match '^-([A-Za-z][\w-]*)(?::(.*))?$') {
        $given = $Matches[1]; $attached = $Matches[2]; $hasAttached = $Matches.ContainsKey(2)
        # the full name, or the start of exactly one (-Dr for -Drive), as PowerShell itself allows
        $name = @($known.Keys | Where-Object { $_ -eq $given })
        if (-not $name) { $name = @($known.Keys | Where-Object { $_ -like "$given*" }) }
        if ($name.Count -ne 1) {
            Write-Host "'$Command' has no option -$given. See:  .\rar2fs.ps1 help $Command" -ForegroundColor Red
            exit 1
        }
        $name = $name[0]
        if ($known[$name].SwitchParameter) {
            $options[$name] = $(if ($hasAttached) { $attached -notmatch '^(\$?false|0)$' } else { $true })
        } elseif ($hasAttached) {
            $options[$name] = $attached
        } else {
            $i++
            if ($i -ge $Rest.Count) { Write-Host "-$name needs a value after it." -ForegroundColor Red; exit 1 }
            $options[$name] = $Rest[$i]
        }
    } else {
        $words += , $token
    }
}

# a first word that is shorthand for an option (autostart off, tray on)
if ($words.Count -and $entry.Shorthand -and $entry.Shorthand.ContainsKey(([string]$words[0]).ToLower())) {
    $means = $entry.Shorthand[([string]$words[0]).ToLower()]
    if ($means) { $options[$means] = $true }
    $words = @($words | Select-Object -Skip 1)
}
# the remaining plain words fill the usual options, in order
$slots = @($entry.Words | Where-Object { $_ })
if ($words.Count -gt $slots.Count) {
    Write-Host "'$Command' doesn't know what to do with: $($words[$slots.Count..($words.Count - 1)] -join ' ')" -ForegroundColor Red
    Write-Host "See:  .\rar2fs.ps1 help $Command"
    exit 1
}
for ($i = 0; $i -lt $words.Count; $i++) { $options[$slots[$i]] = $words[$i] }

$global:LASTEXITCODE = 0
& $file @options
exit $LASTEXITCODE
