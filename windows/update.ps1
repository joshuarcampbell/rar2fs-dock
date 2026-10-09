# Updates rar2fs-dock in one go:
#   1. pulls the latest version
#   2. rebuilds and restarts the container, and waits until it is healthy
#   3. remounts the drive, if the mount scripts or the certificate changed
#   4. tells you if other devices (a Linux Plex server, say) need anything
#
# Run it from a normal PowerShell, in the repo folder:
#     .\windows\update.ps1
#
# Coming from an older version that kept your folders in docker-compose.yml? It moves
# them into docker-compose.override.yml first, so the update can't overwrite them.
param(
    [switch]$NoPull,      # rebuild and restart what is already here
    [switch]$NoStart      # pull (and move folders) only; don't touch the container or the drive
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$utf8 = New-Object System.Text.UTF8Encoding $false
function Step($text) { Write-Host ""; Write-Host "== $text" -ForegroundColor Cyan }
function Note($text) { Write-Host "   $text" }
function Stop-Update($text) { Write-Host ""; Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }
function Git { & git.exe -C $repo @args }
# Runs a docker command quietly and says whether it worked. (With errors set to stop the
# script, PowerShell would otherwise abort on anything docker prints as a warning.)
function Test-Docker {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { & docker @args 2>&1 | Out-Null; return ($LASTEXITCODE -eq 0) } catch { return $false } finally { $ErrorActionPreference = $previous }
}
function Get-Health {
    $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
    try { return [string](& docker inspect --format '{{.State.Health.Status}}' rar2fs 2>$null) } catch { return "" } finally { $ErrorActionPreference = $previous }
}
function Get-CertPrint {
    $cert = Join-Path $repo "tls\cert.pem"
    if (Test-Path $cert) { return (Get-FileHash $cert -Algorithm SHA256).Hash }
    return ""
}

if (-not (Get-Command git -ErrorAction SilentlyContinue)) { Stop-Update "git is not installed (winget install Git.Git)." }
if (-not (Test-Path (Join-Path $repo ".git"))) { Stop-Update "$repo is not a git checkout, so there is nothing to pull. Download the new version and copy your .env and docker-compose.override.yml across." }

$before = (Git rev-parse HEAD).Trim()
$certBefore = Get-CertPrint

# ---------------------------------------------------------------- folders in the old place
# Older versions had you list your folders in docker-compose.yml itself. That file is
# replaced by updates, so move the folders to docker-compose.override.yml first.
$compose = Join-Path $repo "docker-compose.yml"
$override = Join-Path $repo "docker-compose.override.yml"
$changed = @(Git status --porcelain --untracked-files=no | ForEach-Object { $_.Substring(3).Trim('"') })
if ($changed -contains "docker-compose.yml") {
    Step "Moving your folders out of docker-compose.yml"
    if (Test-Path $override) {
        Stop-Update ("docker-compose.yml has changes of yours, and docker-compose.override.yml already exists. " +
            "Move what you need into the override file by hand, then run: git checkout -- docker-compose.yml")
    }
    $lines = Get-Content $compose
    $sources = @($lines | Where-Object { $_ -match '^\s*-\s' -and $_ -notmatch '^\s*#' -and $_ -match ':/sources/' })
    # everything from the first top-level x-... or volumes: line: the network shares
    $start = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^(x-[\w-]+|volumes):') { $start = $i; break } }
    $shares = @()
    if ($start -ge 0) {
        $shares = @($lines[$start..($lines.Count - 1)] | Where-Object { $_ -notmatch '^\s*#' -and $_ -notmatch '^\s+state:\s*$' -and $_.Trim() })
        if (-not ($shares | Where-Object { $_ -match '^\s+\S' })) { $shares = @() }      # only "volumes:" left
    }
    if ($sources.Count -eq 0) {
        Stop-Update "docker-compose.yml has changes of yours, but no folder lines I recognise. Save what you need, then run: git checkout -- docker-compose.yml"
    }
    $file = @(
        "# Your media folders - moved here from docker-compose.yml by windows\update.ps1.",
        "# Docker merges this file with docker-compose.yml automatically, and it is gitignored.",
        "services:",
        "  rar2fs:",
        "    volumes:"
    ) + ($sources | ForEach-Object { "      " + $_.Trim() })
    if ($shares) { $file += @("", "# Network shares") + $shares }
    [System.IO.File]::WriteAllText($override, (($file -join "`n") + "`n"), $utf8)
    Copy-Item $compose (Join-Path $repo "docker-compose.yml.before-update") -Force
    Git checkout -- docker-compose.yml
    Note "Moved $($sources.Count) folder line(s)$(if ($shares) { ' and your network shares' }) to docker-compose.override.yml."
    Note "Your old file is kept as docker-compose.yml.before-update, in case anything is missing."
    $changed = @($changed | Where-Object { $_ -ne "docker-compose.yml" })
}
if ($changed -and -not $NoPull) {
    Stop-Update ("You have changed these files, and the update would overwrite them: " + ($changed -join ", ") +
        ". Undo your changes (git checkout -- <file>) or keep them elsewhere, then run this again.")
}

# ---------------------------------------------------------------- pull
if (-not $NoPull) {
    Step "Getting the latest version"
    Git pull --ff-only
    if ($LASTEXITCODE -ne 0) { Stop-Update "git pull failed - see the message above." }
}
$after = (Git rev-parse HEAD).Trim()
$files = @()
if ($after -ne $before) {
    $files = @(Git diff --name-only $before $after)
    Note "Updated: $(@(Git log --oneline "$before..$after").Count) change(s), $($files.Count) file(s)."
    Git log --oneline "$before..$after" | Select-Object -First 8 | ForEach-Object { Note "  $_" }
} elseif (-not $NoPull) {
    Note "Already up to date."
}

if ($NoStart) { Step "Done (files only)"; exit 0 }
if (-not (Test-Path (Join-Path $repo ".env"))) { Stop-Update "There is no .env yet. Run .\windows\setup.ps1 first." }

# ---------------------------------------------------------------- rebuild
Step "Rebuilding and restarting the container"
if (-not (Test-Docker version)) { Stop-Update "Docker Desktop is not running. Start it, then run this again." }
Push-Location $repo
try {
    docker compose up -d --build
    if ($LASTEXITCODE -ne 0) { Stop-Update "Docker could not start the container - see the messages above." }
} finally { Pop-Location }
Note "Waiting for it to report healthy..."
$deadline = (Get-Date).AddMinutes(5); $state = ""
while ((Get-Date) -lt $deadline) {
    $state = Get-Health
    if ($state -eq "healthy") { break }
    Start-Sleep -Seconds 5
}
if ($state -ne "healthy") { Stop-Update "The container started but isn't healthy yet ($state). Look at: docker logs rar2fs" }
Note "The container is healthy."

# ---------------------------------------------------------------- drive
$certAfter = Get-CertPrint
$certChanged = ($certAfter -ne $certBefore) -and $certBefore
$task = Get-ScheduledTask -TaskName "rar2fs-dock mount" -ErrorAction SilentlyContinue
$mountChanged = [bool]($files | Where-Object { $_ -match '^windows/(mount|install-autostart)\.ps1$' })
if ($task -and ($mountChanged -or $certChanged)) {
    Step "Remounting the drive"
    $taskArgs = $task.Actions.Arguments
    $remount = @{}
    if ($taskArgs -match '-Drive ([A-Za-z]:)') { $remount.Drive = $Matches[1] }
    if ($taskArgs -match '-Url (\S+)') { $remount.Url = $Matches[1] }
    if ($taskArgs -match '-Original') { $remount.Original = $true }
    & (Join-Path $PSScriptRoot "uninstall-autostart.ps1") | Out-Null
    & (Join-Path $PSScriptRoot "install-autostart.ps1") @remount | Out-Null
    Note "Remounted $($remount.Drive) ($(if ($certChanged) { 'the certificate changed' } else { 'the mount scripts changed' }))."
} elseif ($task) {
    Note "The drive didn't need remounting."
}

# ---------------------------------------------------------------- other devices
Step "Done"
$notes = @()
if ($files | Where-Object { $_ -match '^linux/' }) {
    $notes += "Files for Linux machines changed (linux\). Copy rar2fs@.service to them again and restart their mounts - see the README, 'Plex on Linux'."
}
if ($certChanged) {
    $notes += "The HTTPS certificate changed. Other devices need the new tls\cert.pem - see the README, 'HTTPS'."
}
if ($files -contains ".env.example") { $notes += "New settings are available - compare .env.example with your .env, or see 'Settings' in the README." }
if ($notes) { $notes | ForEach-Object { Note "NOTE: $_" } } else { Note "Nothing else to do." }
