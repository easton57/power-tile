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

$script:LogWriter = $null
$script:LogWriteCount = 0

function Write-Log {
    param([string]$Message)
    try {
        if (-not $script:LogWriter) {
            # One handle for the life of the process - Add-Content re-opens the file (and
            # re-triggers the AV filter driver on a managed machine) for every single line.
            # Shared read/write so an overlapping restart can't lock the other one out.
            $stream = New-Object System.IO.FileStream($script:LogPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            $script:LogWriter = New-Object System.IO.StreamWriter($stream, (New-Object System.Text.UTF8Encoding($false)))
            $script:LogWriter.AutoFlush = $true
        }
        $script:LogWriteCount++
        if (($script:LogWriteCount % 50) -eq 0 -and $script:LogWriter.BaseStream.Length -gt 512KB) {
            $script:LogWriter.Dispose()
            $script:LogWriter = $null
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).1" -Force -ErrorAction Stop
            return
        }
        $script:LogWriter.WriteLine("[$([datetime]::Now.ToString('yyyy-MM-dd HH:mm:ss.fff'))] $Message")
    } catch { }
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
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
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
    [DllImport("user32.dll")] static extern IntPtr MonitorFromPoint(System.Drawing.Point pt, uint dwFlags);
    [DllImport("shcore.dll")] static extern int GetDpiForMonitor(IntPtr hmonitor, int dpiType, out uint dpiX, out uint dpiY);

    public static int GetDpiAt(System.Drawing.Point pt)
    {
        try
        {
            uint x, y;
            IntPtr mon = MonitorFromPoint(pt, 2); // MONITOR_DEFAULTTONEAREST
            if (GetDpiForMonitor(mon, 0, out x, out y) == 0 && x > 0) return (int)x; // MDT_EFFECTIVE_DPI
        }
        catch (DllNotFoundException) { }
        catch (EntryPointNotFoundException) { }
        return 96;
    }

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

// Ranking runs on every keystroke over every installed app (hundreds of them on a corporate
// image). In PowerShell that meant a function call plus several string allocations per app
// per character typed, which is exactly where the launcher felt sluggish - so the scoring
// lives here, over a lowercase/initials index that's built once per app-list refresh.
public static class FuzzyMatcher
{
    static string[] lowered = new string[0];
    static string[] initials = new string[0];

    public static void SetItems(string[] items)
    {
        string[] source = items ?? new string[0];
        lowered = new string[source.Length];
        initials = new string[source.Length];
        var sb = new StringBuilder(32);
        for (int i = 0; i < source.Length; i++)
        {
            string lower = (source[i] ?? "").ToLowerInvariant();
            lowered[i] = lower;
            sb.Length = 0;
            bool atWordStart = true;
            foreach (char c in lower)
            {
                if (c == ' ' || c == '-' || c == '_' || c == '.') { atWordStart = true; continue; }
                if (atWordStart) { sb.Append(c); atWordStart = false; }
            }
            initials[i] = sb.ToString();
        }
    }

    // Returns the indices of the best matches, highest score first. An empty query matches
    // everything, so the frequency boost (and then the caller's original order) decides.
    public static int[] Rank(string query, int[] boosts, int max)
    {
        string q = (query ?? "").ToLowerInvariant();
        var order = new List<int>();
        var keys = new List<long>();
        for (int i = 0; i < lowered.Length; i++)
        {
            int score;
            if (q.Length == 0) score = 0;
            else if (!TryScore(lowered[i], initials[i], q, out score)) continue;
            if (boosts != null && i < boosts.Length) score += boosts[i];
            // Negated score in the high word, index in the low word: one ascending sort then
            // gives best-first, with equal scores left in the caller's (alphabetical) order.
            keys.Add(((long)(-score) << 32) | (uint)i);
            order.Add(i);
        }

        int[] result = order.ToArray();
        long[] sortKeys = keys.ToArray();
        Array.Sort(sortKeys, result);
        if (result.Length <= max) return result;
        var top = new int[max];
        Array.Copy(result, top, max);
        return top;
    }

    // Prefix > word initials ("vsc" -> Visual Studio Code) > substring > in-order subsequence.
    static bool TryScore(string text, string textInitials, string query, out int score)
    {
        score = 0;
        if (text.StartsWith(query, StringComparison.Ordinal)) { score = 1000 - text.Length; return true; }
        if (query.Length > 1 && textInitials.StartsWith(query, StringComparison.Ordinal)) { score = 800 - text.Length; return true; }
        int idx = text.IndexOf(query, StringComparison.Ordinal);
        if (idx >= 0) { score = 500 - idx; return true; }
        int from = 0;
        int total = 0;
        foreach (char c in query)
        {
            int found = text.IndexOf(c, from);
            if (found < 0) return false;
            total += 100 - found;
            from = found + 1;
        }
        score = total;
        return true;
    }
}

public class LauncherForm : Form
{
    public event EventHandler HotKeyPressed;
    public event EventHandler ClickedOutside;

    // A low-level mouse hook (installed only while the launcher is open) is the one reliable way
    // to see every click outside it - including on windows that never take focus, like the
    // power-tile status bar, where no Deactivate ever fires. Done in C# because the callback
    // runs for every mouse event system-wide and must return quickly.
    delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    struct MSLLHOOKSTRUCT { public int x; public int y; public uint mouseData; public uint flags; public uint time; public IntPtr dwExtraInfo; }

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc fn, IntPtr hMod, uint threadId);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);

    LowLevelMouseProc mouseProc;
    IntPtr mouseHook = IntPtr.Zero;

    public void StartClickWatch()
    {
        if (mouseHook != IntPtr.Zero) return;
        if (mouseProc == null) mouseProc = MouseHookProc; // must stay referenced while hooked
        mouseHook = SetWindowsHookEx(14, mouseProc, GetModuleHandle(null), 0); // WH_MOUSE_LL
    }

    public void StopClickWatch()
    {
        if (mouseHook == IntPtr.Zero) return;
        UnhookWindowsHookEx(mouseHook);
        mouseHook = IntPtr.Zero;
    }

    IntPtr MouseHookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            int msg = wParam.ToInt32();
            // WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN, WM_XBUTTONDOWN
            if (msg == 0x0201 || msg == 0x0204 || msg == 0x0207 || msg == 0x020B)
            {
                var p = (MSLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(MSLLHOOKSTRUCT));
                RECT r;
                if (GetWindowRect(Handle, out r) && (p.x < r.Left || p.x >= r.Right || p.y < r.Top || p.y >= r.Bottom))
                {
                    // Raise after returning - the click itself still goes through to its target.
                    BeginInvoke(new MethodInvoker(() => { var h = ClickedOutside; if (h != null) h(this, EventArgs.Empty); }));
                }
            }
        }
        return CallNextHookEx(mouseHook, nCode, wParam, lParam);
    }

    protected override void Dispose(bool disposing)
    {
        StopClickWatch();
        base.Dispose(disposing);
    }

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
$script:Boosts = New-Object 'int[]' 0 # launch-frequency boost per app, aligned with $script:Apps
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
            [FuzzyMatcher]::SetItems([string[]]($script:Apps | ForEach-Object { $_.Name }))
            Update-HistoryBoosts
            if ($script:Form.Visible) { Update-Results }
        }
    } catch {
        Write-Log "Failed to enumerate installed apps: $_"
    } finally {
        $ps.Dispose()
    }
}

function Update-HistoryBoosts {
    # Frequency boosts, kept as a plain int[] aligned with $script:Apps so ranking never has
    # to walk the history hashtable per app per keystroke.
    $boosts = New-Object 'int[]' $script:Apps.Count
    for ($i = 0; $i -lt $script:Apps.Count; $i++) {
        $id = $script:Apps[$i].AppID
        if ($script:History.ContainsKey($id)) { $boosts[$i] = [Math]::Min($script:History[$id], 20) * 15 }
    }
    $script:Boosts = $boosts
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
$script:Scale = 1.0
$script:CurrentDpi = 0

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
            $inset = 8 * $script:Scale
            $rect = [System.Drawing.RectangleF]::new($e.Bounds.X + $inset, $e.Bounds.Y, $e.Bounds.Width - $inset, $e.Bounds.Height)
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
    $indices = [FuzzyMatcher]::Rank($query, $script:Boosts, 30)
    $results = @(foreach ($i in $indices) { $script:Apps[$i] })
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
    $script:DismissTimer.Stop()
    $script:Form.StopClickWatch()
    if ($script:Form.Visible) { $script:Form.Hide() }
}

# Deactivate alone misses some ways of losing the launcher: focus being taken before its own
# activation finished left it visible but unfocused, so only Escape-after-refocusing closed
# it. Poll while it's open and dismiss once focus is gone (clicks outside it - including on
# windows that never take focus - are caught by the ClickedOutside mouse hook instead).
function Test-LauncherDismiss {
    $elapsed = ((Get-Date) - $script:ShownAt).TotalMilliseconds
    if ($elapsed -lt 300) { return }
    if ([LauncherNative]::GetForegroundWindow() -eq $script:Form.Handle) { return }
    if ($script:WasActivated -or $elapsed -gt 1500) {
        Hide-Launcher
    } else {
        # Never got focus in the first place - keep trying briefly before giving up.
        if ([LauncherNative]::Activate($script:Form.Handle)) { $script:TextBox.Focus() | Out-Null }
    }
}

$script:DismissTimer = New-Object System.Windows.Forms.Timer
$script:DismissTimer.Interval = 100
$script:DismissTimer.add_Tick({ try { Test-LauncherDismiss } catch { Write-Log "Dismiss check failed: $_" } })

# The process is per-monitor DPI aware, so WinForms won't scale anything itself - fonts are
# built in pixels for the target monitor's DPI and the window is sized from its work area.
function Set-LauncherScale {
    param([int]$Dpi)
    if ($Dpi -eq $script:CurrentDpi) { return }
    $script:CurrentDpi = $Dpi
    $script:Scale = $Dpi / 96.0
    $oldText = $script:TextBox.Font
    $oldList = $script:ListBox.Font
    $script:TextBox.Font = New-Object System.Drawing.Font('Segoe UI', [float](14 * $Dpi / 72.0), [System.Drawing.GraphicsUnit]::Pixel)
    $script:ListBox.Font = New-Object System.Drawing.Font('Segoe UI', [float](11 * $Dpi / 72.0), [System.Drawing.GraphicsUnit]::Pixel)
    $script:ListBox.ItemHeight = [Math]::Min(255, $script:ListBox.Font.Height + [int](8 * $script:Scale))
    $script:Form.Padding = New-Object System.Windows.Forms.Padding([Math]::Max(1, [int][Math]::Round($script:Scale)))
    $oldText.Dispose()
    $oldList.Dispose()
}

function Show-Launcher {
    $cursor = [System.Windows.Forms.Cursor]::Position
    $area = [System.Windows.Forms.Screen]::FromPoint($cursor).WorkingArea
    Set-LauncherScale -Dpi ([LauncherNative]::GetDpiAt($cursor))
    $width = [int][Math]::Min($area.Width * 0.9, [Math]::Max(560 * $script:Scale, $area.Width * 0.3))
    $height = [int][Math]::Min($area.Height * 0.8, [Math]::Max(380 * $script:Scale, $area.Height * 0.4))
    $script:Form.Bounds = New-Object System.Drawing.Rectangle(
        ($area.X + [int](($area.Width - $width) / 2)),
        ($area.Y + [int](($area.Height - $height) / 3)),
        $width, $height)
    $script:TextBox.Text = ''
    Update-Results
    $script:ShownAt = Get-Date
    $script:WasActivated = $false
    $script:Form.Show()
    $script:Form.Activate()
    if (-not [LauncherNative]::Activate($script:Form.Handle)) {
        Write-Log "Could not take foreground (fg=$([LauncherNative]::GetForegroundWindow()))."
    }
    $script:TextBox.Focus() | Out-Null
    $script:DismissTimer.Start()
    $script:Form.StartClickWatch()
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
        Update-HistoryBoosts
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
$form.add_Activated({ $script:WasActivated = $true })
$form.add_ClickedOutside({ try { Hide-Launcher } catch { Write-Log "Click-outside handling failed: $_" } })
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
# Deliberately lazy: this runs for the whole session, and nothing here is time-critical.
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
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
    if ($script:LogWriter) { try { $script:LogWriter.Dispose() } catch { } }
}
