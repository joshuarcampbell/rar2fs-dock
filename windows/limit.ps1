# Changes how much of the processor the container may use - while it runs, with no
# restart and nothing interrupted. Handy during a big library scan.
#
#     .\rar2fs.ps1 limit                 show the limit now
#     .\rar2fs.ps1 limit 4          at most 4 processor cores
#     .\rar2fs.ps1 limit half       half of what Docker has (also: quarter)
#     .\rar2fs.ps1 limit none       no limit
#     .\rar2fs.ps1 limit 2 -NoSave  only until the next restart
#
# The change takes effect at once. It is also written to .env as CPU_LIMIT, so it is
# still there after a restart (not with -NoSave). The tray icon's menu does the same.
#
# The memory limit (MEMORY_LIMIT in .env) can't be changed this way: Docker only applies
# that one when the container is created.
param(
    [string]$Cpu = "",
    [switch]$NoSave
)

$repo = Split-Path $PSScriptRoot -Parent
$container = if ($env:RAR2FS_CONTAINER) { $env:RAR2FS_CONTAINER } else { "rar2fs" }                       # the overrides
$envFile = if ($env:RAR2FS_ENV_FILE) { $env:RAR2FS_ENV_FILE } else { Join-Path $repo ".env" }              # are for testing
$utf8 = New-Object System.Text.UTF8Encoding $false
$invariant = [Globalization.CultureInfo]::InvariantCulture

function Stop-Here($text) { Write-Host "STOPPED: $text" -ForegroundColor Red; exit 1 }

$cores = 0
[void][int]::TryParse((& docker info --format '{{.NCPU}}' 2>$null), [ref]$cores)
if ($cores -le 0) { Stop-Here "Docker isn't answering. Is Docker Desktop running?" }
$nano = & docker inspect $container --format '{{.HostConfig.NanoCpus}}' 2>$null
if ($LASTEXITCODE -ne 0) { Stop-Here "The $container container doesn't exist yet. Start it first: docker compose up -d" }
$current = [double]$nano / 1e9          # 0 = no limit

function Format-Limit([double]$value) {
    if ($value -le 0 -or $value -ge $cores) { return "no limit (all $cores cores)" }
    return ("{0} of {1} cores" -f $value.ToString("0.##", $invariant), $cores)
}

if (-not $Cpu) {
    Write-Host "Processor limit now: $(Format-Limit $current)"
    Write-Host "Change it with:  .\rar2fs.ps1 limit <cores | half | quarter | none>"
    exit 0
}

[double]$wanted = 0
switch -Regex ($Cpu.Trim().ToLower()) {
    '^(none|off|all|0)$' { $wanted = 0; break }
    '^half$'             { $wanted = [Math]::Max(1, [Math]::Floor($cores / 2)); break }
    '^quarter$'          { $wanted = [Math]::Max(1, [Math]::Floor($cores / 4)); break }
    default {
        if (-not [double]::TryParse($Cpu, [Globalization.NumberStyles]::Float, $invariant, [ref]$wanted) -or $wanted -lt 0.1) {
            Stop-Here "'$Cpu' isn't a number of cores. Use for example 4, 1.5, half, quarter or none."
        }
    }
}
if ($wanted -ge $cores) { $wanted = 0 }         # as many as there are = no limit

# Docker can't take a limit away from a running container, only change it - so
# "no limit" is applied as "all the cores there are", which comes to the same thing.
$apply = if ($wanted -eq 0) { $cores } else { $wanted }
& docker update --cpus $apply.ToString("0.##", $invariant) $container 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) { Stop-Here "Docker refused the change. Is the container running? (docker ps)" }
Write-Host "Processor limit is now: $(Format-Limit $wanted). Nothing was restarted."

if ($NoSave) { Write-Host "Not saved: the next restart goes back to what .env says."; exit 0 }
if (-not (Test-Path $envFile)) { Write-Host "There is no .env to save it in, so it lasts until the next restart."; exit 0 }

# Save it as CPU_LIMIT in .env, leaving every other line exactly as it is.
$note = "# Most processor cores the container may use (set by windows\limit.ps1)"
$value = "CPU_LIMIT=" + $wanted.ToString("0.##", $invariant)
$kept = New-Object System.Collections.Generic.List[string]
$placed = $false
foreach ($line in [IO.File]::ReadAllLines($envFile)) {
    if ($line -match '^\s*CPU_LIMIT\s*=') {
        # the existing line: replaced in place, or dropped when the limit is taken away
        if ($wanted -gt 0 -and -not $placed) { $kept.Add($value); $placed = $true }
    } elseif ($line -eq $note -and $wanted -eq 0) {
        # its comment goes with it
    } else { $kept.Add($line) }
}
while ($kept.Count -gt 0 -and $kept[$kept.Count - 1] -eq "") { $kept.RemoveAt($kept.Count - 1) }    # no blank lines piling up at the end
if ($wanted -gt 0 -and -not $placed) { $kept.Add(""); $kept.Add($note); $kept.Add($value) }
[IO.File]::WriteAllText($envFile, (($kept -join "`n") + "`n"), $utf8)
Write-Host "Saved in .env, so it stays after a restart."
exit 0
