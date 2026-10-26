#Requires -Version 5.1
<#
    power-tile app launcher - a standalone fuzzy finder over installed apps (Get-StartApps
    covers both classic Win32 shortcuts and Store/UWP apps).

    USAGE
        powershell.exe -ExecutionPolicy Bypass -File .\AppLauncher.ps1
        (TilingWM.ps1 starts this automatically and passes -ParentPid so it exits with the WM.)

    Runs as its own process on purpose:
      * It owns its own global hotkey, so Windows grants it foreground rights when the key is
        pressed - no input-faking tricks needed to get focus, which is what made the old
        in-process launcher flash open and immediately close.
      * The window is built once and only shown/hidden, and the app list is cached and
        refreshed on a background runspace, so opening it never blocks on Get-StartApps.
      * A slow tiling poll in the WM can no longer delay (or be delayed by) the launcher.

    Reads the AppLauncher hotkey and status-bar colors from TilingWM.config.psd1.
    Up/Down (or Ctrl+N/Ctrl+P) select, Enter launches, Escape or the hotkey again closes.
#>
param(
    # PID of the TilingWM.ps1 process that started this one - the launcher exits when it does.
    [int]$ParentPid = 0
)

$script:WindowTitle = 'power-tile launcher' # TilingWM.ps1 matches on this - keep them in sync
Import-Module (Join-Path $PSScriptRoot 'PowerTile.Common.psm1') -Force -DisableNameChecking

$script:DataDir = Get-PowerTileDataDirectory
$script:LogPath = Join-Path $script:DataDir 'AppLauncher.log'
$script:HistoryPath = Join-Path $script:DataDir 'AppLauncher.history.json'

function Write-Log {
    param([string]$Message)
    try {
        $existing = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt 512KB) {
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).1" -Force -ErrorAction Stop
        }
    } catch { }
    try { Add-Content -LiteralPath $script:LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] $Message" -ErrorAction Stop } catch { }
}

# ---------------------------------------------------------------------------
# Configuration (shared with TilingWM.ps1)
# ---------------------------------------------------------------------------

$script:Config = @{
    AppLauncherHotKey      = 'Ctrl+Shift+Space'
    StatusBarBackColor     = '#181818'
    StatusBarActiveColor   = '#0078D7'
    StatusBarBusyColor     = '#3C3C3C'
    StatusBarTextColor     = '#FFFFFF'
    StatusBarIdleTextColor = '#808080'
}
$configPath = Join-Path $PSScriptRoot 'TilingWM.config.psd1'
if (Test-Path -LiteralPath $configPath) {
    try {
        $userConfig = Import-PowerShellDataFile -Path $configPath
        foreach ($k in @($script:Config.Keys)) {
            if ($userConfig.ContainsKey($k)) { $script:Config[$k] = $userConfig[$k] }
        }
        if ($userConfig.HotKeys -and $userConfig.HotKeys.AppLauncher) {
            $script:Config.AppLauncherHotKey = $userConfig.HotKeys.AppLauncher
        }
    } catch {
        Write-Log "Failed to load config file '$configPath': $_. Using defaults."
    }
}

# ---------------------------------------------------------------------------
# Single instance - a restart of the WM can briefly overlap the old launcher, so wait
# for it to go away instead of bailing out (or both fighting over the hotkey).
# ---------------------------------------------------------------------------

$script:Mutex = New-Object System.Threading.Mutex($false, 'Local\PowerTile.AppLauncher')
$acquired = $false
try { $acquired = $script:Mutex.WaitOne(5000) } catch [System.Threading.AbandonedMutexException] { $acquired = $true }
if (-not $acquired) {
    Write-Log "Another launcher instance is already running - exiting."
    exit 0
}

# ---------------------------------------------------------------------------
# Win32 interop
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('LauncherForm' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public static class LauncherNative
{
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int dwProcessId);

    // Receiving WM_HOTKEY normally grants this process the right to take the foreground,
    // so plain SetForegroundWindow is tried first. Attaching to the current foreground
    // thread's input queue is only a fallback for when something else holds the
    // foreground lock - no synthetic keystrokes, which could corrupt held modifier state.
    public static bool Activate(IntPtr hWnd)
    {
        if (GetForegroundWindow() == hWnd) return true;
        if (SetForegroundWindow(hWnd) && GetForegroundWindow() == hWnd) return true;

        IntPtr fg = GetForegroundWindow();
        uint dummy;
        uint fgThread = fg == IntPtr.Zero ? 0 : GetWindowThreadProcessId(fg, out dummy);
        uint curThread = GetCurrentThreadId();
        bool attached = fgThread != 0 && fgThread != curThread && AttachThreadInput(curThread, fgThread, true);
        try
        {
            BringWindowToTop(hWnd);
            SetForegroundWindow(hWnd);
        }
        finally
        {
            if (attached) AttachThreadInput(curThread, fgThread, false);
        }
        return GetForegroundWindow() == hWnd;
    }
}

public class LauncherForm : Form
{
    public event EventHandler HotKeyPressed;

    protected override CreateParams CreateParams
    {
        get
        {
            var cp = base.CreateParams;
            // WS_EX_TOOLWINDOW keeps it out of Alt+Tab and the tiler. WS_EX_TOPMOST is set here
            // rather than via the TopMost property, whose SetWindowPos call (no SWP_NOACTIVATE)
            // would activate the still-hidden window at startup and swallow keystrokes.
            cp.ExStyle |= 0x00000080 | 0x00000008;
            return cp;
        }
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x0312) // WM_HOTKEY
        {
            var handler = HotKeyPressed;
            if (handler != null) handler(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}
'@
}

try { [LauncherNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }

function ConvertTo-Color {
    param([string]$Spec, [System.Drawing.Color]$Default)
    if (-not $Spec) { return $Default }
    try { return [System.Drawing.ColorTranslator]::FromHtml($Spec) } catch { return $Default }
}

# ---------------------------------------------------------------------------
# App list (cached, refreshed off the UI thread) and launch history
# ---------------------------------------------------------------------------

$script:Apps = @()
$script:AppsLoadedAt = [datetime]::MinValue
$script:AppRefreshPs = $null
$script:AppRefreshHandle = $null
$script:History = @{} # AppID -> launch count, boosts frequently used apps in the results

try {
    if (Test-Path -LiteralPath $script:HistoryPath) {
        $saved = Get-Content -LiteralPath $script:HistoryPath -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $script:History[$p.Name] = [int]$p.Value }
    }
} catch { Write-Log "Failed to read launch history: $_" }

function Start-AppListRefresh {
    if ($script:AppRefreshPs) { return }
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
            Get-StartApps | Where-Object { $_.Name -and $_.AppID } |
                Sort-Object Name, AppID -Unique |
                ForEach-Object { [PSCustomObject]@{ Name = [string]$_.Name; AppID = [string]$_.AppID } }
        })
    $script:AppRefreshPs = $ps
    $script:AppRefreshHandle = $ps.BeginInvoke()
}

function Complete-AppListRefresh {
    if (-not $script:AppRefreshPs -or -not $script:AppRefreshHandle.IsCompleted) { return }
    $ps = $script:AppRefreshPs
    $script:AppRefreshPs = $null
    try {
        $result = @($ps.EndInvoke($script:AppRefreshHandle))
        if ($ps.Streams.Error.Count -gt 0) { Write-Log "Get-StartApps reported: $($ps.Streams.Error[0])" }
        if ($result.Count -gt 0) {
            $script:Apps = $result
            $script:AppsLoadedAt = Get-Date
            if ($script:Form.Visible) { Update-Results }
        }
    } catch {
        Write-Log "Failed to enumerate installed apps: $_"
    } finally {
        $ps.Dispose()
    }
}

function Get-FuzzyScore {
    # Higher is better; $null means no match. Prefix > word-initials ("vsc" -> Visual Studio
    # Code) > substring > in-order subsequence.
    param([string]$Text, [string]$Query)
    $t = $Text.ToLowerInvariant()
    $q = $Query.ToLowerInvariant()
    if ($t.StartsWith($q)) { return 1000 - $t.Length }
    $initials = -join ($t -split '[\s\-_.]+' | Where-Object { $_ } | ForEach-Object { $_[0] })
    if ($q.Length -gt 1 -and $initials.StartsWith($q)) { return 800 - $t.Length }
    $idx = $t.IndexOf($q)
    if ($idx -ge 0) { return 500 - $idx }
    $searchFrom = 0
    $score = 0
    foreach ($c in $q.ToCharArray()) {
        $found = $t.IndexOf($c, $searchFrom)
        if ($found -lt 0) { return $null }
        $score += (100 - $found)
        $searchFrom = $found + 1
    }
    return $score
}

function Get-HistoryBoost {
    param([string]$AppID)
    if ($script:History.ContainsKey($AppID)) { return [Math]::Min($script:History[$AppID], 20) * 15 }
    return 0
}

# ---------------------------------------------------------------------------
# UI - built once, then only shown/hidden
# ---------------------------------------------------------------------------

$script:Theme = @{
    Background = ConvertTo-Color $script:Config.StatusBarBackColor ([System.Drawing.Color]::FromArgb(30, 30, 30))
    Field      = ConvertTo-Color $script:Config.StatusBarBusyColor ([System.Drawing.Color]::FromArgb(45, 45, 45))
    Text       = ConvertTo-Color $script:Config.StatusBarTextColor ([System.Drawing.Color]::White)
    Dim        = ConvertTo-Color $script:Config.StatusBarIdleTextColor ([System.Drawing.Color]::Gray)
    Accent     = ConvertTo-Color $script:Config.StatusBarActiveColor ([System.Drawing.Color]::FromArgb(0, 120, 215))
}
$script:Filtered = @()
$script:ShownAt = [datetime]::MinValue

$form = New-Object LauncherForm
$form.Text = $script:WindowTitle
$form.FormBorderStyle = 'None'
$form.StartPosition = 'Manual'
$form.ShowInTaskbar = $false
$form.KeyPreview = $true
$form.Size = New-Object System.Drawing.Size(560, 380)
# The 1px padding shows the accent color as a border around the dark content.
$form.BackColor = $script:Theme.Accent
$form.Padding = New-Object System.Windows.Forms.Padding(1)

$textBox = New-Object System.Windows.Forms.TextBox
$textBox.Dock = 'Top'
$textBox.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 14
$textBox.BackColor = $script:Theme.Field
$textBox.ForeColor = $script:Theme.Text
$textBox.BorderStyle = 'None'

$listBox = New-Object System.Windows.Forms.ListBox
$listBox.Dock = 'Fill'
$listBox.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 11
$listBox.BackColor = $script:Theme.Background
$listBox.ForeColor = $script:Theme.Text
$listBox.BorderStyle = 'None'
$listBox.IntegralHeight = $false
# ItemHeight isn't recalculated from Font once DrawMode is OwnerDrawFixed, so set it explicitly.
$listBox.DrawMode = 'OwnerDrawFixed'
$listBox.ItemHeight = $listBox.Font.Height + 8
$listBox.add_DrawItem({
        param($sender, $e)
        try {
            if ($e.Index -lt 0) { return }
            $selected = ($e.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
            $back = if ($selected) { $script:Theme.Accent } else { $script:Theme.Background }
            $backBrush = New-Object System.Drawing.SolidBrush $back
            $e.Graphics.FillRectangle($backBrush, $e.Bounds)
            $backBrush.Dispose()
            $color = if ($sender.Items[$e.Index] -eq $script:LoadingText) { $script:Theme.Dim } else { $script:Theme.Text }
            $textBrush = New-Object System.Drawing.SolidBrush $color
            $format = New-Object System.Drawing.StringFormat
            $format.LineAlignment = [System.Drawing.StringAlignment]::Center
            $format.Trimming = [System.Drawing.StringTrimming]::EllipsisCharacter
            $format.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap
            $rect = [System.Drawing.RectangleF]::new($e.Bounds.X + 8, $e.Bounds.Y, $e.Bounds.Width - 8, $e.Bounds.Height)
            $e.Graphics.DrawString([string]$sender.Items[$e.Index], $e.Font, $textBrush, $rect, $format)
            $textBrush.Dispose()
            $format.Dispose()
        } catch { Write-Log "Draw item failed: $_" }
    })

# Enter isn't an input key for a single-line TextBox, so a KeyDown handler never sees it -
# hidden Accept/Cancel buttons are the standard WinForms way to get form-wide Enter/Escape.
$acceptButton = New-Object System.Windows.Forms.Button
$acceptButton.Size = New-Object System.Drawing.Size(0, 0)
$acceptButton.TabStop = $false
$cancelButton = New-Object System.Windows.Forms.Button
$cancelButton.Size = New-Object System.Drawing.Size(0, 0)
$cancelButton.TabStop = $false

$form.Controls.Add($listBox)
$form.Controls.Add($textBox)
$form.Controls.Add($acceptButton)
$form.Controls.Add($cancelButton)
$form.AcceptButton = $acceptButton
$form.CancelButton = $cancelButton
$script:Form = $form
$script:TextBox = $textBox
$script:ListBox = $listBox
$script:LoadingText = 'Loading apps...'

function Update-Results {
    $query = $script:TextBox.Text.Trim()
    # The outer @() must wrap the whole if/else so a single match stays an array.
    $results = @(if ($query) {
            $scored = foreach ($app in $script:Apps) {
                $score = Get-FuzzyScore -Text $app.Name -Query $query
                if ($null -ne $score) { [PSCustomObject]@{ App = $app; Score = $score + (Get-HistoryBoost $app.AppID) } }
            }
            $scored | Sort-Object Score -Descending | Select-Object -First 30 -ExpandProperty App
        } else {
            $script:Apps |
                Sort-Object @{ Expression = { Get-HistoryBoost $_.AppID }; Descending = $true }, Name |
                Select-Object -First 30
        })
    $script:Filtered = $results
    $lb = $script:ListBox
    $lb.BeginUpdate()
    $lb.Items.Clear()
    foreach ($app in $results) { [void]$lb.Items.Add($app.Name) }
    if ($lb.Items.Count -gt 0) {
        $lb.SelectedIndex = 0
    } elseif ($script:Apps.Count -eq 0) {
        [void]$lb.Items.Add($script:LoadingText)
    }
    $lb.EndUpdate()
}

function Hide-Launcher {
    if ($script:Form.Visible) { $script:Form.Hide() }
}

function Show-Launcher {
    $screen = [System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position)
    $area = $screen.Bounds
    $script:Form.Location = New-Object System.Drawing.Point(
        ($area.X + [int](($area.Width - $script:Form.Width) / 2)),
        ($area.Y + [int](($area.Height - $script:Form.Height) / 3)))
    $script:TextBox.Text = ''
    Update-Results
    $script:ShownAt = Get-Date
    $script:Form.Show()
    $script:Form.Activate()
    if (-not [LauncherNative]::Activate($script:Form.Handle)) {
        Write-Log "Could not take foreground (fg=$([LauncherNative]::GetForegroundWindow()))."
    }
    $script:TextBox.Focus() | Out-Null
    if (((Get-Date) - $script:AppsLoadedAt).TotalSeconds -gt 60) { Start-AppListRefresh }
}

function Invoke-Launch {
    $lb = $script:ListBox
    if ($lb.SelectedIndex -lt 0 -or $lb.SelectedIndex -ge $script:Filtered.Count) { return }
    $app = $script:Filtered[$lb.SelectedIndex]
    try {
        # Store apps start via a broker (explorer/COM), not as our child - let whichever
        # process ends up owning the new window take the foreground from us.
        [LauncherNative]::AllowSetForegroundWindow(-1) | Out-Null # ASFW_ANY
        # Classic shortcuts/exes report a real file path as AppID; Store/UWP apps (and
        # known-folder-relative paths) only launch through shell:AppsFolder.
        if (Test-Path -LiteralPath $app.AppID -PathType Leaf) {
            Start-Process -FilePath $app.AppID
        } else {
            Start-Process -FilePath "shell:AppsFolder\$($app.AppID)"
        }
        $script:History[$app.AppID] = 1 + $(if ($script:History.ContainsKey($app.AppID)) { $script:History[$app.AppID] } else { 0 })
        try { $script:History | ConvertTo-Json -Compress | Set-Content -LiteralPath $script:HistoryPath -ErrorAction Stop } catch { Write-Log "Failed to save launch history: $_" }
    } catch {
        Write-Log "Failed to start '$($app.Name)' ($($app.AppID)): $_"
    }
    # Hide only after starting the app - while this process is still foreground, Windows
    # lets the new app take focus instead of opening behind whatever was there before.
    Hide-Launcher
}

$acceptButton.add_Click({ try { Invoke-Launch } catch { Write-Log "Launch failed: $_" } })
$cancelButton.add_Click({ Hide-Launcher })
$listBox.add_MouseDoubleClick({ try { Invoke-Launch } catch { Write-Log "Launch failed: $_" } })
$textBox.add_TextChanged({ try { Update-Results } catch { Write-Log "Filter failed: $_" } })
$form.add_KeyDown({
        param($sender, $e)
        try {
            $lb = $script:ListBox
            $down = $e.KeyCode -eq 'Down' -or ($e.Control -and $e.KeyCode -eq 'N')
            $up = $e.KeyCode -eq 'Up' -or ($e.Control -and $e.KeyCode -eq 'P')
            if ($down) {
                if ($lb.SelectedIndex -lt $lb.Items.Count - 1) { $lb.SelectedIndex++ }
                $e.Handled = $true; $e.SuppressKeyPress = $true
            } elseif ($up) {
                if ($lb.SelectedIndex -gt 0) { $lb.SelectedIndex-- }
                $e.Handled = $true; $e.SuppressKeyPress = $true
            }
        } catch { Write-Log "Key handling failed: $_" }
    })
# Click-away closes it, like a Start menu. Activation can bounce for a moment while taking the
# foreground from another app; within that grace window, grab focus back instead of closing.
$form.add_Deactivate({
        try {
            if (((Get-Date) - $script:ShownAt).TotalMilliseconds -lt 400) {
                [LauncherNative]::Activate($script:Form.Handle) | Out-Null
                $script:TextBox.Focus() | Out-Null
                return
            }
            Hide-Launcher
        } catch { Write-Log "Deactivate handling failed: $_" }
    })
# Alt+F4 or similar should hide, not destroy, the reusable window.
$form.add_FormClosing({
        param($sender, $e)
        if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $e.Cancel = $true
            Hide-Launcher
        }
    })
$form.add_HotKeyPressed({
        try {
            if ($script:Form.Visible -and [LauncherNative]::GetForegroundWindow() -eq $script:Form.Handle) { Hide-Launcher } else { Show-Launcher }
        } catch { Write-Log "Show failed: $_" }
    })

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$null = $form.Handle # create the window (still hidden) so RegisterHotKey has a target
$script:HotKeyId = 1
try {
    $spec = ConvertTo-HotKeySpec -Spec $script:Config.AppLauncherHotKey
    if (-not [LauncherNative]::RegisterHotKey($form.Handle, $script:HotKeyId, $spec.Modifiers, $spec.VirtualKey)) {
        Write-Log "Could not register hotkey '$($script:Config.AppLauncherHotKey)' - it may already be in use by another application."
        exit 1
    }
} catch {
    Write-Log "Invalid launcher hotkey '$($script:Config.AppLauncherHotKey)': $_"
    exit 1
}

$script:Parent = $null
if ($ParentPid -gt 0) {
    try { $script:Parent = Get-Process -Id $ParentPid -ErrorAction Stop } catch {
        Write-Log "Parent process $ParentPid is not running - exiting."
        exit 0
    }
}

# Polls the background app-list refresh, and exits if the WM that started us has gone away
# (covers a crash or hard kill, where TilingWM.ps1 never gets to stop this process itself).
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 250
$timer.add_Tick({
        try {
            Complete-AppListRefresh
            if ($script:Parent) {
                $alive = try { -not $script:Parent.HasExited } catch { [bool](Get-Process -Id $ParentPid -ErrorAction SilentlyContinue) }
                if (-not $alive) { [System.Windows.Forms.Application]::ExitThread() }
            }
        } catch { Write-Log "Timer tick failed: $_" }
    })

Start-AppListRefresh
$timer.Start()
Write-Log "Launcher running (pid $PID, parent $ParentPid, hotkey $($script:Config.AppLauncherHotKey))."

try {
    [System.Windows.Forms.Application]::Run()
} finally {
    $timer.Stop()
    $timer.Dispose()
    try { [LauncherNative]::UnregisterHotKey($form.Handle, $script:HotKeyId) | Out-Null } catch { }
    if ($script:AppRefreshPs) { try { $script:AppRefreshPs.Stop(); $script:AppRefreshPs.Dispose() } catch { } }
    if (-not $form.IsDisposed) { $form.Dispose() }
    try { $script:Mutex.ReleaseMutex() } catch { }
    $script:Mutex.Dispose()
    Write-Log "Launcher stopped."
}
