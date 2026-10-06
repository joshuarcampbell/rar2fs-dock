# Mounts the rar2fs container's WebDAV view as a Windows drive letter using rclone + WinFsp.
# Runs in the foreground; close the window (or Ctrl+C) to unmount.
param(
    [string]$Drive = "K:",
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

$rcloneArgs = @(
    "mount", ":webdav:", $Drive,
    "--webdav-url", $Url,
    "--read-only",
    "--network-mode",
    "--volname", "rar2fs",
    "--dir-cache-time", "1m",
    "--vfs-cache-mode", "off"
)
if ($User) {
    $rcloneArgs += @("--webdav-user", $User, "--webdav-pass", (& $rclone obscure $Pass))
}

& $rclone @rcloneArgs
