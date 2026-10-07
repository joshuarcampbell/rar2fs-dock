# Mounts the rar2fs container's WebDAV view as a Windows drive letter using rclone + WinFsp.
# Runs in the foreground; close the window (or Ctrl+C) to unmount.
param(
    [string]$Drive = "Y:",
    [string]$Url = "",   # default: http(s)://localhost:8765, depending on TLS in ..\.env
    [string]$User = "",
    [string]$Pass = ""
)

$rclone = (Get-Command rclone -ErrorAction SilentlyContinue).Source
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

# Settings shared with the container (..\.env): login, and whether HTTPS is on
$envFile = Join-Path $PSScriptRoot "..\.env"
$envUser = ""; $envPass = ""; $tls = $false
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*WEBDAV_USER\s*=\s*(.*)$') { $envUser = $Matches[1].Trim() }
        if ($line -match '^\s*WEBDAV_PASS\s*=\s*(.*)$') { $envPass = $Matches[1].Trim() }
        if ($line -match '^\s*TLS\s*=\s*1\s*$') { $tls = $true }
    }
}
if (-not $User) { $User = $envUser; $Pass = $envPass }
if (-not $Url) { $Url = if ($tls) { "https://localhost:8765" } else { "http://localhost:8765" } }

$rcloneArgs = @(
    "mount", ":webdav:", $Drive,
    "--webdav-url", $Url,
    "--read-only",
    "--network-mode",
    # Network name must be unique per mount (\\server\rar2fs-K), or a second mount fails
    "--volname", ("rar2fs-" + $Drive.TrimEnd(':')),
    "--dir-cache-time", "1m",
    "--vfs-cache-mode", "off"
)
# HTTPS with the container's self-signed certificate: trust exactly that certificate
$cert = Join-Path $PSScriptRoot "..\tls\cert.pem"
if ($Url -like "https://*" -and (Test-Path $cert)) {
    $rcloneArgs += @("--ca-cert", (Resolve-Path $cert).Path)
}

# Credentials go through env vars so they don't show up in the process list
if ($User) {
    $env:RCLONE_WEBDAV_USER = $User
    $env:RCLONE_WEBDAV_PASS = ($Pass | & $rclone obscure -)
}

& $rclone @rcloneArgs
