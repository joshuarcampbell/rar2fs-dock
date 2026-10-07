# Mounts the rar2fs container's WebDAV view as a Windows drive letter using rclone + WinFsp.
# Runs in the foreground; close the window (or Ctrl+C) to unmount.
param(
    [string]$Drive = "Y:",
    [string]$Url = "",   # default: this PC's server, chosen from the settings in ..\.env
    [string]$User = "",
    [string]$Pass = "",
    [switch]$Original    # use the full-length names even when SHORT_PATHS=1 in ..\.env
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

# Settings shared with the container (..\.env): login, and the short-names view
$envFile = Join-Path $PSScriptRoot "..\.env"
$envUser = ""; $envPass = ""; $short = $false
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*WEBDAV_USER\s*=\s*(.*)$') { $envUser = $Matches[1].Trim() }
        if ($line -match '^\s*WEBDAV_PASS\s*=\s*(.*)$') { $envPass = $Matches[1].Trim() }
        if ($line -match '^\s*SHORT_PATHS\s*=\s*1\s*$') { $short = $true }
    }
}
if (-not $User) { $User = $envUser; $Pass = $envPass }
if (-not $Url) {
    # 8765 = full names; 8767 = names shortened to fit Windows' path limit
    $port = if ($short -and -not $Original) { 8767 } else { 8765 }
    $Url = "http://localhost:$port"
}

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
# Credentials go through env vars so they don't show up in the process list
if ($User) {
    $env:RCLONE_WEBDAV_USER = $User
    $env:RCLONE_WEBDAV_PASS = ($Pass | & $rclone obscure -)
}

& $rclone @rcloneArgs
