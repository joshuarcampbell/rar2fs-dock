# Checks your setup and says, in plain words, what is wrong and how to fix it.
#
#     .\windows\doctor.ps1
#
# It reads .env and the compose files, looks at the folders and network shares they name,
# asks the running container what it sees, and checks the drive. Nothing is changed.
# Exit code: 0 if no problems were found, 1 if there were.
$repo = Split-Path $PSScriptRoot -Parent
[Console]::OutputEncoding = [Text.Encoding]::UTF8      # docker writes UTF-8 (folder names)

$script:problems = 0; $script:checks = 0
function Say($level, $title, $detail) {
    switch ($level) {
        'ok'   { $label = '  ok     '; $color = 'Green' }
        'warn' { $label = '  CHECK  '; $color = 'Yellow'; $script:checks++ }
        default { $label = '  PROBLEM'; $color = 'Red'; $script:problems++ }
    }
    Write-Host $label -ForegroundColor $color -NoNewline
    Write-Host " $title" -NoNewline
    if ($level -eq 'ok') { Write-Host " - $detail" -ForegroundColor DarkGray }
    else { Write-Host ""; Write-Host "           $detail" }
}
function Finish {
    Write-Host ""
    if ($script:problems -eq 0 -and $script:checks -eq 0) { Write-Host "Everything looks right." -ForegroundColor Green }
    else { Write-Host "$($script:problems) problem(s), $($script:checks) thing(s) to check." }
    Pop-Location
    if ($script:problems -gt 0) { exit 1 } else { exit 0 }
}
# Runs docker and returns what it printed; $script:failed says whether it worked.
function Docker-Out {
    $errFile = [IO.Path]::GetTempFileName()
    $out = & docker @args 2> $errFile
    $script:failed = ($LASTEXITCODE -ne 0)
    $script:lastError = ((Get-Content $errFile -ErrorAction SilentlyContinue) -join ' ').Trim()
    [IO.File]::Delete($errFile)
    return $out
}

Push-Location $repo
Write-Host "rar2fs-dock setup check" -ForegroundColor Cyan
Write-Host ""

# ---- Docker ----
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Say bad "Docker" "Docker isn't installed, or isn't on the PATH. Install Docker Desktop first."
    Finish
}
Docker-Out info --format '{{.ServerVersion}}' | Out-Null
if ($script:failed) {
    Say bad "Docker" "Docker Desktop isn't running. Start it, wait for it to finish starting, and run this again."
    Finish
}
Say ok "Docker" "running"

# ---- .env ----
$envFile = Join-Path $repo ".env"
if (-not (Test-Path $envFile)) {
    Say bad ".env" "There is no .env file, so there is no login. Run .\windows\setup.ps1, or copy .env.example to .env and set a password."
} else {
    $envText = Get-Content $envFile
    $user = [bool]($envText | Where-Object { $_ -match '^\s*WEBDAV_USER\s*=\s*\S' })
    $pass = [bool]($envText | Where-Object { $_ -match '^\s*WEBDAV_PASS\s*=\s*\S' })
    if (-not ($user -and $pass)) { Say bad ".env" "WEBDAV_USER and WEBDAV_PASS must both be set in .env." }
    else { Say ok ".env" "the login is set" }
}

# ---- the compose files ----
if (-not (Test-Path (Join-Path $repo "docker-compose.override.yml"))) {
    Say bad "Your folders" "There is no docker-compose.override.yml, so no folders are shared. Run .\windows\setup.ps1, or copy docker-compose.override.example.yml and edit it."
}
$json = Docker-Out compose config --format json
if ($script:failed) {
    Say bad "Compose files" "Docker can't read them: $($script:lastError)"
    Finish
}
$config = ($json -join "`n") | ConvertFrom-Json
$service = $config.services.rar2fs
if (-not $service) { $service = $config.services.PSObject.Properties.Value | Select-Object -First 1 }
$mounts = @($service.volumes | Where-Object { $_.target -like '/sources/*' -or $_.target -like '/drives/*' })
$hasConf = Test-Path (Join-Path $repo "config\folders.conf")
if (-not ($mounts | Where-Object { $_.target -like '/sources/*' }) -and -not $hasConf) {
    Say bad "Your folders" "No folder is mounted under /sources, so the drive will be empty. Each one needs a line like:  - `"D:/Movies:/sources/movies:ro`""
} else {
    Say ok "Compose files" "$($mounts.Count) folder(s) listed"
}

# ---- folders on this PC ----
foreach ($m in ($mounts | Where-Object { $_.type -eq 'bind' })) {
    $path = $m.source -replace '/', '\'
    $shown = "$path -> $($m.target -replace '^/sources/', '' -replace '^/drives/', 'drive ')"
    if ($path -match '^([A-Za-z]):') {
        $kind = (New-Object IO.DriveInfo $Matches[1]).DriveType
        if ($kind -eq 'NoRootDirectory') {
            Say bad $shown "This PC has no drive $($Matches[1].ToUpper()): right now. If it is a USB or external disk, plug it in and restart the container."
            continue
        }
        if ($kind -eq 'Network') {
            Say bad $shown "$($Matches[1].ToUpper()): is a network drive that Windows mapped. Docker can't see those, so the folder shows up empty. Connect it as a network share instead (README, 'Choose your source folders')."
            continue
        }
    }
    if (-not (Test-Path -LiteralPath $path)) {
        Say bad $shown "That folder doesn't exist. Docker will quietly create it, empty. Check the spelling in docker-compose.override.yml."
    } elseif (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue | Select-Object -First 1).Count -eq 0) {
        Say warn $shown "That folder is empty. If it shouldn't be, check that the path is the right one."
    } else {
        Say ok $shown "found"
    }
    if (-not $m.read_only) {
        Say warn "$shown is not read-only" "Add :ro to the end of its line, so nothing in the container can ever change your files."
    }
}

# ---- network shares ----
# Shares that are defined but that no line under the service's "volumes:" uses. (The
# normal "config" output leaves those out, so the unprocessed files are read for names.)
$rawJson = Docker-Out compose config --no-normalize --no-interpolate --format json
if (-not $script:failed) {
    $raw = ($rawJson -join "`n") | ConvertFrom-Json
    $used = @($service.volumes | Where-Object { $_.type -eq 'volume' } | ForEach-Object { $_.source })
    if ($raw.volumes) {
        foreach ($name in $raw.volumes.PSObject.Properties.Name) {
            if ($name -eq 'state' -or $used -contains $name) { continue }
            Say bad "Network share '$name' is defined but not used" "It is set up at the bottom of the file, but nothing mounts it, so it never appears on the drive. Under the service's `"volumes:`" add a line like:  - ${name}:/sources/<folder name>:ro"
        }
    }
}
foreach ($m in ($mounts | Where-Object { $_.type -eq 'volume' })) {
    $name = $m.source
    $volume = $config.volumes.$name
    $shown = "Network share '$name' -> $($m.target -replace '^/sources/', '')"
    $device = $null
    if ($volume.driver_opts) { $device = $volume.driver_opts.device }
    if (-not $device) {
        Say bad $shown "'$name' has no `"device:`" under `"driver_opts:`", so it is just an empty Docker volume and not your NAS. See the network share example in docker-compose.override.example.yml."
        continue
    }
    $fine = $true
    if ($device -notmatch '^//([^/]+)/.+') {
        Say bad $shown "Its device is `"$device`". It has to look like //server/share/folder, with forward slashes."
        continue
    }
    $server = $Matches[1]
    if ($server -notmatch '\.' -and $server -notmatch ':') {
        $fine = $false
        Say warn $shown "`"$server`" is a short Windows network name. Docker often can't find a NAS by that kind of name. If this share is empty or the container won't start, use the NAS's IP address instead (for example //192.168.1.30/...)."
    }
    $client = New-Object Net.Sockets.TcpClient
    try {
        $reached = $client.BeginConnect($server, 445, $null, $null).AsyncWaitHandle.WaitOne(2500) -and $client.Connected
    } catch { $reached = $false }
    $client.Close()
    if (-not $reached) {
        $fine = $false
        Say warn $shown "This PC can't reach $server for file sharing (port 445). Check the address, and that the NAS is on."
    }
    # Docker keeps the address and login a share was first connected with, whatever the file says now
    $existing = Docker-Out volume inspect $volume.name --format '{{json .Options}}'
    if (-not $script:failed -and $existing) {
        $options = ($existing -join '') | ConvertFrom-Json
        if ($options -and ($options.device -ne $device -or $options.o -ne $volume.driver_opts.o)) {
            $fine = $false
            $what = if ($options.device -ne $device) { "the old address $($options.device)" } else { "the old login or options" }
            Say bad $shown "Docker is still using $what - it doesn't pick up changes to a share by itself. Run:  docker compose down;  docker volume rm $($volume.name);  docker compose up -d"
        }
    }
    if ($fine) { Say ok $shown "$device, reachable" }
}

# ---- the container ----
$containerName = if ($service.container_name) { $service.container_name } else { 'rar2fs' }
$stateJson = Docker-Out inspect $containerName --format '{{json .State}}'
if ($script:failed) {
    Say warn "Container" "It hasn't been created yet. Start it with:  docker compose up -d --build"
    Finish
}
$state = ($stateJson -join '') | ConvertFrom-Json
if ($state.Status -ne 'running') {
    Say bad "Container" "It is '$($state.Status)', not running. Look at the last lines of  docker compose logs --tail 30  for the reason; a network share that can't connect is the usual one."
    Finish
}
$health = if ($state.Health) { $state.Health.Status } else { 'unknown' }
if ($health -eq 'unhealthy') { Say bad "Container" "running, but unhealthy. The status page says why." }
elseif ($health -eq 'starting') { Say warn "Container" "It is still starting up. Give it a minute and run this again." }
else { Say ok "Container" "running and healthy" }

# folders in the compose files that the running container doesn't have (or the other way round)
$mountsJson = Docker-Out inspect $containerName --format '{{json .Mounts}}'
if (-not $script:failed) {
    $has = @((($mountsJson -join '') | ConvertFrom-Json) | ForEach-Object { $_.Destination } | Where-Object { $_ -like '/sources/*' -or $_ -like '/drives/*' })
    $wants = @($mounts | ForEach-Object { $_.target })
    if (Compare-Object @($has | Sort-Object -Unique) @($wants | Sort-Object -Unique)) {
        Say warn "Container" "Your folder list has changed since the container was created. Apply it with:  docker compose up -d"
    }
}

# what the container itself sees
$inside = Docker-Out exec $containerName doctor --full
if ($script:failed) {
    Say warn "Inside the container" "This container was built before the setup check existed. Rebuild it with:  docker compose up -d --build"
} else {
    foreach ($line in $inside) {
        $parts = $line -split "`t", 3
        if ($parts.Count -eq 3) { Say $parts[0] $parts[1] $parts[2] }
    }
}

# ---- the drive ----
$task = Get-ScheduledTask -TaskName "rar2fs-dock mount" -ErrorAction SilentlyContinue
if (-not $task) {
    Say warn "Drive" "It isn't set up to appear when you log in. Run .\windows\install-autostart.ps1 (or .\windows\mount.ps1 to mount it just for now)."
} elseif ($task.Actions.Arguments -match '-Drive ([A-Za-z]:)') {
    $letter = $Matches[1].ToUpper()
    if (Test-Path "$letter\") { Say ok "Drive" "$letter is mounted" }
    else { Say warn "Drive" "$letter isn't mounted right now. Use 'Remount drive' on the tray icon, or run .\windows\install-autostart.ps1 again." }
}
Finish
