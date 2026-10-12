# OLD NAME - kept for a while so that existing notes, shortcuts and an update that is
# half-way through still work. It only passes this on to autostart.ps1, and - as it
# always did - takes every rar2fs drive away.
# Use instead:   .\rar2fs.ps1 autostart off    (other PCs: .\windows\autostart.ps1 -Remove)
& (Join-Path $PSScriptRoot "autostart.ps1") -Remove -All
