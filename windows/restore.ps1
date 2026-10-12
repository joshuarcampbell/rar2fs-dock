# OLD NAME - kept for a while so that existing notes still work. It only passes this on
# to backup.ps1.   Use instead:   .\rar2fs.ps1 restore <the zip>
param([Parameter(Mandatory)][string]$File, [switch]$Force)
& (Join-Path $PSScriptRoot "backup.ps1") -Restore $File -Force:$Force
