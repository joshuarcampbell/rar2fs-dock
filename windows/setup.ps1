# Sets up rar2fs-dock on this PC from start to finish:
#   1. checks (and where it can, installs) what's needed
#   2. asks which folders to share and writes docker-compose.override.yml
#   3. writes .env with a random password
#   4. builds and starts the container
#   5. mounts the drive and makes it come back at every login
#
# Run it from a normal (non-admin) PowerShell, in the repo folder:
#     .\windows\setup.ps1
#
# It never overwrites an existing .env or docker-compose.override.yml (use -Force for
# the folder list), so it is safe to run again - for instance to finish after a step
# failed, or to rebuild after pulling an update.
#
# Without questions:
#     .\windows\setup.ps1 -Yes -Folder "D:\Movies=movies","E:\TV=tv" -Drive R:
param(
    [string[]]$Folder = @(),   # "path=name" pairs; the same name twice merges those folders
    [string]$Drive = "",       # drive letter to mount on, e.g. R:  (default: first free one)
    [switch]$Network,          # other devices will connect (default: this PC only)
    [switch]$NoShortPaths,     # don't shorten over-long folder names
    [switch]$Subfolders,       # folders sharing a name become name\name-1, name\name-2 instead of merging
    [string]$NasUser = "",     # login for folders on a NAS
    [string]$NasPass = "",
    [switch]$Yes,              # accept the defaults instead of asking
    [switch]$Force,            # replace an existing docker-compose.override.yml
    [switch]$NoStart,          # write the files only; don't start the container
    [switch]$NoMount,          # start the container but don't mount the drive
    [switch]$NoTray            # don't add the tray icon
)

$ErrorActionPreference = 'Stop'
# Started with "powershell -File", a list arrives as one piece of text: "D:\A=a,E:\B=b".
# Split it wherever a comma is followed by the start of another path.
$Folder = @($Folder | ForEach-Object { $_ -split ',(?=\s*(?:[A-Za-z]:\\|\\\\))' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$repo = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $repo ".env"
$overrideFile = Join-Path $repo "docker-compose.override.yml"
$utf8 = New-Object System.Text.UTF8Encoding $false     # no BOM: Docker reads these files

function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Note($text) { Write-Host "   $text" }
function Stop-Setup($text) { Write-Host ""; Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }
function Ask($question, $default) {
    if ($Yes) { return $default }
    $suffix = if ($default) { " [$default]" } else { "" }
    $answer = Read-Host "   $question$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim()
}
function AskYesNo($question, [bool]$default) {
    if ($Yes) { return $default }
    $hint = if ($default) { "Y/n" } else { "y/N" }
    $answer = Read-Host "   $question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim() -match '^(y|yes)$'
}
# Runs a docker command quietly and says whether it worked. (With errors set to stop the
# script, PowerShell would otherwise abort on anything docker prints as a warning.)
function Test-Docker {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker @args 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false } finally { $ErrorActionPreference = $previous }
}
function Get-Health {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return [string](& docker inspect --format '{{.State.Health.Status}}' rar2fs 2>$null) } catch { return "" } finally { $ErrorActionPreference = $previous }
}
function Write-TextFile($path, [string[]]$lines) {
    [System.IO.File]::WriteAllText($path, (($lines -join "`n") + "`n"), $utf8)
}
function Get-EnvValue($name) {
    if (-not (Test-Path $envFile)) { return "" }
    foreach ($line in Get-Content $envFile) {
        if ($line -match "^\s*$name\s*=\s*(.*)$") { return $Matches[1].Trim() }
    }
    return ""
}
function Invoke-Winget($id, $what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-Setup "$what is not installed, and winget isn't available to install it. Install $what, then run this again."
    }
    Note "Installing $what (Windows may ask for permission)..."
    winget install -e --id $id --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Setup "Installing $what failed. Install it yourself (winget install $id), then run this again." }
}

# ---------------------------------------------------------------- 1. what's needed
Step "Checking what's needed"
if (-not $NoStart) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        Stop-Setup ("Docker Desktop is not installed. Get it from https://www.docker.com/products/docker-desktop/ " +
            "(or: winget install Docker.DockerDesktop), start it once, then run this again.")
    }
    if (-not (Test-Docker version)) { Stop-Setup "Docker Desktop is installed but not running. Start it, wait until it says it's running, then run this again." }
    Note "Docker is running."
}
if (-not $NoStart -and -not $NoMount) {
    $winfsp = @("${env:ProgramFiles(x86)}\WinFsp", "$env:ProgramFiles\WinFsp") | Where-Object { Test-Path (Join-Path $_ "bin") }
    if (-not $winfsp) { Invoke-Winget "WinFsp.WinFsp" "WinFsp" } else { Note "WinFsp is installed." }
    $rcloneFound = (Get-Command rclone -ErrorAction SilentlyContinue) -or
        (Test-Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\rclone.exe"))
    if (-not $rcloneFound) { Invoke-Winget "Rclone.Rclone" "rclone" } else { Note "rclone is installed." }
}

# ---------------------------------------------------------------- 2. folders
# Where a Windows path really lives: a local disk, or a network share behind a mapped
# drive letter. Docker can't see mapped drive letters, so those are connected by their
# network address instead.
function Resolve-Source($path) {
    $path = $path.Trim().Trim('"').TrimEnd('\')
    if ($path -match '^[A-Za-z]:$') { $path = "$path\" }
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { return @{ Error = "'$path' is not a folder that exists." } }
    $unc = $null
    if ($path -match '^\\\\') {
        $unc = $path
    } else {
        $letter = $path.Substring(0, 1)
        $psDrive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
        if ($psDrive -and $psDrive.DisplayRoot -match '^\\\\') { $unc = $psDrive.DisplayRoot.TrimEnd('\') + $path.Substring(2) }
    }
    if ($unc) {
        if ($unc -match '^\\\\server\\rar2fs') { return @{ Error = "'$path' is the rar2fs drive itself - choose the original folder." } }
        return @{ Kind = "nas"; Device = "//" + ($unc.TrimStart('\').TrimEnd('\') -replace '\\', '/'); Shown = $unc }
    }
    return @{ Kind = "local"; Device = ($path.TrimEnd('\') -replace '\\', '/') + $(if ($path -match '^[A-Za-z]:\\$') { "/" } else { "" }); Shown = $path }
}
function Get-SafeName($text) {
    $name = ($text.ToLower() -replace '[^a-z0-9._-]+', '-').Trim('-', '.')
    if (-not $name) { $name = "media" }
    return $name
}

$writeOverride = $true
if ((Test-Path $overrideFile) -and -not $Force) {
    Step "Folders"
    Note "Keeping your existing docker-compose.override.yml (use -Force to replace it)."
    $writeOverride = $false
}

$sources = @()
if ($writeOverride) {
    Step "Which folders should appear on the drive?"
    if ($Folder.Count -gt 0) {
        foreach ($pair in $Folder) {
            $path, $name = $pair -split '=', 2
            $resolved = Resolve-Source $path
            if ($resolved.Error) { Stop-Setup $resolved.Error }
            if (-not $name) { $name = Split-Path $path.TrimEnd('\') -Leaf }
            $resolved.Name = Get-SafeName $name
            $sources += $resolved
        }
    } elseif ($Yes) {
        Stop-Setup "With -Yes, say which folders to share: -Folder `"D:\Movies=movies`",`"E:\TV=tv`""
    } else {
        Note "Type a folder that holds your media, for example D:\Movies. Folders on a NAS drive"
        Note "letter work too. Press Enter on an empty line when you have added them all."
        while ($true) {
            $path = Read-Host "   Folder"
            if ([string]::IsNullOrWhiteSpace($path)) {
                if ($sources.Count -gt 0) { break }
                Note "Add at least one folder."
                continue
            }
            $resolved = Resolve-Source $path
            if ($resolved.Error) { Note $resolved.Error; continue }
            $leaf = Split-Path $path.Trim().Trim('"').TrimEnd('\') -Leaf
            if (-not $leaf) { $leaf = $path.Substring(0, 1) + "-drive" }
            $resolved.Name = Get-SafeName (Ask "Name it should have on the drive" (Get-SafeName $leaf))
            $sources += $resolved
            Note ("added: {0}  ->  {1}{2}" -f $resolved.Shown, $resolved.Name, $(if ($resolved.Kind -eq "nas") { "  (network share)" } else { "" }))
        }
    }

    # folders that share a name: one merged folder, or side by side?
    $sideBySide = [bool]$Subfolders
    $shared = $sources | Group-Object { $_.Name } | Where-Object { $_.Count -gt 1 }
    if ($shared -and -not $Subfolders -and -not $Yes) {
        Note ""
        Note ("These names are used by more than one folder: " + (($shared | ForEach-Object { $_.Name }) -join ", "))
        Note "  merge       - their contents appear together in one folder"
        Note "  subfolders  - each keeps its own folder inside, e.g. movies\movies-1, movies\movies-2"
        $sideBySide = (Ask "Merge them, or keep them as subfolders? (merge/subfolders)" "merge") -match '^s'
    }

    $needsNas = [bool]($sources | Where-Object { $_.Kind -eq "nas" })
    if ($needsNas) {
        if (-not $NasUser) { $NasUser = Get-EnvValue "NAS_USER" }
        if (-not $NasPass) { $NasPass = Get-EnvValue "NAS_PASS" }
        if (-not $NasUser -or -not $NasPass) {
            if ($Yes) { Stop-Setup "Some folders are on a network share. Give its login with -NasUser and -NasPass." }
            Note ""
            Note "Some folders are on a network share. Docker needs the share's login to read them."
            $NasUser = Ask "NAS user name" $NasUser
            $secure = Read-Host "   NAS password" -AsSecureString
            $NasPass = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
        }
        if ($NasPass -match ',') { Note "NOTE: the NAS password contains a comma, which Docker's share options can't handle. If the share fails to connect, change that password." }
    }

    # build the file
    $volumeLines = @(); $nasBlocks = @(); $nasIndex = 0
    foreach ($group in ($sources | Group-Object { $_.Name })) {
        $position = 0
        foreach ($source in $group.Group) {
            $position++
            if ($group.Count -eq 1)  { $target = "/sources/$($group.Name)";                              $shownAs = $group.Name }
            elseif ($sideBySide)     { $target = "/sources/$($group.Name)/$($group.Name)-$position";      $shownAs = "$($group.Name)\$($group.Name)-$position" }
            else                     { $target = "/sources/$($group.Name)@$position";                     $shownAs = "$($group.Name) (merged)" }
            if ($source.Kind -eq "nas") {
                $nasIndex++
                $volume = "nas-$($group.Name)" + $(if ($group.Count -gt 1) { "-$position" } else { "" })
                $volumeLines += "      - ${volume}:${target}:ro    # $($source.Shown)  ->  $shownAs"
                $nasBlocks += @("  ${volume}:", "    driver_opts:", "      <<: *nas-options", "      device: `"$($source.Device)`"")
            } else {
                $volumeLines += "      - `"$($source.Device):${target}:ro`"    # ->  $shownAs"
            }
        }
    }
    $file = @(
        "# Your media folders - written by windows\setup.ps1. Docker merges this file with",
        "# docker-compose.yml automatically, and it is gitignored. Edit it freely (see",
        "# docker-compose.override.example.yml for the formats), then: docker compose up -d",
        "services:",
        "  rar2fs:",
        "    volumes:"
    ) + $volumeLines
    if ($nasBlocks) {
        $file += @(
            "",
            "# Network shares. The login comes from NAS_USER / NAS_PASS in .env. Docker keeps",
            "# using a share's old `"device`" or login after you change it, until its volume is",
            "# removed: run .\windows\doctor.ps1, which spots that and prints the commands.",
            "x-nas-options: &nas-options",
            "  type: cifs",
            '  o: "username=${NAS_USER:?set NAS_USER in .env},password=${NAS_PASS:?set NAS_PASS in .env},vers=3.0,iocharset=utf8,ro,uid=1000,gid=1000"',
            "",
            "volumes:"
        ) + $nasBlocks
    }
    Write-TextFile $overrideFile $file
    Note "Wrote docker-compose.override.yml with $($sources.Count) folder(s)."
}

# ---------------------------------------------------------------- 3. settings
Step "Settings"
if (Test-Path $envFile) {
    Note "Keeping your existing .env."
    if ($writeOverride -and $needsNas -and -not (Get-EnvValue "NAS_USER")) {
        [System.IO.File]::AppendAllText($envFile, "`n# Login for the network shares in docker-compose.override.yml`nNAS_USER=$NasUser`nNAS_PASS=$NasPass`n", $utf8)
        Note "Added the NAS login to .env."
    }
} else {
    if (-not $Network -and -not $Yes) {
        $Network = AskYesNo "Will other devices on your network connect to it (for example Plex on another machine)?" $false
    }
    $shortPaths = -not $NoShortPaths
    if (-not $NoShortPaths -and -not $Yes) {
        $shortPaths = AskYesNo "Shorten over-long folder names, so Windows programs can open every file?" $true
    }
    $bytes = New-Object byte[] 24
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
    $password = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })

    $lines = @(
        "# Written by windows\setup.ps1. See .env.example and the README (`"Settings`") for",
        "# everything that can go here. After a change: docker compose up -d",
        "",
        "# The login for the drive and the status page",
        "WEBDAV_USER=rar2fs",
        "WEBDAV_PASS=$password"
    )
    if ($shortPaths) { $lines += @("", "# Show shortened folder names where a path would be too long for Windows", "SHORT_PATHS=1") }
    if ($Network) {
        $addresses = @(Get-NetIPConfiguration -ErrorAction SilentlyContinue | Where-Object { $_.IPv4DefaultGateway } |
            ForEach-Object { $_.IPv4Address.IPAddress } | Where-Object { $_ })
        $lines += @("", "# Addresses other devices use to reach this PC - they go in the HTTPS certificate", "TLS_HOSTS=$($addresses -join ',')")
    } else {
        $lines += @("", "# Only this PC can connect. Remove this line to let other devices in (see README).", "BIND=127.0.0.1")
    }
    if ($writeOverride -and $needsNas) { $lines += @("", "# Login for the network shares in docker-compose.override.yml", "NAS_USER=$NasUser", "NAS_PASS=$NasPass") }
    Write-TextFile $envFile $lines
    Note "Wrote .env with a random password."
}

if ($NoStart) {
    Step "Done (files only)"
    Note "Start it with: docker compose up -d --build"
    exit 0
}

# ---------------------------------------------------------------- 4. start
Step "Building and starting the container (the first build takes several minutes)"
Push-Location $repo
try {
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) { Stop-Setup "Docker could not start the container - see the messages above." }
} finally { Pop-Location }

Note "Waiting for it to report healthy..."
$deadline = (Get-Date).AddMinutes(5); $state = ""
while ((Get-Date) -lt $deadline) {
    $state = Get-Health
    if ($state -eq "healthy") { break }
    Start-Sleep -Seconds 5
}
if ($state -ne "healthy") { Stop-Setup "The container started but isn't healthy yet ($state). Look at: docker logs rar2fs" }
Note "The container is healthy."

# ---------------------------------------------------------------- 5. drive
$mountedOn = ""
if (-not $NoMount) {
    Step "Mounting the drive"
    $used = @((Get-PSDrive -PSProvider FileSystem).Name) + @(Get-ChildItem "HKCU:\Network" -ErrorAction SilentlyContinue | ForEach-Object { $_.PSChildName.ToUpper() })
    $existing = Get-ScheduledTask -TaskName "rar2fs-dock mount" -ErrorAction SilentlyContinue
    if (-not $Drive -and $existing -and $existing.Actions.Arguments -match '-Drive ([A-Za-z]:)') { $Drive = $Matches[1] }   # keep the letter in use
    if (-not $Drive) {
        $free = @('R','M','N','L','K','J','T','U','V','W','X','Y','Z','G','H','I','O','P','Q','S') | Where-Object { $used -notcontains $_ } | Select-Object -First 1
        if (-not $free) { Stop-Setup "No free drive letter found. Free one up, or choose with -Drive." }
        $Drive = (Ask "Drive letter to use" "${free}:")
    }
    $Drive = $Drive.Substring(0, 1).ToUpper() + ":"
    & (Join-Path $PSScriptRoot "uninstall-autostart.ps1") | Out-Null
    & (Join-Path $PSScriptRoot "install-autostart.ps1") -Drive $Drive | Out-Null
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path "$Drive\") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
    if (Test-Path "$Drive\") { $mountedOn = $Drive; Note "$Drive is mounted and will come back at every login." }
    else { Note "The drive hasn't appeared yet. Try: .\windows\mount.ps1 -Drive $Drive   to see why." }
}

# ---------------------------------------------------------------- tray icon
if (-not $NoMount -and -not $NoTray) {
    if (AskYesNo "Add a tray icon that shows whether it's healthy (a coloured dot next to the clock)?" $true) {
        & (Join-Path $PSScriptRoot "install-tray.ps1") | Out-Null
        Note "The tray icon is running and will start at every login."
    }
}

# ---------------------------------------------------------------- Plex on another Windows PC
if (-not $Yes -and (AskYesNo "Does Plex run on ANOTHER Windows PC? Set that PC up now?" $false)) {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "connect-plex.ps1")
}

# ---------------------------------------------------------------- summary
$scheme = if ((Get-EnvValue "TLS") -eq "0") { "http" } else { "https" }
Step "All set"
if ($mountedOn) { Note "Your files:     $mountedOn\" }
Note "Status page:    ${scheme}://localhost:8766/status.html     (health, folders, run a health report)"
Note "Health as data: ${scheme}://localhost:8766/status.json     (for dashboards and monitoring apps)"
Note "Login:          $(Get-EnvValue 'WEBDAV_USER')  /  the WEBDAV_PASS value in .env"
if ($scheme -eq "https") { Note "                (your browser will warn about the certificate once - that's expected)" }
Note ""
Note "Using Plex on this PC? Add the folders from $(if ($mountedOn) { $mountedOn } else { 'the drive' }) to your libraries, and turn off"
Note "'Empty trash automatically after every scan' first. See the README, 'Plex on the same Windows PC'."
Note "Plex on another Windows PC? Run .\windows\connect-plex.ps1 any time."
if (Get-EnvValue "TLS_HOSTS") {
    Note ""
    Note "For other devices, allow the ports through Windows Firewall once (admin PowerShell):"
    Note '  New-NetFirewallRule -DisplayName "rar2fs-dock" -Direction Inbound -Protocol TCP -LocalPort 8765-8767 -Action Allow -Profile Private'
    Note "They connect to: ${scheme}://$((Get-EnvValue 'TLS_HOSTS') -split ',' | Select-Object -First 1):8765"
}
Note ""
Note "To change the folders later, edit docker-compose.override.yml and run: docker compose up -d"
Note "To update to a newer version: .\windows\update.ps1     To save your setup: .\windows\backup.ps1"
