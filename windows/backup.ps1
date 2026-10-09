# Saves everything that is yours into one zip file, so the setup can be restored on
# this PC or moved to another:
#   .env                          your settings and passwords
#   docker-compose.override.yml   your folder list
#   config\                       extra logins, folders added without a restart
#   tls\                          the HTTPS certificate and its private key
#
#     .\windows\backup.ps1                  -> a zip in your Documents folder
#     .\windows\backup.ps1 -To D:\Backups
#
# The zip contains passwords and a private key. Keep it somewhere private.
param(
    [string]$To = [Environment]::GetFolderPath('MyDocuments')
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
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
Write-Host "To restore: .\windows\restore.ps1 -File `"$zip`""
