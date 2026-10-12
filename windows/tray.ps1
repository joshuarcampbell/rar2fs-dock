# A tray icon for rar2fs-dock: a coloured dot next to the clock that shows whether the
# container is healthy, with a menu for the things you'd otherwise open a terminal for.
#
#   green   healthy            amber   starting up
#   red     unhealthy          grey    not answering (Docker Desktop not running?)
#
# It asks the status page every 30 seconds and shows a notification when the state
# changes.
#
#     .\rar2fs.ps1 tray on        start it now and at every login
#     .\rar2fs.ps1 tray off       stop it, and don't start it at login
#     .\rar2fs.ps1 tray status    print the current state and exit
#     .\rar2fs.ps1 tray           run it in this window (closes with the window, or via Exit)
#
# "on" puts a shortcut to this file in your Startup folder; "off" removes it.
param(
    [switch]$Install,    # tray on
    [switch]$Remove,     # tray off
    [switch]$Once        # tray status
)

$shortcutPath = Join-Path ([Environment]::GetFolderPath('Startup')) "rar2fs-dock tray.lnk"
# stop a tray icon that is already running (not this window)
function Stop-Tray {
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
        Where-Object { $_.CommandLine -like "*tray.ps1*" -and $_.CommandLine -notlike "*-Install*" -and $_.ProcessId -ne $PID } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
}
if ($Remove) {
    if (Test-Path -LiteralPath $shortcutPath) { [IO.File]::Delete($shortcutPath) }
    Stop-Tray
    Write-Host "The tray icon is stopped and won't start at login."
    exit 0
}
if ($Install) {
    $arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    $shortcut = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcutPath)
    $shortcut.TargetPath = (Get-Command powershell.exe).Source
    $shortcut.Arguments = $arguments
    $shortcut.WorkingDirectory = Split-Path $PSScriptRoot -Parent
    $shortcut.WindowStyle = 7        # minimised: no window flashes up at login
    $shortcut.Description = "rar2fs-dock tray icon"
    $shortcut.Save()
    Stop-Tray                        # so that a newer version of this file takes over
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $arguments
    Write-Host "The tray icon is running and will start at every login."
    Write-Host "Look for a coloured dot next to the clock (it may be behind the ^ arrow)."
    exit 0
}

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

# The drive "Open drive" means: of the drives set to start at login (there can be more
# than one - see autostart.ps1), the first that is mounted, or else the first.
function Get-MainDrive {
    $drives = @(& (Join-Path $PSScriptRoot "autostart.ps1") -Objects | Where-Object { $_.AtLogin })
    $pick = $drives | Where-Object { $_.Mounted } | Select-Object -First 1
    if (-not $pick) { $pick = $drives | Select-Object -First 1 }
    if ($pick) { return $pick.Drive } else { return "" }
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
# Processor limit: changed while the container runs, nothing restarts (see limit.ps1).
# The list is built each time it opens, from the number of cores Docker has: "No limit",
# then one entry per core count, with a tick on the one in force.
$limitMenu = New-Object System.Windows.Forms.ToolStripMenuItem "Processor limit"
[void]$menu.Items.Add($limitMenu)
[void]$limitMenu.DropDownItems.Add("...")       # a sub-menu needs an entry before it can open
$setLimit = {
    param($sender, $e)
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "limit.ps1") -Cpu $sender.Tag 2>&1 | Select-Object -First 1
    $tray.ShowBalloonTip(5000, "rar2fs-dock", [string]$out, [System.Windows.Forms.ToolTipIcon]::Info)
}
# Which core counts to offer: every one up to 16; on bigger machines every second or
# fourth, so the list stays a sensible length. (Any number works with limit.ps1 -Cpu.)
function Get-CoreChoices([int]$cores) {
    $step = if ($cores -le 16) { 1 } elseif ($cores -le 32) { 2 } else { 4 }
    $list = @(1) + @(for ($n = $step; $n -lt $cores; $n += $step) { $n }) | Where-Object { $_ -lt $cores } | Sort-Object -Unique
    return @($list)
}
$limitMenu.add_DropDownOpening({
    $cores = 0; [void][int]::TryParse((& docker info --format '{{.NCPU}}' 2>$null), [ref]$cores)
    $limitMenu.DropDownItems.Clear()
    if ($cores -le 0) {
        $none = $limitMenu.DropDownItems.Add("Docker isn't answering"); $none.Enabled = $false
        return
    }
    $now = [double](& docker inspect rar2fs --format '{{.HostConfig.NanoCpus}}' 2>$null) / 1e9
    if ($now -le 0 -or $now -ge $cores) { $now = 0 }       # 0 = no limit
    $choices = @(@{ Text = "No limit (all $cores cores)"; Value = 0 })
    foreach ($n in (Get-CoreChoices $cores)) { $choices += @{ Text = $(if ($n -eq 1) { "1 core" } else { "$n cores" }); Value = $n } }
    # a limit set by hand that isn't in the list (1.5, say) is shown too, so the tick has somewhere to go
    if ($now -gt 0 -and -not ($choices | Where-Object { $_.Value -eq $now })) {
        $choices += @{ Text = "$($now.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)) cores"; Value = $now }
        $choices = @($choices[0]) + @($choices | Select-Object -Skip 1 | Sort-Object { $_.Value })
    }
    foreach ($choice in $choices) {
        $item = New-Object System.Windows.Forms.ToolStripMenuItem $choice.Text
        $item.Tag = $(if ($choice.Value -eq 0) { "none" } else { ([double]$choice.Value).ToString('0.##', [Globalization.CultureInfo]::InvariantCulture) })
        $item.Checked = ($choice.Value -eq $now)
        $item.add_Click($setLimit)
        [void]$limitMenu.DropDownItems.Add($item)
    }
})
[void]$menu.Items.Add("-")
$exit = $menu.Items.Add("Exit")
$tray.ContextMenuStrip = $menu

# The menu follows Windows' light or dark setting (Settings > Personalisation > Colours >
# "Choose your default app mode"). Looked up each time the menu opens, so changing the
# setting takes effect without restarting the tray icon.
Add-Type -ReferencedAssemblies System.Windows.Forms, System.Drawing -TypeDefinition @'
using System.Drawing;
using System.Windows.Forms;
public class Rar2fsDockDarkColors : ProfessionalColorTable {
    static readonly Color Back = Color.FromArgb(43, 43, 43);
    static readonly Color Line = Color.FromArgb(80, 80, 80);
    static readonly Color Hover = Color.FromArgb(65, 65, 65);
    public override Color ToolStripDropDownBackground { get { return Back; } }
    public override Color ImageMarginGradientBegin { get { return Back; } }
    public override Color ImageMarginGradientMiddle { get { return Back; } }
    public override Color ImageMarginGradientEnd { get { return Back; } }
    public override Color MenuBorder { get { return Line; } }
    public override Color SeparatorDark { get { return Line; } }
    public override Color SeparatorLight { get { return Line; } }
    public override Color MenuItemBorder { get { return Hover; } }
    public override Color MenuItemSelected { get { return Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return Hover; } }
}
public class Rar2fsDockDarkRenderer : ToolStripProfessionalRenderer {
    public Rar2fsDockDarkRenderer() : base(new Rar2fsDockDarkColors()) { RoundedEdges = false; }
    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e) {
        e.TextColor = e.Item.Enabled ? Color.FromArgb(240, 240, 240) : Color.FromArgb(150, 150, 150);
        base.OnRenderItemText(e);
    }
    protected override void OnRenderMenuItemBackground(ToolStripItemRenderEventArgs e) {
        Color fill = e.Item.Selected && e.Item.Enabled ? Color.FromArgb(65, 65, 65) : Color.FromArgb(43, 43, 43);
        using (SolidBrush brush = new SolidBrush(fill)) {
            e.Graphics.FillRectangle(brush, new Rectangle(2, 0, e.Item.Width - 3, e.Item.Height));
        }
    }
    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e) {
        e.ArrowColor = Color.FromArgb(240, 240, 240);       // the arrow that opens a sub-menu
        base.OnRenderArrow(e);
    }
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e) {
        Rectangle r = e.ImageRectangle;                      // a plain tick, no coloured box
        e.Graphics.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        using (Pen pen = new Pen(Color.FromArgb(240, 240, 240), 2)) {
            e.Graphics.DrawLines(pen, new Point[] {
                new Point(r.Left + 3, r.Top + r.Height / 2), new Point(r.Left + r.Width / 2 - 1, r.Bottom - 4), new Point(r.Right - 3, r.Top + 4) });
        }
    }
    protected override void OnRenderSeparator(ToolStripSeparatorRenderEventArgs e) {
        using (SolidBrush brush = new SolidBrush(Color.FromArgb(43, 43, 43))) {
            e.Graphics.FillRectangle(brush, new Rectangle(0, 0, e.Item.Width, e.Item.Height));
        }
        int y = e.Item.Height / 2;
        using (Pen pen = new Pen(Color.FromArgb(80, 80, 80))) {
            e.Graphics.DrawLine(pen, 4, y, e.Item.Width - 4, y);
        }
    }
}
'@
$darkRenderer = New-Object Rar2fsDockDarkRenderer
function Test-DarkMode {
    $key = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"
    $light = (Get-ItemProperty -Path $key -Name AppsUseLightTheme -ErrorAction SilentlyContinue).AppsUseLightTheme
    return ($null -ne $light -and $light -eq 0)       # no such setting (older Windows) = light
}
$applyTheme = {
    if (Test-DarkMode) {
        $menu.Renderer = $darkRenderer
        $menu.BackColor = [System.Drawing.Color]::FromArgb(43, 43, 43)
        $limitMenu.DropDown.Renderer = $darkRenderer
        $limitMenu.DropDown.BackColor = $menu.BackColor
    } else {
        $menu.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::ManagerRenderMode
        $menu.BackColor = [System.Drawing.SystemColors]::Control
        $limitMenu.DropDown.RenderMode = [System.Windows.Forms.ToolStripRenderMode]::ManagerRenderMode
        $limitMenu.DropDown.BackColor = $menu.BackColor
    }
}
$menu.add_Opening($applyTheme)
& $applyTheme

$openStatusPage = { Start-Process "$((Get-Settings).Base)/status.html" }
$openPage.add_Click($openStatusPage)
$tray.add_DoubleClick($openStatusPage)
$openDrive.add_Click({
    $drive = Get-MainDrive
    if ($drive -and (Test-Path "$drive\")) { Start-Process explorer.exe "$drive\" }
    else { $tray.ShowBalloonTip(5000, "rar2fs-dock", "The drive isn't mounted. Try 'Remount drive'.", [System.Windows.Forms.ToolTipIcon]::Warning) }
})
$remount.add_Click({
    # every drive that starts at login, set up again as it is (a first one if there is none)
    $command = "& '$PSScriptRoot\autostart.ps1' " + $(if (Get-MainDrive) { "-Refresh" } else { "" })
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $command
    $tray.ShowBalloonTip(4000, "rar2fs-dock", "Remounting the drive...", [System.Windows.Forms.ToolTipIcon]::Info)
})
$restart.add_Click({
    # don't cut off someone's film without asking
    $busy = @(& (Join-Path $PSScriptRoot "in-use.ps1") -Quiet)
    if ($busy) {
        $list = ($busy | Select-Object -First 5 | ForEach-Object { "$(@($_.users) -join ', ') is reading $($_.path)" }) -join "`n"
        $answer = [System.Windows.Forms.MessageBox]::Show("The drive is in use right now:`n`n$list`n`nRestarting interrupts that for about a minute. Restart anyway?",
            "rar2fs-dock", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
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
    $drive = Get-MainDrive
    $openDrive.Text =$(if ($drive) { "Open drive ($drive)" } else { "Open drive" })
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
