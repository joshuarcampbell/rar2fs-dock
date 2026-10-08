# Mounts the rar2fs container's WebDAV view as a Windows drive letter using rclone + WinFsp.
# Runs in the foreground; close the window (or Ctrl+C) to unmount.
#
# It waits until the server answers before the drive letter appears. After a restart,
# Windows logs in before Docker is ready; without the wait, programs that start at
# login (Plex, for one) would find an empty drive.
param(
    [string]$Drive = "Y:",
    [string]$Url = "",   # default: this PC's server, chosen from the settings in ..\.env
    [string]$User = "",
    [string]$Pass = "",
    [switch]$Original,   # use the full-length names even when SHORT_PATHS=1 in ..\.env
    [switch]$NoWait      # mount straight away, even if the server isn't answering yet
)

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
if (-not $rclone) {
    # Just installed with winget? It isn't on PATH until a new window is opened.
    $wingetLink = Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\rclone.exe"
    if (Test-Path $wingetLink) { $rclone = $wingetLink }
}
if (-not $rclone) {
    Write-Error "rclone not found. Install it with: winget install Rclone.Rclone"
    exit 1
}

if (Test-Path "$Drive\") {
    Write-Error "$Drive is already in use. Pick a free letter with -Drive, e.g. -Drive M:"
    exit 1
}

$running = Get-CimInstance Win32_Process -Filter "Name = 'rclone.exe'" |
    Where-Object { $_.CommandLine -like "*:webdav:*" }
if ($running) {
    Write-Warning ("A rar2fs drive is already mounted (probably by the login task). To switch " +
        "letters, run .\windows\uninstall-autostart.ps1 then .\windows\install-autostart.ps1 -Drive $Drive")
}

# Settings shared with the container (..\.env): login, HTTPS, and the short-names view
$envFile = Join-Path $PSScriptRoot "..\.env"
$envUser = ""; $envPass = ""
$tls = $true       # HTTPS unless .env says TLS=0
$short = $false    # full names unless .env says SHORT_PATHS=1
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*WEBDAV_USER\s*=\s*(.*)$') { $envUser = $Matches[1].Trim() }
        if ($line -match '^\s*WEBDAV_PASS\s*=\s*(.*)$') { $envPass = $Matches[1].Trim() }
        if ($line -match '^\s*TLS\s*=\s*0\s*$') { $tls = $false }
        if ($line -match '^\s*SHORT_PATHS\s*=\s*1\s*$') { $short = $true }
    }
}
if (-not $User) { $User = $envUser; $Pass = $envPass }
if (-not $Url) {
    # 8765 = full names; 8767 = names shortened to fit Windows' path limit
    $scheme = if ($tls) { "https" } else { "http" }
    $port = if ($short -and -not $Original) { 8767 } else { 8765 }
    $Url = "${scheme}://localhost:$port"
}

# Where to connect, shared by the readiness check and the mount
function Get-ConnectionArgs {
    $connection = @("--webdav-url", $Url)
    # HTTPS with the container's self-signed certificate: trust exactly that certificate.
    # Looked up each time, because on a first start the container may not have made it yet.
    $cert = Join-Path $PSScriptRoot "..\tls\cert.pem"
    if ($Url -like "https://*" -and (Test-Path $cert)) {
        $connection += @("--ca-cert", (Resolve-Path $cert).Path)
    }
    return $connection
}

# Credentials go through env vars so they don't show up in the process list
if ($User) {
    $env:RCLONE_WEBDAV_USER = $User
    $env:RCLONE_WEBDAV_PASS = ($Pass | & $rclone obscure -)
}

# Wait for the server
if (-not $NoWait) {
    $waited = 0
    while ($true) {
        $answer = (& $rclone lsd ":webdav:" @(Get-ConnectionArgs) --contimeout 5s --timeout 15s --retries 1 --low-level-retries 1 2>&1 | Out-String)
        if ($LASTEXITCODE -eq 0) { break }
        if ($answer -match '401|Unauthorized') {
            Write-Error "The server at $Url rejected the login. Check WEBDAV_USER / WEBDAV_PASS in .env (or -User / -Pass)."
            exit 1
        }
        if ($waited -eq 0) {
            Write-Host "Waiting for the rar2fs container to answer at $Url ..."
        } elseif ($waited % 60 -eq 0) {
            $last = ($answer.Trim() -split "`n" | Select-Object -Last 1).Trim()
            Write-Host "Still waiting after $([int]($waited / 60)) min - is Docker Desktop running? Last answer: $last"
        }
        Start-Sleep -Seconds 5
        $waited += 5
    }
    if ($waited -gt 0) { Write-Host "The server is answering. Mounting $Drive" }
}

$rcloneArgs = @(
    "mount", ":webdav:", $Drive
) + (Get-ConnectionArgs) + @(
    "--read-only",
    "--network-mode",
    # Network name must be unique per mount (\\server\rar2fs-K), or a second mount fails
    "--volname", ("rar2fs-" + $Drive.TrimEnd(':')),
    "--dir-cache-time", "1m",
    "--vfs-cache-mode", "off"
)

& $rclone @rcloneArgs
