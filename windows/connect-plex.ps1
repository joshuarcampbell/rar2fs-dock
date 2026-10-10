# Connects a Plex server on ANOTHER Windows PC to this PC's rar2fs-dock. Run it here, on
# the PC with the container; setup.ps1 offers to at the end.
#
#     .\windows\connect-plex.ps1
#
# It asks for the Plex PC's address, then:
#   1. lets other devices reach this PC: .env (BIND, TLS_HOSTS) and the firewall rule
#   2. makes a login just for the Plex PC
#   3. gets a Plex token (you type a short code at plex.tv/link), turns off Plex's
#      "empty trash automatically", and switches on instant refresh in .env
#   4. restarts the container once, with all of that
#   5. copies a ready-made folder to the Plex PC and tells you where it is. Running
#      Setup.cmd in that folder, on the Plex PC, is the one step left to you.
#
# Nothing can install the drive on the Plex PC from here - Windows doesn't accept that
# from another PC - which is why step 5 ends with something for you to do.
#
#     .\windows\connect-plex.ps1 -PlexHost 192.168.1.20 -Drive P:
#     .\windows\connect-plex.ps1 -PlexHost 192.168.1.20 -CopyTo \\192.168.1.20\Shared
#     .\windows\connect-plex.ps1 -PlexHost 192.168.1.20 -DryRun     # change nothing, show what it would do
param(
    [string]$PlexHost = "",      # the Plex PC's IP address or name
    [string]$Drive = "Y:",       # the letter the drive gets on the Plex PC
    [string]$Token = "",         # a Plex token, if you have one; otherwise it asks
    [string]$CopyTo = "",        # a shared folder on the Plex PC to copy to (default: its C: drive)
    [string]$Login = "plex",     # name of the login made for the Plex PC
    [switch]$NoPlex,             # skip the Plex token and settings; only set up the drive
    [switch]$NoCopy,             # make the folder but leave it on this PC
    [switch]$DryRun              # change nothing on this PC or in Plex
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$envFile = Join-Path $repo ".env"
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Note($text) { Write-Host "   $text" }
function Stop-Setup($text) { Write-Host ""; Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }
function Ask($question, $default) {
    $suffix = if ($default) { " [$default]" } else { "" }
    $answer = Read-Host "   $question$suffix"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim()
}
function AskYesNo($question, [bool]$default) {
    $hint = if ($default) { "Y/n" } else { "y/N" }
    $answer = Read-Host "   $question [$hint]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim() -match '^(y|yes)$'
}
# docker, without PowerShell stopping at anything it prints as a warning
function Invoke-Docker {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { $out = & docker @args 2>$null; $script:dockerOk = ($LASTEXITCODE -eq 0); return $out }
    catch { $script:dockerOk = $false } finally { $ErrorActionPreference = $previous }
}
function Get-EnvValue([string[]]$lines, $name) {
    foreach ($line in $lines) { if ($line -match "^\s*$name\s*=\s*(.*)$") { return $Matches[1].Trim() } }
    return ""
}
# Replaces the line that sets $name, or adds one (with a comment) at the end. Every
# other line - comments included - is left exactly as it is.
function Set-EnvValue([string[]]$lines, $name, $value, $comment) {
    $found = $false
    $out = @(foreach ($line in $lines) {
        if ($line -match "^\s*$name\s*=") { if (-not $found) { "$name=$value" }; $found = $true } else { $line }
    })
    if (-not $found) { $out += @("", "# $comment", "$name=$value") }
    return ,$out
}
function Test-Port($server, $port) {
    $client = New-Object Net.Sockets.TcpClient
    try { return ($client.BeginConnect($server, $port, $null, $null).AsyncWaitHandle.WaitOne(3000) -and $client.Connected) }
    catch { return $false } finally { $client.Close() }
}

if ($DryRun) { Write-Host "DRY RUN: nothing on this PC or in Plex is changed." -ForegroundColor Yellow }

# ---------------------------------------------------------------- this PC
Step "Checking this PC"
if (-not (Test-Path $envFile)) { Stop-Setup "There is no .env yet. Run .\windows\setup.ps1 first." }
$running = Invoke-Docker inspect --format '{{.State.Running}}' rar2fs
if ("$running" -ne "true") { Stop-Setup "The rar2fs container isn't running. Run .\windows\setup.ps1 (or: docker compose up -d) first." }
$envLines = [string[]][IO.File]::ReadAllLines($envFile)
$original = $envLines -join "`n"
$folders = @(Invoke-Docker exec rar2fs cut -f1 /tmp/folders.state | Where-Object { $_ })
if (-not $folders) { Stop-Setup "The container isn't sharing any folders yet. Add some first (see .\windows\doctor.ps1)." }
Note "The container is running and shares: $($folders -join ', ')"

# ---------------------------------------------------------------- the Plex PC
Step "The PC that runs Plex"
if (-not $PlexHost) { $PlexHost = Ask "Its IP address or name (for example 192.168.1.20)" "" }
if (-not $PlexHost) { Stop-Setup "No address given." }
$plexUrl = "http://${PlexHost}:32400"
# the address of THIS PC, as the Plex PC will see it
try {
    $probe = New-Object Net.Sockets.UdpClient
    $probe.Connect($PlexHost, 32400)
    $thisPc = $probe.Client.LocalEndPoint.Address.ToString()
    $probe.Close()
} catch { Stop-Setup "'$PlexHost' can't be found on the network. Check the address or name." }
if ($thisPc -match '^127\.') { Stop-Setup "That address is this PC itself. For Plex on this PC, see the README, 'Plex on the same Windows PC'." }
Note "The Plex PC will reach this PC at $thisPc."
$plexAnswers = Test-Port $PlexHost 32400
if ($plexAnswers) { Note "Plex answers at $plexUrl." }
elseif (-not $NoPlex) {
    Note "Nothing answers at $plexUrl. Is Plex running there, and is that the right PC?"
    if (-not (AskYesNo "Carry on and set up the drive only, without the Plex settings?" $true)) { exit 1 }
    $NoPlex = $true
}
$Drive = $Drive.Substring(0, 1).ToUpper() + ":"

# ---------------------------------------------------------------- Plex token and settings
function Get-PlexTokenByCode {
    $headers = @{ 'Accept' = 'application/json'; 'X-Plex-Product' = 'rar2fs-dock'; 'X-Plex-Client-Identifier' = "rar2fs-dock-$([Guid]::NewGuid().ToString('N'))" }
    try { $pin = Invoke-RestMethod -Method Post -Uri 'https://plex.tv/api/v2/pins' -Headers $headers }
    catch { Note "plex.tv could not be reached ($($_.Exception.Message))."; return "" }
    Note ""
    Note "In a browser, open   https://plex.tv/link"
    Note "sign in to the Plex account that owns the server, and enter this code:"
    Write-Host ""; Write-Host "        $($pin.code)" -ForegroundColor Green; Write-Host ""
    Note "Waiting for you to enter it (up to 5 minutes; Ctrl+C to give up)..."
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        try { $check = Invoke-RestMethod -Uri "https://plex.tv/api/v2/pins/$($pin.id)" -Headers $headers } catch { continue }
        if ($check.authToken) { return [string]$check.authToken }
    }
    Note "No code was entered in time."
    return ""
}
function Invoke-Plex($method, $path) {
    return Invoke-RestMethod -Method $method -Uri "$plexUrl$path" -Headers @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' } -TimeoutSec 20
}

$plexReady = $false; $current = ""
if (-not $NoPlex) {
    Step "Plex"
    $current = Get-EnvValue $envLines "PLEX_URL"
    if ($current -and $current -ne $plexUrl) {
        Note "This PC is set up to refresh another Plex server: $current"
        if (-not (AskYesNo "Switch it to the Plex on $PlexHost instead?" $false)) { $NoPlex = $true; Note "Leaving the Plex settings alone." }
    }
}
if (-not $NoPlex) {
    if (-not $Token -and $current -eq $plexUrl) { $Token = Get-EnvValue $envLines "PLEX_TOKEN" }
    if (-not $Token) {
        Note "To tell Plex about new files straight away, this PC needs a Plex token."
        Note "  1  get one now with a code at plex.tv/link (easiest)"
        Note "  2  paste a token you already have"
        Note "  3  skip - Plex will find new files at its next scheduled scan"
        switch (Ask "Choose 1, 2 or 3" "1") {
            '1' { $Token = Get-PlexTokenByCode }
            '2' { $Token = Ask "Token" "" }
        }
    }
    if ($Token) {
        try {
            $sections = Invoke-Plex Get "/library/sections"
            $plexReady = $true
            Note "Plex accepts the token."
            foreach ($library in @($sections.MediaContainer.Directory)) {
                Note ("   library: {0} ({1})" -f $library.title, $library.type)
            }
        } catch {
            Note "Plex at $plexUrl did not accept that token ($($_.Exception.Message))."
            Note "Carrying on without the Plex settings. Run this again to retry."
        }
    }
    if ($plexReady) {
        if ($DryRun) { Note "Would turn off 'Empty trash automatically after every scan' in Plex." }
        else {
            try { Invoke-Plex Put "/:/prefs?autoEmptyTrash=0" | Out-Null; Note "Turned off 'Empty trash automatically after every scan' in Plex." }
            catch { Note "Couldn't change Plex's trash setting. Turn off Settings > Library > 'Empty trash automatically after every scan' yourself." }
        }
    }
}

# ---------------------------------------------------------------- .env
Step "Settings on this PC"
if ($envLines | Where-Object { $_ -match '^\s*BIND\s*=\s*127\.0\.0\.1\s*$' }) {
    $envLines = [string[]]@($envLines | Where-Object { $_ -notmatch '^\s*BIND\s*=\s*127\.0\.0\.1\s*$' -and $_ -notmatch '^\s*#\s*Only this PC can connect' })
    Note "Removed BIND=127.0.0.1, so other devices can connect."
}
$tlsOn = (Get-EnvValue $envLines "TLS") -ne "0"
$certChanges = $false
if ($tlsOn) {
    $hosts = @((Get-EnvValue $envLines "TLS_HOSTS") -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($hosts -notcontains $thisPc) {
        $envLines = Set-EnvValue $envLines "TLS_HOSTS" (($hosts + $thisPc) -join ',') "Addresses other devices use to reach this PC - they go in the HTTPS certificate"
        $certChanges = $true
        Note "Added $thisPc to TLS_HOSTS, so the certificate covers it."
    }
}
if ($plexReady) {
    $map = ($folders | ForEach-Object { "$_=$Drive\$_" }) -join ';'
    $envLines = Set-EnvValue $envLines "PLEX_URL" $plexUrl "Tell Plex about new files straight away (see README)"
    $envLines = Set-EnvValue $envLines "PLEX_TOKEN" $Token "Plex token"
    $envLines = Set-EnvValue $envLines "PLEX_PATH_MAP" $map "Where each folder is on the Plex PC"
    Note "Instant refresh: PLEX_URL, PLEX_TOKEN and PLEX_PATH_MAP ($map)."
}
$envChanged = (($envLines -join "`n") -ne $original)
if (-not $envChanged) { Note "Nothing in .env needed changing." }
elseif ($DryRun) { Note "Would save these changes to .env." }
else { [IO.File]::WriteAllText($envFile, (($envLines -join "`n") + "`n"), $utf8); Note "Saved .env." }

# ---------------------------------------------------------------- a login for the Plex PC
Step "A login for the Plex PC"
$bytes = New-Object byte[] 24
[System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
$alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789"
$password = -join ($bytes | ForEach-Object { $alphabet[$_ % $alphabet.Length] })
$usersFile = Join-Path $repo "config\users.htpasswd"
if ($DryRun) { Note "Would make the login '$Login' with a random password." }
else {
    # hashed (bcrypt) inside the container; only the hash is stored on this PC
    $hash = $password | docker exec -i rar2fs htpasswd -niB $Login | Where-Object { $_ -match ':' }
    if (-not $hash) { Stop-Setup "Could not create the login." }
    $others = @()
    if (Test-Path $usersFile) { $others = @([IO.File]::ReadAllLines($usersFile) | Where-Object { $_ -notmatch "^$([regex]::Escape($Login)):" }) }
    if (-not (Test-Path (Split-Path $usersFile -Parent))) { New-Item -ItemType Directory -Path (Split-Path $usersFile -Parent) | Out-Null }
    [IO.File]::WriteAllLines($usersFile, [string[]]($others + $hash))
    Note "Made the login '$Login' with a random password (a login of that name from an earlier run stops working)."
}

# ---------------------------------------------------------------- firewall
Step "Windows Firewall on this PC"
if (Get-NetFirewallRule -DisplayName "rar2fs-dock" -ErrorAction SilentlyContinue) { Note "The rule is already there." }
elseif ($DryRun) { Note "Would add a rule allowing ports 8765-8767 on private networks." }
else {
    Note "Adding a rule for ports 8765-8767. Windows will ask for permission."
    # single quotes inside: the command passes through two layers of argument parsing
    $rule = "New-NetFirewallRule -DisplayName 'rar2fs-dock' -Direction Inbound -Protocol TCP -LocalPort 8765-8767 -Action Allow -Profile Private | Out-Null"
    try { Start-Process powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "-NoProfile", "-Command", $rule } catch { }
    if (Get-NetFirewallRule -DisplayName "rar2fs-dock" -ErrorAction SilentlyContinue) { Note "Added." }
    else { Note "The rule was NOT added. In an administrator PowerShell, run:"; Note "  $rule" }
}

# ---------------------------------------------------------------- restart
if (-not $DryRun) {
    Step "Restarting the container with the new settings"
    Note "The drive on this PC drops out for a minute and comes back by itself."
    Push-Location $repo
    $ErrorActionPreference = 'Continue'
    try {
        if ($envChanged) { docker compose up -d 2>&1 | Out-Null } else { docker compose restart 2>&1 | Out-Null }
        if ($LASTEXITCODE -ne 0) { Stop-Setup "Docker could not restart the container. Try: docker compose up -d" }
    } finally { $ErrorActionPreference = 'Stop'; Pop-Location }
    $deadline = (Get-Date).AddMinutes(5); $state = ""
    while ((Get-Date) -lt $deadline) {
        $state = [string](Invoke-Docker inspect --format '{{.State.Health.Status}}' rar2fs)
        if ($state -eq "healthy") { break }
        Start-Sleep -Seconds 5
    }
    if ($state -ne "healthy") { Stop-Setup "The container isn't healthy yet ($state). Look at: docker logs rar2fs" }
    Note "The container is healthy."
    if ($certChanges) { Note "The certificate is new. Devices that already connect (a Linux server, another PC) need the new tls\cert.pem." }
}

# ---------------------------------------------------------------- the folder for the Plex PC
Step "Making the folder for the Plex PC"
$scheme = if ($tlsOn) { "https" } else { "http" }
$port = if ((Get-EnvValue $envLines "SHORT_PATHS") -eq "1") { 8767 } else { 8765 }     # 8767 = names shortened to fit Windows
$serverUrl = "${scheme}://${thisPc}:$port"
$stage = Join-Path ([IO.Path]::GetTempPath()) ("rar2fs-dock-plex-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path (Join-Path $stage "windows") | Out-Null
foreach ($name in "mount.ps1", "install-autostart.ps1", "uninstall-autostart.ps1", "client-setup.ps1") {
    Copy-Item (Join-Path $PSScriptRoot $name) (Join-Path $stage "windows")
}
if ($tlsOn) {
    $cert = Join-Path $repo "tls\cert.pem"
    if (-not (Test-Path $cert)) { Stop-Setup "tls\cert.pem is missing - has the container started with HTTPS on?" }
    New-Item -ItemType Directory -Path (Join-Path $stage "tls") | Out-Null
    Copy-Item $cert (Join-Path $stage "tls")          # the certificate only - never the key
}
$clientEnv = @("# Login for the rar2fs-dock server at $serverUrl - made by connect-plex.ps1", "WEBDAV_USER=$Login", "WEBDAV_PASS=$password")
if (-not $tlsOn) { $clientEnv += "TLS=0" }
[IO.File]::WriteAllText((Join-Path $stage ".env"), (($clientEnv -join "`r`n") + "`r`n"), $utf8)
$cmd = @(
    "@echo off",
    "rem Sets up the $Drive drive on this PC. Made by connect-plex.ps1 on the server PC.",
    "powershell -NoProfile -ExecutionPolicy Bypass -File `"%~dp0windows\client-setup.ps1`" -Url `"$serverUrl`" -Drive $Drive -Folders `"$($folders -join ',')`"",
    "echo.",
    "pause"
)
[IO.File]::WriteAllText((Join-Path $stage "Setup.cmd"), (($cmd -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
$readme = @(
    "rar2fs-dock - folder for the PC that runs Plex",
    "",
    "1. Log in to this PC as the Windows user that Plex runs as.",
    "2. Double-click Setup.cmd in this folder. It installs WinFsp and rclone if they",
    "   are missing, mounts the server's folders as $Drive and brings the drive back at",
    "   every login.",
    "3. In Plex, add these folders to your libraries:",
    ""
) + ($folders | ForEach-Object { "       $Drive\$_" }) + @(
    "",
    "Server: $serverUrl   (the PC at $thisPc has to be on, with Docker Desktop running)",
    "Keep this folder: the drive uses the scripts and the login in it.",
    "To remove the drive: windows\uninstall-autostart.ps1"
)
[IO.File]::WriteAllText((Join-Path $stage "READ-ME.txt"), (($readme -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
Note "Scripts, certificate, the login and a Setup.cmd for $serverUrl."

# ---------------------------------------------------------------- copy it over
function Copy-Folder($from, $to, $credential) {
    try {
        if ($credential) {
            $share = ($to -split '\\' | Where-Object { $_ } | Select-Object -First 2) -join '\'
            New-PSDrive -Name rar2fsCopy -PSProvider FileSystem -Root "\\$share" -Credential $credential -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $to)) { New-Item -ItemType Directory -Path $to -ErrorAction Stop | Out-Null }
        Copy-Item (Join-Path $from "*") $to -Recurse -Force -ErrorAction Stop
        return ""
    } catch { return $_.Exception.Message }
    finally { if ($credential) { Remove-PSDrive rar2fsCopy -ErrorAction SilentlyContinue } }
}
# where a path on the Plex PC's network share is when you sit at that PC
function Get-LocalName($unc) {
    if ($unc -match '^\\\\[^\\]+\\([A-Za-z])\$\\?(.*)$') { return ("{0}:\{1}" -f $Matches[1].ToUpper(), $Matches[2]).TrimEnd('\') }
    return ""
}

$placed = ""
if (-not $NoCopy) {
    Step "Copying it to the Plex PC"
    $target = if ($CopyTo) { Join-Path $CopyTo "rar2fs-dock" } else { "\\$PlexHost\C$\rar2fs-dock" }
    $credential = $null
    while ($true) {
        Note "Trying $target ..."
        $problem = Copy-Folder $stage $target $credential
        if (-not $problem) { $placed = $target; break }
        Note "That didn't work: $problem"
        Note ""
        Note "  1  sign in with an administrator account of the Plex PC and try again"
        Note "  2  copy to a shared folder on the Plex PC instead (for example \\$PlexHost\Shared)"
        Note "  3  skip - leave the folder on this PC and I'll carry it over myself"
        Note "(Windows often refuses option 1 for ordinary accounts on home PCs. A shared folder always works:"
        Note " on the Plex PC, right-click any folder > Properties > Sharing > Share, with permission to change.)"
        $choice = Ask "Choose 1, 2 or 3" "2"
        if ($choice -eq '1') { $credential = Get-Credential -Message "An administrator account of $PlexHost" }
        elseif ($choice -eq '2') {
            $share = Ask "Shared folder" "\\$PlexHost\Shared"
            $target = Join-Path $share "rar2fs-dock"
            if (AskYesNo "Does that share need a different user name and password than yours?" $false) { $credential = Get-Credential -Message "A login for $share" } else { $credential = $null }
        }
        else { break }
    }
}
if (-not $placed) {
    $local = Join-Path ([Environment]::GetFolderPath('MyDocuments')) "rar2fs-dock-plex"
    if (Test-Path $local) { [IO.Directory]::Delete($local, $true) }
    Copy-Item $stage $local -Recurse
}
[IO.Directory]::Delete($stage, $true)

# ---------------------------------------------------------------- what's left
Step "What's left - on the Plex PC"
if ($placed) {
    $there = Get-LocalName $placed
    if ($there) { Note "The folder is on the Plex PC at:   $there" }
    else { Note "The folder is in the shared folder:   $placed"; Note "(on the Plex PC, that is the folder you shared, with 'rar2fs-dock' inside it)" }
} else {
    Note "The folder is on THIS PC at:   $local"
    Note "Copy the whole folder to the Plex PC (USB stick, network, anything) - for example to C:\rar2fs-dock."
    Note "It holds a password, so delete this copy afterwards."
}
Note ""
Note "1. On the Plex PC, log in as the Windows user Plex runs as and open that folder."
Note "2. Double-click Setup.cmd. It installs what's missing and mounts the drive as $Drive."
Note "3. In Plex, add the folders to your libraries (Manage Library > Edit > Add folders):"
foreach ($name in $folders) { Note "       $Drive\$name" }
if (-not $plexReady) {
    Note "4. In Plex: Settings > Library, turn OFF 'Empty trash automatically after every scan'."
    Note "   New files appear at Plex's next scan. For instant refresh, run this again and choose a token."
} else {
    Note "Plex's trash setting is done, and Plex is told about new files as they arrive."
}
Note ""
Note "The same steps are in READ-ME.txt in the folder. To check this PC's side: .\windows\doctor.ps1"
