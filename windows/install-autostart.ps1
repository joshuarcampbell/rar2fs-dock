# OLD NAME - kept for a while so that existing notes, shortcuts and an update that is
# half-way through still work. It only passes everything on to autostart.ps1.
# Use instead:   .\rar2fs.ps1 autostart        (other PCs: .\windows\autostart.ps1)
param([string]$Drive = "Y:", [string]$Url = "", [string]$User = "", [string]$Pass = "", [switch]$Original)
& (Join-Path $PSScriptRoot "autostart.ps1") @PSBoundParameters
