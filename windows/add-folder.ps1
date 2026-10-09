# Adds a folder to the drive (or removes one) while the container keeps running.
#
#     .\windows\add-folder.ps1 -Path E:\Concerts                 -> Y:\concerts
#     .\windows\add-folder.ps1 -Path E:\More-TV -Name tv         joins the existing "tv" folder
#     .\windows\add-folder.ps1 -Remove concerts
#     .\windows\add-folder.ps1 -List
#
# How it works: Docker can't attach a new Windows folder to a running container. But
# once a whole drive is visible to the container (at /drives/<letter>, read-only), any
# folder on it can be added or removed without a restart. So:
#   - if the drive is already visible, the folder appears within a few seconds;
#   - if not, this offers to make the drive visible, which restarts the container once.
#     After that, further folders on that drive need no restart.
#
# Making a drive visible lets the container read all of it, though only the folders you
# add are ever served. Folders added this way are listed in config\folders.conf.
param(
    [string]$Path = "",
    [string]$Name = "",
    [string]$Remove = "",
    [switch]$List,
    [switch]$Yes        # don't ask before restarting the container
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$conf = Join-Path $repo "config\folders.conf"
$override = Join-Path $repo "docker-compose.override.yml"
$utf8 = New-Object System.Text.UTF8Encoding $false
function Stop-Here($text) { Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }
function Invoke-Docker { $previous = $ErrorActionPreference; $ErrorActionPreference = 'Continue'; try { & docker @args 2>&1 } finally { $ErrorActionPreference = $previous } }
function Get-ConfLines { if (Test-Path $conf) { return @(Get-Content $conf) } else { return @() } }
function Save-Conf([string[]]$lines) {
    $folder = Split-Path $conf -Parent
    if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    [System.IO.File]::WriteAllText($conf, (($lines -join "`n") + "`n"), $utf8)
}
function Invoke-Reload {
    $out = Invoke-Docker exec rar2fs mount-folders reload
    $out | ForEach-Object { Write-Host "   $_" }
    if ($LASTEXITCODE -ne 0) { Stop-Here "The container could not reload its folders - is it running? (docker ps)" }
}

if ($List) {
    Write-Host "Folders added without a restart (config\folders.conf):"
    $entries = @(Get-ConfLines | Where-Object { $_ -match '=' -and $_ -notmatch '^\s*#' })
    if ($entries) { $entries | ForEach-Object { Write-Host "   $_" } } else { Write-Host "   (none)" }
    Write-Host "Everything the container is sharing now:"
    Invoke-Docker exec rar2fs sh -c "cut -f1 /tmp/folders.state | tr '\n' ' '" | ForEach-Object { Write-Host "   $_" }
    exit 0
}

if ($Remove) {
    $wanted = $Remove.Trim().ToLower()
    $lines = Get-ConfLines
    $kept = @($lines | Where-Object { -not ($_ -match '^\s*([^=#\s@]+)(@[^=\s]*)?\s*=' -and $Matches[1].ToLower() -eq $wanted) })
    if ($kept.Count -eq $lines.Count) {
        Stop-Here "'$Remove' isn't in config\folders.conf. Folders listed in docker-compose.override.yml are removed there, followed by: docker compose up -d"
    }
    Save-Conf $kept
    Write-Host "Removed '$Remove' from config\folders.conf."
    Invoke-Reload
    exit 0
}

if (-not $Path) { Stop-Here "Say which folder: -Path E:\Concerts   (or -Remove <name>, or -List)" }
$Path = $Path.Trim().Trim('"').TrimEnd('\')
if ($Path -match '^[A-Za-z]:$') { $Path = "$Path\" }
if (-not (Test-Path -LiteralPath $Path -PathType Container)) { Stop-Here "'$Path' is not a folder that exists." }
if ($Path -match '^\\\\') { Stop-Here "Network paths can't be added this way. Add the share to docker-compose.override.yml (see the README), then: docker compose up -d" }
$letter = $Path.Substring(0, 1).ToLower()
$psDrive = Get-PSDrive -Name $letter -ErrorAction SilentlyContinue
if ($psDrive -and $psDrive.DisplayRoot -match '^\\\\') {
    Stop-Here "$($letter.ToUpper()): is a network drive. Add the share to docker-compose.override.yml instead (see the README, 'Network share'), then: docker compose up -d"
}
if (-not $Name) { $Name = Split-Path $Path -Leaf; if (-not $Name) { $Name = "$letter-drive" } }
$Name = ($Name.ToLower() -replace '[^a-z0-9._-]+', '-').Trim('-', '.')
if (-not $Name) { Stop-Here "Give the folder a name with -Name." }
$inside = "/drives/$letter" + (($Path.Substring(2).TrimEnd('\')) -replace '\\', '/')

# Is that drive visible to the container already?
Invoke-Docker exec rar2fs test -d "/drives/$letter" | Out-Null
$driveVisible = ($LASTEXITCODE -eq 0)

if (-not $driveVisible) {
    Write-Host "The container can't see drive $($letter.ToUpper()): yet."
    Write-Host "Making it visible (read-only) restarts the container once - about a minute, during which"
    Write-Host "the drive and anything reading from it (Plex) pause. After that, folders on $($letter.ToUpper()): need no restart."
    if (-not $Yes) {
        $answer = Read-Host "Do that now? [y/N]"
        if ($answer.Trim() -notmatch '^(y|yes)$') { Write-Host "Nothing was changed."; exit 1 }
    }
    if (-not (Test-Path $override)) { Stop-Here "There is no docker-compose.override.yml yet. Run .\windows\setup.ps1 first." }
    $lines = @(Get-Content $override)
    $mount = "      - `"$($letter.ToUpper()):/:/drives/${letter}:ro`"    # the whole drive, so folders on it can be added without a restart"
    $at = -1
    for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^    volumes:\s*$') { $at = $i; break } }
    if ($at -lt 0) { Stop-Here "Couldn't find the 'volumes:' list in docker-compose.override.yml. Add this line under it yourself, then run this again:`n$mount" }
    $lines = $lines[0..$at] + $mount + $(if ($at + 1 -lt $lines.Count) { $lines[($at + 1)..($lines.Count - 1)] } else { @() })
    [System.IO.File]::WriteAllText($override, (($lines -join "`n") + "`n"), $utf8)
}

# record the folder; an existing name gets a label, which merges the two
$existing = @(Get-ConfLines)
$taken = @($existing | Where-Object { $_ -match "^\s*$([regex]::Escape($Name))(@[^=\s]*)?\s*=" })
$key = if ($taken) { "$Name@$($taken.Count + 1)" } else { $Name }
if ($existing | Where-Object { $_ -match "=\s*$([regex]::Escape($inside))\s*$" }) { Stop-Here "'$Path' is already in config\folders.conf." }
if (-not $existing) { $existing = @("# Folders added while the container runs. One per line:  <name> = <path inside the container>", "# Managed by windows\add-folder.ps1; edit by hand if you like, then: docker exec rar2fs mount-folders reload") }
Save-Conf ($existing + "$key = $inside")
Write-Host "Added to config\folders.conf:  $key = $inside"

if ($driveVisible) {
    Invoke-Reload
} else {
    Write-Host "Restarting the container..."
    Push-Location $repo
    try { Invoke-Docker compose up -d | Select-Object -Last 2 | ForEach-Object { Write-Host "   $_" } } finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { Stop-Here "Docker could not restart the container - see above." }
}
Write-Host "'$Name' will appear on the drive within a minute."
