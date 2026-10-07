# Adds (or replaces) an extra login in config\users.htpasswd and restarts the container.
#   .\windows\add-user.ps1 -Name plex -Pass 'some-password'
# To remove a login, delete its line from config\users.htpasswd and run: docker compose restart
param(
    [Parameter(Mandatory)][string]$Name,
    [Parameter(Mandatory)][string]$Pass
)

$repo = Split-Path $PSScriptRoot -Parent
$file = Join-Path $repo "config\users.htpasswd"

# The password is hashed (bcrypt) inside the container; only the hash is stored.
$line = $Pass | docker exec -i rar2fs htpasswd -niB $Name | Where-Object { $_ -match ':' }
if (-not $line) {
    Write-Error "Could not create the login - is the rar2fs container running?"
    exit 1
}

$existing = @()
if (Test-Path $file) { $existing = @(Get-Content $file | Where-Object { $_ -notmatch "^$([regex]::Escape($Name)):" }) }
[IO.File]::WriteAllLines($file, [string[]]($existing + $line))

docker compose --project-directory $repo restart | Out-Null
Write-Host "Login '$Name' added. Remove it by deleting its line from config\users.htpasswd."
