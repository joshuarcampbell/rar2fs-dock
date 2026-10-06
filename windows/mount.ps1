# Mounts the rar2fs container's WebDAV view as a Windows drive letter using rclone + WinFsp.
# Runs in the foreground; close the window (or Ctrl+C) to unmount.
param(
    [string]$Drive = "Y:",
    [string]$Url = "http://localhost:8765",
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

# Without -User/-Pass, use the same credentials as the container (from ..\.env)
$envFile = Join-Path $PSScriptRoot "..\.env"
if (-not $User -and (Test-Path $envFile)) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*WEBDAV_USER\s*=\s*(.*)$') { $User = $Matches[1].Trim() }
        if ($line -match '^\s*WEBDAV_PASS\s*=\s*(.*)$') { $Pass = $Matches[1].Trim() }
    }
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
