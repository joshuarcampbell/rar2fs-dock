# Says what is being read from the drive right now, and by whom - so you know whether
# restarting the container would interrupt somebody's film.
#
#     .\windows\in-use.ps1                              print the list
#     .\windows\in-use.ps1 -AskBefore "restarting"      used by the other scripts: if
#                                                        something is being read, show it
#                                                        and ask; returns $true to go ahead
#     .\windows\in-use.ps1 -Quiet                       return the list and print nothing
#
# The list comes from the container (its "In use now" section on the status page shows
# the same). If the container isn't running, nothing is in use.
param(
    [string]$AskBefore = "",
    [switch]$Quiet
)

$container = if ($env:RAR2FS_CONTAINER) { $env:RAR2FS_CONTAINER } else { "rar2fs" }     # the override is for testing
function Get-Reading {
    try {
        # only a list written in the last minute counts: an old one says nothing about now
        $json = & docker exec $container find /tmp/activity.json -mmin -1 -exec cat '{}' ';' 2>$null
        if ($LASTEXITCODE -ne 0 -or -not $json) { return @() }
        return @((($json -join "`n") | ConvertFrom-Json).reading)
    } catch { return @() }
}
function Format-Reading($item) {
    $who = @($item.users) -join ", "
    if (-not $who) { $who = "someone" }
    $speed = if ($item.bytes_per_second -ge 1048576) { " at {0:N1} MB/s" -f ($item.bytes_per_second / 1048576) } else { "" }
    $done = if ($null -ne $item.percent) { ", $($item.percent)% through" } else { "" }
    return "$who is reading $($item.path)$done$speed"
}

$reading = @(Get-Reading | Where-Object { $_ })
if ($Quiet) { return $reading }

if ($AskBefore) {
    if ($reading.Count -eq 0) { return $true }
    Write-Host ""
    Write-Host "The drive is in use right now:" -ForegroundColor Yellow
    $reading | ForEach-Object { Write-Host "   $(Format-Reading $_)" }
    Write-Host "$AskBefore will interrupt that for about a minute."
    $answer = Read-Host "Go ahead anyway? [y/N]"
    return ($answer.Trim() -match '^(y|yes)$')
}

if ($reading.Count -eq 0) { Write-Host "Nothing is being read from the drive right now."; exit 0 }
Write-Host "Being read right now:"
$reading | ForEach-Object { Write-Host "   $(Format-Reading $_)" }
exit 1
