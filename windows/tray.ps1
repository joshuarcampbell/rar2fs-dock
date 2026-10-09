# A tray icon for rar2fs-dock: a coloured dot next to the clock that shows whether the
# container is healthy, with a menu for the things you'd otherwise open a terminal for.
#
#   green   healthy            amber   starting up
#   red     unhealthy          grey    not answering (Docker Desktop not running?)
#
# It asks the status page every 30 seconds and shows a notification when the state
# changes. Start it at every login with .\windows\install-tray.ps1.
#
#     .\windows\tray.ps1          run it now (closes with the window, or via its Exit item)
#     .\windows\tray.ps1 -Once    print the current state and exit
param([switch]$Once)

$repo = Split-Path $PSScriptRoot -Parent

function Get-Settings {
    $s = @{ User = ""; Pass = ""; Tls = $true }
    $envFile = Join-Path $repo ".env"
    if (Test-Path $envFile) {
        foreach ($line in Get-Content $envFile) {
            if ($line -match '^\s*WEBDAV_USER\s*=\s*(.*)$') { $s.User = $Matches[1].Trim() }
            if ($line -match '^\s*WEBDAV_PASS\s*=\s*(.*)$') { $s.Pass = $Matches[1].Trim() }
            if ($line -match '^\s*TLS\s*=\s*0\s*$') { $s.Tls = $false }
        }
    }
    $s.Base = $(if ($s.Tls) { "https" } else { "http" }) + "://localhost:8766"
    return $s
}

# HTTPS with the container's self-signed certificate: accept that one certificate (by its
# fingerprint, read from tls\cert.pem) and nothing else that Windows wouldn't trust anyway.
Add-Type -TypeDefinition @'
using System;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class Rar2fsDockTls {
    public static string Fingerprint = "";
    public static bool Check(object sender, X509Certificate certificate, X509Chain chain, SslPolicyErrors errors) {
        if (errors == SslPolicyErrors.None) return true;
        return certificate != null && Fingerprint.Length > 0 &&
               string.Equals(certificate.GetCertHashString(), Fingerprint, StringComparison.OrdinalIgnoreCase);
    }
}
'@
$tlsCheck = [Delegate]::CreateDelegate([System.Net.Security.RemoteCertificateValidationCallback], [Rar2fsDockTls].GetMethod("Check"))
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# The container's status, or $null if it isn't answering.
function Get-Status {
    $s = Get-Settings
    try {
        $cert = Join-Path $repo "tls\cert.pem"
        if ($s.Tls -and (Test-Path $cert)) {
            [Rar2fsDockTls]::Fingerprint = (New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $cert).Thumbprint
        }
        $request = [System.Net.HttpWebRequest]::Create("$($s.Base)/status.json")
        $request.Timeout = 8000
        $request.ServerCertificateValidationCallback = $tlsCheck
        # the login travels in a header, so it never shows in a process list
        $request.Headers["Authorization"] = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($s.User + ":" + $s.Pass))
        $response = $request.GetResponse()
        try {
            $reader = New-Object System.IO.StreamReader $response.GetResponseStream()
            return ($reader.ReadToEnd() | ConvertFrom-Json)
        } finally { $response.Close() }
    } catch {
        $answer = $null
        if ($_.Exception.InnerException) { $answer = $_.Exception.InnerException.Response }
        if ($answer -and [int]$answer.StatusCode -eq 401) {
            return [pscustomobject]@{ health = "unhealthy"; detail = "the login in .env was rejected"; folders_mounted = 0; folders_total = 0; updates_available = 0 }
        }
        return $null
    }
}

function Get-Summary($status) {
    if (-not $status) { return @{ State = "offline"; Text = "not answering - is Docker Desktop running?" } }
    $text = "$($status.health) - $($status.folders_mounted) of $($status.folders_total) folders"
    if ($status.health -ne "healthy" -and $status.detail) { $text = "$($status.health) - $($status.detail)" }
    if ($status.updates_available -gt 0) { $text += " - update available" }
    return @{ State = [string]$status.health; Text = $text }
}

function Get-MountArgs {
    $task = Get-ScheduledTask -TaskName "rar2fs-dock mount" -ErrorAction SilentlyContinue
    $found = @{ Drive = ""; Args = "" }
    if ($task) {
        $taskArgs = $task.Actions.Arguments
        if ($taskArgs -match '-Drive ([A-Za-z]:)') { $found.Drive = $Matches[1]; $found.Args = "-Drive $($Matches[1])" }
        if ($taskArgs -match '-Url (\S+)') { $found.Args += " -Url $($Matches[1])" }
        if ($taskArgs -match '-Original') { $found.Args += " -Original" }
    }
    return $found
}

if ($Once) {
    $summary = Get-Summary (Get-Status)
    Write-Output "rar2fs-dock: $($summary.Text)"
    if ($summary.State -eq "healthy") { exit 0 } else { exit 1 }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# one tray icon at a time
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "rar2fs-dock-tray", [ref]$created)
if (-not $created) { exit 0 }

function New-DotIcon([System.Drawing.Color]$color) {
    $bitmap = New-Object System.Drawing.Bitmap 16, 16
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)
    $brush = New-Object System.Drawing.SolidBrush $color
    $graphics.FillEllipse($brush, 2, 2, 12, 12)
    $graphics.Dispose(); $brush.Dispose()
    return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}
$icons = @{
    healthy   = New-DotIcon ([System.Drawing.Color]::FromArgb(46, 160, 67))
    unhealthy = New-DotIcon ([System.Drawing.Color]::FromArgb(207, 34, 46))
    starting  = New-DotIcon ([System.Drawing.Color]::FromArgb(212, 160, 23))
    offline   = New-DotIcon ([System.Drawing.Color]::FromArgb(140, 149, 159))
}

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icons.offline
$tray.Text = "rar2fs-dock"
$tray.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$statusItem = $menu.Items.Add("rar2fs-dock"); $statusItem.Enabled = $false
[void]$menu.Items.Add("-")
$openPage = $menu.Items.Add("Open status page")
$openDrive = $menu.Items.Add("Open drive")
[void]$menu.Items.Add("-")
$remount = $menu.Items.Add("Remount drive")
$restart = $menu.Items.Add("Restart container")
[void]$menu.Items.Add("-")
$exit = $menu.Items.Add("Exit")
$tray.ContextMenuStrip = $menu

$openStatusPage = { Start-Process "$((Get-Settings).Base)/status.html" }
$openPage.add_Click($openStatusPage)
$tray.add_DoubleClick($openStatusPage)
$openDrive.add_Click({
    $drive = (Get-MountArgs).Drive
    if ($drive -and (Test-Path "$drive\")) { Start-Process explorer.exe "$drive\" }
    else { $tray.ShowBalloonTip(5000, "rar2fs-dock", "The drive isn't mounted. Try 'Remount drive'.", [System.Windows.Forms.ToolTipIcon]::Warning) }
})
$remount.add_Click({
    $mount = Get-MountArgs
    if (-not $mount.Args) { $mount.Args = "" }
    $command = "& '$PSScriptRoot\uninstall-autostart.ps1'; & '$PSScriptRoot\install-autostart.ps1' $($mount.Args)"
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command
    $tray.ShowBalloonTip(4000, "rar2fs-dock", "Remounting the drive...", [System.Windows.Forms.ToolTipIcon]::Info)
})
$restart.add_Click({
    Start-Process docker.exe -WindowStyle Hidden -WorkingDirectory $repo -ArgumentList "compose", "restart"
    $tray.ShowBalloonTip(4000, "rar2fs-dock", "Restarting the container. The drive comes back by itself in about a minute.", [System.Windows.Forms.ToolTipIcon]::Info)
})
$exit.add_Click({ $tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })

$script:last = ""
$refresh = {
    $summary = Get-Summary (Get-Status)
    $state = $summary.State
    if (-not $icons.ContainsKey($state)) { $state = "starting" }
    $tray.Icon = $icons[$state]
    $label = "rar2fs-dock: $($summary.Text)"
    $tray.Text = $label.Substring(0, [Math]::Min(63, $label.Length))      # Windows allows 63 characters here
    $statusItem.Text = $label
    $drive = (Get-MountArgs).Drive
    $openDrive.Text = $(if ($drive) { "Open drive ($drive)" } else { "Open drive" })
    # tell the user when it changes - but not about the very first reading
    if ($script:last -and $script:last -ne $state) {
        if ($state -eq "healthy") {
            $tray.ShowBalloonTip(5000, "rar2fs-dock is healthy again", $summary.Text, [System.Windows.Forms.ToolTipIcon]::Info)
        } elseif ($state -ne "starting") {
            $tray.ShowBalloonTip(10000, "rar2fs-dock needs attention", $summary.Text, [System.Windows.Forms.ToolTipIcon]::Warning)
        }
    }
    $script:last = $state
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 30000
$timer.add_Tick($refresh)
& $refresh
$timer.Start()

[System.Windows.Forms.Application]::Run()
$timer.Stop(); $tray.Dispose(); $mutex.ReleaseMutex()
