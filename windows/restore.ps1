# Puts back what backup.ps1 saved: .env, your folder list, extra logins and the HTTPS
# certificate. Use it on this PC, or on a new one after cloning the repo.
#
#     .\windows\restore.ps1 -File C:\Users\you\Documents\rar2fs-dock-backup-20260101-1200.zip
#
# It won't overwrite files that are already here unless you add -Force.
# Afterwards run .\windows\setup.ps1, which keeps the restored files and does the rest.
param(
    [Parameter(Mandatory)][string]$File,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
if (-not (Test-Path $File)) { Write-Host "No such file: $File" -ForegroundColor Red; exit 1 }

$stage = Join-Path ([IO.Path]::GetTempPath()) ("rar2fs-dock-restore-" + [Guid]::NewGuid().ToString("N"))
Expand-Archive -Path $File -DestinationPath $stage
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
    Write-Host "Next: .\windows\setup.ps1   (it keeps these files, starts the container and mounts the drive)"
} finally {
    [IO.Directory]::Delete($stage, $true)
}
