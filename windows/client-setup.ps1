# Sets up the drive on ANOTHER Windows PC - one that has no container of its own and
# connects to the PC that does (for example the PC Plex runs on).
#
# You normally don't run this by hand: connect-plex.ps1 on the server PC copies a folder
# to this PC with a Setup.cmd in it that runs this with the right address. The folder
# must hold, next to this "windows" folder:
#     .env            two lines: WEBDAV_USER=... and WEBDAV_PASS=...
#     tls\cert.pem    the server's certificate (not needed for an http:// address)
#
#     .\windows\client-setup.ps1 -Url https://192.168.1.10:8765 -Drive Y: -Folders "tv,films"
param(
    [Parameter(Mandatory)][string]$Url,   # the server PC's address and port
    [string]$Drive = "Y:",
    [string]$Folders = ""                  # the folders on the drive, to list at the end
)

$root = Split-Path $PSScriptRoot -Parent
function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Note($text) { Write-Host "   $text" }
function Stop-Setup($text) { Write-Host ""; Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }
function Invoke-Winget($id, $what) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Stop-Setup "$what is not installed, and winget isn't available to install it. Install $what, then run this again."
    }
    Note "Installing $what (Windows may ask for permission)..."
    winget install -e --id $id --accept-source-agreements --accept-package-agreements | Out-Null
    if ($LASTEXITCODE -ne 0) { Stop-Setup "Installing $what failed. Install it yourself (winget install $id), then run this again." }
}
$Drive = $Drive.Substring(0, 1).ToUpper() + ":"

Step "Checking this folder"
if (-not (Test-Path (Join-Path $root ".env"))) { Stop-Setup "There is no .env file in $root. Copy the whole folder from the server PC again." }
if ($Url -like "https://*" -and -not (Test-Path (Join-Path $root "tls\cert.pem"))) {
    Stop-Setup "There is no tls\cert.pem in $root. Copy the whole folder from the server PC again."
}
Note "The login and the certificate are here."

Step "Checking what's needed"
$winfsp = @("${env:ProgramFiles(x86)}\WinFsp", "$env:ProgramFiles\WinFsp") | Where-Object { Test-Path (Join-Path $_ "bin") }
if (-not $winfsp) { Invoke-Winget "WinFsp.WinFsp" "WinFsp" } else { Note "WinFsp is installed." }
$rcloneFound = (Get-Command rclone -ErrorAction SilentlyContinue) -or
    (Test-Path (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\rclone.exe"))
if (-not $rcloneFound) { Invoke-Winget "Rclone.Rclone" "rclone" } else { Note "rclone is installed." }

Step "Checking the server PC answers"
$address = [Uri]$Url
$client = New-Object Net.Sockets.TcpClient
try { $reached = $client.BeginConnect($address.Host, $address.Port, $null, $null).AsyncWaitHandle.WaitOne(4000) -and $client.Connected } catch { $reached = $false }
$client.Close()
if (-not $reached) {
    Stop-Setup ("Nothing answers at $($address.Host) port $($address.Port). Check that the server PC is on, that Docker Desktop is running " +
        "there, and that its firewall rule exists (on the server PC: .\windows\connect-plex.ps1 adds it).")
}
Note "$($address.Host) answers."

Step "Mounting $Drive"
& (Join-Path $PSScriptRoot "uninstall-autostart.ps1") | Out-Null
Start-Sleep -Seconds 2
if (Test-Path "$Drive\") {
    Stop-Setup ("$Drive is already used by something else on this PC. On the server PC, run " +
        ".\windows\connect-plex.ps1 -Drive X: (with a letter that is free here) to make a new folder for this PC.")
}
& (Join-Path $PSScriptRoot "install-autostart.ps1") -Drive $Drive -Url $Url | Out-Null
$deadline = (Get-Date).AddSeconds(90)
while (-not (Test-Path "$Drive\") -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
if (-not (Test-Path "$Drive\")) {
    Stop-Setup "The drive hasn't appeared. To see why, run:  .\windows\mount.ps1 -Drive $Drive -Url $Url"
}
Note "$Drive is mounted and will come back every time you log in."

Step "All set - what to do in Plex"
Note "1. Settings > Library: turn OFF 'Empty trash automatically after every scan'."
Note "   (connect-plex.ps1 already did this if it had a Plex token.)"
Note "2. Add the drive's folders to your libraries (Manage Library > Edit > Add folders)."
Note "   If $Drive isn't shown in the folder browser, type the path in:"
$names = @($Folders -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $names) { $names = @(Get-ChildItem "$Drive\" -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
foreach ($name in $names) { Note "       $Drive\$name" }
Note "3. Scan the libraries. The first scan is slower than on a normal disk."
Note ""
Note "Plex has to run as the Windows user you are logged in as now - the normal installation"
Note "does. To remove the drive again: .\windows\uninstall-autostart.ps1"
