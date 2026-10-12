# Saves everything that is yours into one zip file - or puts such a zip back - so the
# setup can be restored on this PC or moved to another:
#   .env                          your settings and passwords
#   docker-compose.override.yml   your folder list
#   config\                       extra logins, folders added without a restart, archive passwords
#   tls\                          the HTTPS certificate and its private key
#
#     .\rar2fs.ps1 backup                   -> a zip in your Documents folder
#     .\rar2fs.ps1 backup D:\Backups        -> a zip in that folder
#     .\rar2fs.ps1 restore <the zip>        put it back (add -Force to replace files
#                                           that are already here)
#
# The zip contains passwords and a private key. Keep it somewhere private.
# After a restore run .\rar2fs.ps1 setup, which keeps the restored files and does the
# rest (on a new PC: clone the repo first).
param(
    [string]$To = [Environment]::GetFolderPath('MyDocuments'),   # where the backup goes
    [string]$Restore = "",                                        # a backup zip to put back
    [switch]$Force                                                # with -Restore: replace existing files
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent

# ---------------------------------------------------------------- restore
if ($Restore) {
    if (-not (Test-Path $Restore)) { Write-Host "No such file: $Restore" -ForegroundColor Red; exit 1 }
    $stage = Join-Path ([IO.Path]::GetTempPath()) ("rar2fs-dock-restore-" + [Guid]::NewGuid().ToString("N"))
    Expand-Archive -Path $Restore -DestinationPath $stage
    try {
        $files = @(Get-ChildItem $stage -Recurse -File -Force)
        if (-not ($files | Where-Object { $_.Name -eq ".env" })) {
            Write-Host "That doesn't look like a rar2fs-dock backup (no .env inside)." -ForegroundColor Red; exit 1
        }
        $plan = foreach ($f in $files) {
            $relative = $f.FullName.Substring($stage.Length).TrimStart('\')
            [pscustomobject]@{ Relative = $relative; Source = $f.FullName; Target = (Join-Path $repo $relative) }
        }
        $existing = @($plan | Where-Object { Test-Path $_.Target })
        if ($existing -and -not $Force) {
            Write-Host "These are already here and would be replaced:" -ForegroundColor Yellow
            $existing | ForEach-Object { Write-Host "   $($_.Relative)" }
            Write-Host "Nothing was changed. Run again with -Force to replace them."
            exit 1
        }
        foreach ($entry in $plan) {
            $folder = Split-Path $entry.Target -Parent
            if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
            Copy-Item $entry.Source $entry.Target -Force
        }
        Write-Host "Restored: $(($plan | ForEach-Object { $_.Relative }) -join ', ')"
        Write-Host "Next: .\rar2fs.ps1 setup   (it keeps these files, starts the container and mounts the drive)"
    } finally {
        [IO.Directory]::Delete($stage, $true)
    }
    exit 0
}

# ---------------------------------------------------------------- backup
if (-not (Test-Path $To)) { New-Item -ItemType Directory -Path $To | Out-Null }

$wanted = @(".env", "docker-compose.override.yml", "config", "tls")
$found = @($wanted | Where-Object { Test-Path (Join-Path $repo $_) })
if (-not ($found -contains ".env")) { Write-Host "There is no .env here yet, so there is nothing worth backing up." -ForegroundColor Red; exit 1 }

# stage a copy, so the zip has the same layout as the repo
$stage = Join-Path ([IO.Path]::GetTempPath()) ("rar2fs-dock-backup-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    foreach ($item in $found) {
        Copy-Item (Join-Path $repo $item) (Join-Path $stage $item) -Recurse -Force
    }
    $keep = Join-Path $stage "config\.gitkeep"
    if (Test-Path $keep) { [IO.File]::Delete($keep) }
    $zip = Join-Path $To ("rar2fs-dock-backup-" + (Get-Date -Format "yyyyMMdd-HHmm") + ".zip")
    if (Test-Path $zip) { [IO.File]::Delete($zip) }
    Compress-Archive -Path (Join-Path $stage "*") -DestinationPath $zip
} finally {
    [IO.Directory]::Delete($stage, $true)
}

Write-Host "Backed up: $($found -join ', ')"
Write-Host "Saved to:  $zip"
Write-Host "It contains your passwords and the certificate's private key - keep it private."
Write-Host "To restore: .\rar2fs.ps1 restore `"$zip`""
