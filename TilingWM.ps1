#Requires -Version 5.1
<#
    PS Tiling Manager - a Hyprland/i3-style master-stack auto-tiling window manager
    for Windows, written entirely in PowerShell (Win32 API via Add-Type P/Invoke).

    USAGE
        powershell.exe -ExecutionPolicy Bypass -File .\TilingWM.ps1
        (Run elevated too if you want it to also manage elevated/admin windows.)

    DEFAULT HOTKEYS (edit TilingWM.config.psd1 next to this script to change them)
        Alt+H / Alt+L   Focus master / stack column (vim-style left/right)
        Alt+J / Alt+K   Focus down / up within the stack (vim-style)
        Alt+Enter       Swap focused window with master
        Alt+Shift+H     Move focused window to the master column
        Alt+Shift+L     Move focused window into the stack column
        Alt+Shift+J     Move focused window down the stack
        Alt+Shift+K     Move focused window up the stack
        Alt+[ / Alt+]   Shrink / grow the master area
        Alt+Q           Close focused window
        Alt+Shift+Space Toggle floating (exclude/include from tiling)
        Alt+Shift+F     Bring floating windows (on the active workspace) to the front
        Alt+Shift+R     Force re-tile
        Alt+Shift+E     Quit
        Alt+1..9        Switch to workspace 1-9 (fake/virtual desktops)
        Alt+Shift+1..9  Move focused window to workspace 1-9
        Ctrl+Shift+Space  Open the app launcher (fuzzy-search installed apps, Enter to run)
        Ctrl+Shift+R      Restart (relaunch fresh - picks up script/config edits without
                          logging out)

    Focus follows mouse is on by default (hover a tiled window to focus it, no
    click needed) - set FocusFollowsMouse = $false in the config to disable it.

    App-launcher shortcuts: define an AppShortcuts table in TilingWM.config.psd1
    (name -> @{ Key = 'Alt+Shift+Enter'; Path = 'wt.exe' }) to bind hotkeys that
    launch programs. None are bound by default; see the sample config for examples.

    The Ctrl+Shift+Space fuzzy launcher lives in AppLauncher.ps1, which this script starts
    as a separate process (and stops on exit) whenever HotKeys.AppLauncher is set.

    A tray icon is shown while running; right-click it for "Retile now" / "Restart" / "Exit".
    A status bar across the top of the primary monitor lists which apps are open
    on each workspace (1-9), highlighting the active one - set ShowStatusBar =
    $false in the config to disable it. Set HideTaskbar = $true to also hide the
    real Windows taskbar (restored automatically on exit) and reclaim its space
    for tiling; StatusBarShowClock then adds a clock/date to the status bar so
    you don't lose the taskbar's clock in the process.
    Only auto-tiling + hotkeys are implemented; compositor-level effects (blur/animations/
    gaps rendering) are not possible on Windows. Workspaces are simulated by hiding/showing
    windows, not real virtual desktops - a window's taskbar entry disappears while it's on
    an inactive workspace.

    Only one instance runs at a time; logs are written to %LOCALAPPDATA%\power-tile.
#>

Import-Module (Join-Path $PSScriptRoot 'PowerTile.Common.psm1') -Force -DisableNameChecking

# ---------------------------------------------------------------------------
# Logging - written to a file even when running hidden (autostart uses
# -WindowStyle Hidden, so console output would otherwise be lost)
# ---------------------------------------------------------------------------

$script:DataDir = Get-PowerTileDataDirectory
$script:LogPath = Join-Path $script:DataDir 'TilingWM.log'
$script:LogLevelRank = @{ Debug = 0; Info = 1; Warning = 2 }
function Write-Log {
    param([string]$Message, [ValidateSet('Debug', 'Info', 'Warning')][string]$Level = 'Warning')
    # Config isn't loaded yet for the earliest calls, so default to Info-and-above.
    $minLevel = if ($script:Config -and $script:Config.LogLevel) { [string]$script:Config.LogLevel } else { 'Info' }
    if (-not $script:LogLevelRank.ContainsKey($minLevel)) { $minLevel = 'Info' }
    if ($script:LogLevelRank[$Level] -lt $script:LogLevelRank[$minLevel]) { return }

    switch ($Level) {
        'Warning' { Write-Warning $Message }
        'Info' { Write-Host $Message -ForegroundColor Cyan }
        default { Write-Host $Message -ForegroundColor DarkGray }
    }
    try {
        # Debug logging is chatty enough to fill a disk over weeks of uptime - roll the file
        # over once instead of truncating, so the run leading up to a crash is still readable.
        $maxBytes = 1024 * [int]$(if ($script:Config -and $script:Config.LogMaxSizeKB) { $script:Config.LogMaxSizeKB } else { 2048 })
        $existing = Get-Item -LiteralPath $script:LogPath -ErrorAction SilentlyContinue
        if ($existing -and $existing.Length -gt $maxBytes) {
            Move-Item -LiteralPath $script:LogPath -Destination "$($script:LogPath).1" -Force -ErrorAction Stop
        }
    } catch { }
    try { Add-Content -LiteralPath $script:LogPath -Value "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff')] [$($Level.Substring(0,1))] $Message" -ErrorAction Stop } catch { }
}

# ---------------------------------------------------------------------------
# Single instance - two managers tiling the same windows fight each other endlessly.
# A restart (Ctrl+Shift+R) launches the new instance before the old one has finished
# shutting down, so wait for the lock briefly rather than giving up immediately.
# ---------------------------------------------------------------------------

$script:InstanceMutex = New-Object System.Threading.Mutex($false, 'Local\PowerTile.TilingWM')
$instanceAcquired = $false
try { $instanceAcquired = $script:InstanceMutex.WaitOne(15000) } catch [System.Threading.AbandonedMutexException] { $instanceAcquired = $true }
if (-not $instanceAcquired) {
    Write-Log "Another PS Tiling Manager instance is already running - exiting (pid $PID)."
    exit 1
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

$script:DefaultConfig = @{
    Gap                = 8
    MasterRatio        = 0.55
    # Safety-net rescan interval; window show/hide events already trigger an immediate one.
    PollIntervalMs      = 1000
    # 'Warning' (problems only), 'Info' (+ lifecycle events), or 'Debug' (+ per-layout
    # geometry, display changes, windows that refuse the size we gave them).
    LogLevel            = 'Info'
    LogMaxSizeKB        = 2048  # TilingWM.log rolls over to TilingWM.log.1 past this size
    FocusFollowsMouse       = $true
    FocusFollowsMousePollMs = 100
    ShowStatusBar       = $true
    StatusBarHeight     = 28
    # Hides the Windows taskbar entirely while the WM is running (restored on exit).
    # Tiling then uses the monitor's full bounds instead of the OS-reported working area.
    HideTaskbar         = $false
    # Shown on the right edge of the status bar - only useful once the taskbar (and its
    # own clock) is hidden, so it's skipped entirely unless HideTaskbar is also $true.
    StatusBarShowClock  = $true
    # Battery percentage next to the clock - shown whenever a battery is detected,
    # regardless of HideTaskbar (desktops without a battery never show it).
    StatusBarShowBattery = $true
    # 'Left', 'Center', or 'Right' placement of the workspace slots within the bar
    StatusBarAlignment     = 'Left'
    # accepts '#RRGGBB' hex or named colors (e.g. 'DodgerBlue')
    # Occupied workspace slots and status widgets are opaque; the rest is transparent.
    StatusBarBackColor     = '#181818'
    StatusBarActiveColor   = '#0078D7'
    StatusBarBusyColor     = '#3C3C3C'
    StatusBarTextColor     = '#FFFFFF'
    StatusBarIdleTextColor = '#808080'
    ExcludedProcesses  = @('ShellExperienceHost', 'SearchHost', 'StartMenuExperienceHost', 'TextInputHost', 'SystemSettings')
    ExcludedClasses    = @('Shell_TrayWnd', 'Shell_SecondaryTrayWnd', 'Progman', 'WorkerW', 'Windows.UI.Core.CoreWindow', 'MultitaskingViewFrame')
    # Windows matching these (by process name or window class) are never hidden for being on
    # an inactive workspace - use this for a chat/call app's notification popup if it isn't
    # already caught automatically (any WS_EX_TOPMOST window gets this treatment for free,
    # which covers most incoming-call/alert popups without needing to list anything here).
    AlwaysVisibleProcesses = @()
    AlwaysVisibleClasses   = @()
    # name -> @{ Key = 'Alt+Shift+Enter'; Path = 'wt.exe'; Arguments = '' (optional) }
    AppShortcuts       = @{}
    HotKeys            = @{
        FocusLeft      = 'Alt+H'
        FocusDown      = 'Alt+J'
        FocusUp        = 'Alt+K'
        FocusRight     = 'Alt+L'
        SwapMaster     = 'Alt+Enter'
        MoveLeft       = 'Alt+Shift+H'
        MoveRight      = 'Alt+Shift+L'
        MoveDown       = 'Alt+Shift+J'
        MoveUp         = 'Alt+Shift+K'
        ShrinkMaster   = 'Alt+['
        GrowMaster     = 'Alt+]'
        CloseWindow    = 'Alt+Q'
        ToggleFloating = 'Alt+Shift+Space'
        FloatingToFront = 'Alt+Shift+F'
        Retile         = 'Alt+Shift+R'
        Quit           = 'Alt+Shift+E'
        # Deliberately not an Alt+ combo - Office apps (Outlook, OneNote, etc.) grab the Alt
        # key for their Ribbon "KeyTips" overlay, which unreliably swallows Alt-chords before
        # they ever reach this app's global hotkey while one of those windows has focus.
        AppLauncher    = 'Ctrl+Shift+Space'
        # Same reasoning as AppLauncher above, plus it mirrors the browser "hard refresh"
        # convention - relaunches a fresh instance so an autostarted WM can pick up script/
        # config edits without logging out, no Alt-chord collision risk either.
        Restart        = 'Ctrl+Shift+R'
    }
}

for ($i = 1; $i -le 9; $i++) {
    $script:DefaultConfig.HotKeys["Workspace$i"] = "Alt+$i"
    $script:DefaultConfig.HotKeys["MoveToWorkspace$i"] = "Alt+Shift+$i"
}

$script:Config = $script:DefaultConfig.Clone()
$configPath = Join-Path $PSScriptRoot 'TilingWM.config.psd1'
if (Test-Path $configPath) {
    try {
        $userConfig = Import-PowerShellDataFile -Path $configPath
        foreach ($k in $userConfig.Keys) { $script:Config[$k] = $userConfig[$k] }
    } catch {
        Write-Log "Failed to load config file '$configPath': $_. Using defaults."
    }
}

# ---------------------------------------------------------------------------
# Win32 interop
# ---------------------------------------------------------------------------

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

if (-not ('Win32' -as [type])) {
    Add-Type -ReferencedAssemblies 'System.Windows.Forms', 'System.Drawing' -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Windows.Forms;

public class Win32
{
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern int GetWindowTextLength(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll")]
    public static extern int GetWindowLong(IntPtr hWnd, int nIndex);

    [DllImport("user32.dll")]
    public static extern int SetWindowLong(IntPtr hWnd, int nIndex, int dwNewLong);

    [DllImport("user32.dll")]
    public static extern IntPtr GetWindow(IntPtr hWnd, uint uCmd);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern int GetClassName(IntPtr hWnd, StringBuilder lpClassName, int nMaxCount);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool IsWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool IsZoomed(IntPtr hWnd);

    // "x,y WxH" for logging, or "?" if the window is gone/inaccessible.
    public static string GetRectString(IntPtr hWnd)
    {
        RECT r;
        if (!GetWindowRect(hWnd, out r)) return "?";
        return string.Format("{0},{1} {2}x{3}", r.Left, r.Top, r.Right - r.Left, r.Bottom - r.Top);
    }

    // Wraps SetWindowPos so the caller can log why it failed instead of just seeing "false".
    public static int SetWindowPosEx(IntPtr hWnd, int X, int Y, int cx, int cy, uint uFlags)
    {
        if (SetWindowPos(hWnd, IntPtr.Zero, X, Y, cx, cy, uFlags)) return 0;
        int err = Marshal.GetLastWin32Error();
        return err == 0 ? -1 : err;
    }

    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    [DllImport("user32.dll")]
    public static extern bool PostMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    public static extern bool DestroyIcon(IntPtr hIcon);

    [DllImport("user32.dll")]
    public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("kernel32.dll")]
    public static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    public static extern bool BringWindowToTop(IntPtr hWnd);

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

    // MOUSEINPUT is the largest member of the native INPUT union, so this layout has the right size.
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public MOUSEINPUT mi; }

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    // Windows only lets the process that generated the last input event take the foreground,
    // and polling the cursor position (focus-follows-mouse) doesn't count. Injecting a zero-
    // distance mouse move earns that permission with no side effects - unlike a synthetic Alt
    // tap, which pops Office's KeyTips/menu bars and can confuse held-modifier state.
    public static void ForceForegroundWindow(IntPtr hWnd)
    {
        if (hWnd == IntPtr.Zero) return;
        if (GetForegroundWindow() == hWnd) return;

        var input = new INPUT[1];
        input[0].type = 0; // INPUT_MOUSE
        input[0].mi.dwFlags = 0x0001; // MOUSEEVENTF_MOVE, dx = dy = 0
        SendInput(1, input, Marshal.SizeOf(typeof(INPUT)));
        if (SetForegroundWindow(hWnd) && GetForegroundWindow() == hWnd) return;

        // Fallback for when another process holds the foreground lock.
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
    }

    [DllImport("dwmapi.dll")]
    public static extern int DwmGetWindowAttribute(IntPtr hwnd, int dwAttribute, out int pvAttribute, int cbAttribute);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }

    [DllImport("user32.dll")]
    public static extern bool GetCursorPos(out POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern IntPtr WindowFromPoint(POINT Point);

    [DllImport("user32.dll")]
    public static extern IntPtr GetAncestor(IntPtr hwnd, uint gaFlags);

    public static IntPtr GetTopLevelWindowAtCursor()
    {
        POINT p;
        if (!GetCursorPos(out p)) return IntPtr.Zero;
        IntPtr hwnd = WindowFromPoint(p);
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        const uint GA_ROOT = 2;
        return GetAncestor(hwnd, GA_ROOT);
    }

    public static List<IntPtr> GetTopLevelWindows()
    {
        var list = new List<IntPtr>();
        EnumWindowsProc callback = (hWnd, lParam) => { list.Add(hWnd); return true; };
        EnumWindows(callback, IntPtr.Zero);
        GC.KeepAlive(callback);
        return list;
    }

    public static string GetTitle(IntPtr hWnd)
    {
        int len = GetWindowTextLength(hWnd);
        if (len == 0) return string.Empty;
        var sb = new StringBuilder(len + 1);
        GetWindowText(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public static string GetClass(IntPtr hWnd)
    {
        var sb = new StringBuilder(256);
        GetClassName(hWnd, sb, sb.Capacity);
        return sb.ToString();
    }

    public delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint dwEventThread, uint dwmsEventTime);

    // WINEVENT_OUTOFCONTEXT (dwFlags=0) delivers callbacks synchronously on the calling
    // thread's message pump - no DLL injection into other processes needed, and no
    // cross-thread marshaling to worry about on the PowerShell side.
    [DllImport("user32.dll")]
    public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);

    [DllImport("user32.dll")]
    public static extern bool UnhookWinEvent(IntPtr hWinEventHook);
}

// Hidden message-only-style window used purely to receive WM_HOTKEY messages
// and to pump the message loop the whole tiling manager runs on.
public class HotKeyWindow : Form
{
    public int LastHotKeyId;
    public event EventHandler HotKeyPressed;

    [DllImport("user32.dll")]
    public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);

    [DllImport("user32.dll")]
    public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    public HotKeyWindow()
    {
        ShowInTaskbar = false;
        FormBorderStyle = FormBorderStyle.FixedToolWindow;
        Opacity = 0;
        Width = 0;
        Height = 0;
        StartPosition = FormStartPosition.Manual;
        Location = new System.Drawing.Point(-2000, -2000);
    }

    protected override void SetVisibleCore(bool value)
    {
        base.SetVisibleCore(false);
    }

    protected override void WndProc(ref Message m)
    {
        const int WM_HOTKEY = 0x0312;
        if (m.Msg == WM_HOTKEY)
        {
            LastHotKeyId = m.WParam.ToInt32();
            var handler = HotKeyPressed;
            if (handler != null) handler(this, EventArgs.Empty);
        }
        base.WndProc(ref m);
    }
}

public class ClickThroughOverlayForm : Form
{
    protected override void WndProc(ref Message m)
    {
        base.WndProc(ref m);
        if (m.Msg == 0x0084) m.Result = (IntPtr)(-1); // WM_NCHITTEST / HTTRANSPARENT
    }
}

// Raises Changed shortly after a top-level window anywhere is shown, hidden, minimized,
// restored, cloaked or uncloaked, so tiling reacts immediately instead of on the next poll.
// Filtering and debouncing happen here in C# because these events arrive by the hundred
// (every control in every app), and running a PowerShell scriptblock for each would be costly.
public class WindowChangeWatcher : IDisposable
{
    public event EventHandler Changed;

    readonly Win32.WinEventDelegate proc;
    readonly List<IntPtr> hooks = new List<IntPtr>();
    readonly Timer debounce = new Timer();
    readonly int debounceMs;
    readonly int minIntervalMs;
    DateTime lastFired = DateTime.MinValue;

    public WindowChangeWatcher(int debounceMs, int minIntervalMs)
    {
        this.debounceMs = Math.Max(1, debounceMs);
        this.minIntervalMs = Math.Max(0, minIntervalMs);
        proc = OnEvent; // must stay referenced for as long as the hooks exist
        debounce.Tick += (s, e) =>
        {
            debounce.Stop();
            lastFired = DateTime.UtcNow;
            var handler = Changed;
            if (handler != null) handler(this, EventArgs.Empty);
        };
    }

    public void Start()
    {
        Hook(0x8002, 0x8003); // EVENT_OBJECT_SHOW .. EVENT_OBJECT_HIDE
        Hook(0x0016, 0x0017); // EVENT_SYSTEM_MINIMIZESTART .. MINIMIZEEND
        Hook(0x8017, 0x8018); // EVENT_OBJECT_CLOAKED .. UNCLOAKED (UWP windows appear this way)
    }

    void Hook(uint eventMin, uint eventMax)
    {
        // WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS - our own bar/menus/tray are ignored.
        IntPtr h = Win32.SetWinEventHook(eventMin, eventMax, IntPtr.Zero, proc, 0, 0, 0x0002);
        if (h != IntPtr.Zero) hooks.Add(h);
    }

    void OnEvent(IntPtr hook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint thread, uint time)
    {
        if (hwnd == IntPtr.Zero || idObject != 0 || idChild != 0) return; // OBJID_WINDOW, CHILDID_SELF
        if (Win32.GetAncestor(hwnd, 2) != hwnd) return; // GA_ROOT - top-level windows only
        int exStyle = Win32.GetWindowLong(hwnd, -20);
        if ((exStyle & 0x80) != 0 && (exStyle & 0x40000) == 0) return; // tooltips, menus, etc.
        if (debounce.Enabled) return;
        // Wait out the rest of a burst, and never fire more often than minIntervalMs even
        // if some app churns windows constantly.
        double sinceLast = (DateTime.UtcNow - lastFired).TotalMilliseconds;
        debounce.Interval = (int)Math.Max(debounceMs, minIntervalMs - sinceLast);
        debounce.Start();
    }

    public void Dispose()
    {
        foreach (var h in hooks) Win32.UnhookWinEvent(h);
        hooks.Clear();
        debounce.Stop();
        debounce.Dispose();
    }
}
'@
}

try { [Win32]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null } catch { }

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:ManagedWindows = @{}   # MonitorKey (Screen.DeviceName) -> List[IntPtr], index 0 = master
$script:FloatingWindows = New-Object 'System.Collections.Generic.HashSet[IntPtr]'
$script:HotKeyActions = @{}     # hotkey id -> action name
$script:HotKeyWindowHandle = [IntPtr]::Zero
$script:WindowWorkspace = @{}   # hwnd -> workspace number, remembered even while hidden
$script:LastWindowVisible = @{} # hwnd -> was it visible on the previous poll (Outlook dismiss-detection)
$script:DismissedWindows = New-Object 'System.Collections.Generic.HashSet[IntPtr]' # Outlook singleton popups the user closed - never re-show
$script:ActiveWorkspace = 1
$script:WorkspaceMasterRatio = @{} # "workspace|MonitorKey" -> master ratio override, falls back to Config.MasterRatio
$script:LastMousePos = $null # last-seen cursor position, so focus-follows-mouse only reacts to actual movement
$script:LastScreenSignature = $null # last-seen display topology, for change detection in Test-DisplayTopologyChanged
$script:TrayIconHandle = [IntPtr]::Zero # native HICON backing the tray workspace badge
$script:StatusBarForm = $null   # top-of-screen form listing apps per workspace
$script:StatusBarLabels = @{}   # workspace number -> Label control inside the status bar
$script:StatusBarColors = @{}   # parsed Color objects, populated by Initialize-StatusBar
$script:StatusBarFlow = $null   # FlowLayoutPanel holding the workspace labels, repositioned for alignment
$script:StatusBarClockLabel = $null   # top-of-screen clock label (only when HideTaskbar + StatusBarShowClock)
$script:StatusBarBatteryLabel = $null # top-of-screen battery % label (only when a battery is present)
$script:PowerMenuForm = $null   # separate interactive form for the top-left power button
$script:PowerMenu = $null
$script:PowerMenuButton = $null
$script:PowerMenuDismissTimer = $null

# ---------------------------------------------------------------------------
# Window filtering
# ---------------------------------------------------------------------------

function Test-ManageableWindow {
    # $ProcCache is an optional pid -> process-name lookup reused across every window checked
    # within a single Update-WindowSets pass, so multi-window apps (browsers, Explorer, etc.)
    # only cost one Get-Process call per poll instead of one per window.
    param([IntPtr]$Hwnd, [hashtable]$ProcCache)

    if ($Hwnd -eq $script:HotKeyWindowHandle) { return $false }
    if ($script:FloatingWindows.Contains($Hwnd)) { return $false }
    if (-not [Win32]::IsWindowVisible($Hwnd)) { return $false }
    if ([Win32]::IsIconic($Hwnd)) { return $false }
    if ([Win32]::GetWindowTextLength($Hwnd) -eq 0) { return $false }
    if ([Win32]::GetWindow($Hwnd, 4) -ne [IntPtr]::Zero) { return $false } # GW_OWNER

    $exStyle = [Win32]::GetWindowLong($Hwnd, -20) # GWL_EXSTYLE
    $isToolWindow = ($exStyle -band 0x00000080) -ne 0 # WS_EX_TOOLWINDOW
    $isAppWindow = ($exStyle -band 0x00040000) -ne 0  # WS_EX_APPWINDOW
    if ($isToolWindow -and -not $isAppWindow) { return $false }

    $cloaked = 0
    [Win32]::DwmGetWindowAttribute($Hwnd, 14, [ref]$cloaked, 4) | Out-Null # DWMWA_CLOAKED
    if ($cloaked -ne 0) { return $false }

    $className = [Win32]::GetClass($Hwnd)
    if ($script:Config.ExcludedClasses -contains $className) { return $false }

    $procId = 0
    [Win32]::GetWindowThreadProcessId($Hwnd, [ref]$procId) | Out-Null
    if ($ProcCache -and $ProcCache.ContainsKey($procId)) {
        $procName = $ProcCache[$procId]
    } else {
        try {
            $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName
        } catch {
            $procName = $null
        }
        if ($ProcCache) { $ProcCache[$procId] = $procName }
    }
    if ($procName -and ($script:Config.ExcludedProcesses -contains $procName)) { return $false }

    return $true
}

function Test-AlwaysVisibleWindow {
    # Chat/calling apps (Teams, Slack, Zoom, Discord...) commonly reuse one hidden hwnd for
    # their incoming-call/notification popup across the app's whole lifetime instead of
    # creating a fresh one each time - once that hwnd gets tracked to whatever workspace
    # happened to be active the first time it appeared, every later poll would just hide it
    # again if a different workspace is active, silently swallowing the alert (missed calls).
    # WS_EX_TOPMOST is the vendor-agnostic signal these always use for exactly this kind of
    # transient always-on-top alert, so it's treated as "never hide this for a workspace
    # switch" by default; AlwaysVisibleProcesses/AlwaysVisibleClasses cover anything that
    # doesn't set it.
    param([IntPtr]$Hwnd, [hashtable]$ProcCache)

    $exStyle = [Win32]::GetWindowLong($Hwnd, -20) # GWL_EXSTYLE
    if (($exStyle -band 0x00000008) -ne 0) { return $true } # WS_EX_TOPMOST

    if ($script:Config.AlwaysVisibleClasses -and $script:Config.AlwaysVisibleClasses.Count -gt 0) {
        if ($script:Config.AlwaysVisibleClasses -contains [Win32]::GetClass($Hwnd)) { return $true }
    }
    if ($script:Config.AlwaysVisibleProcesses -and $script:Config.AlwaysVisibleProcesses.Count -gt 0) {
        $procId = 0
        [Win32]::GetWindowThreadProcessId($Hwnd, [ref]$procId) | Out-Null
        if ($ProcCache -and $ProcCache.ContainsKey($procId)) {
            $procName = $ProcCache[$procId]
        } else {
            try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $procName = $null }
            if ($ProcCache) { $ProcCache[$procId] = $procName }
        }
        if ($procName -and ($script:Config.AlwaysVisibleProcesses -contains $procName)) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Diagnostics - geometry/state dumps for after-the-fact debugging of layout bugs
# ("only half my screen is usable", windows tiled off-screen, a monitor vanishing)
# ---------------------------------------------------------------------------

function Get-ScreenSignature {
    # Compact, comparable description of the current display topology.
    $parts = foreach ($s in [System.Windows.Forms.Screen]::AllScreens) {
        $b = $s.Bounds; $w = $s.WorkingArea
        "$($s.DeviceName)$(if ($s.Primary) { '*' })|B:$($b.X),$($b.Y),$($b.Width)x$($b.Height)|W:$($w.X),$($w.Y),$($w.Width)x$($w.Height)"
    }
    ($parts -join ' ; ')
}

function Get-WindowDescription {
    param([IntPtr]$Hwnd)
    $procId = 0
    [Win32]::GetWindowThreadProcessId($Hwnd, [ref]$procId) | Out-Null
    try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $procName = '?' }
    "hwnd=$Hwnd proc=$procName class=$([Win32]::GetClass($Hwnd)) title='$([Win32]::GetTitle($Hwnd))' rect=$([Win32]::GetRectString($Hwnd))"
}

function Write-DiagnosticSnapshot {
    param([string]$Reason = 'manual')
    try {
        Write-Log "--- DIAGNOSTIC SNAPSHOT ($Reason) ---" -Level Info
        Write-Log "screens: $(Get-ScreenSignature)" -Level Info
        $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
        Write-Log "virtualScreen=$($vs.X),$($vs.Y) $($vs.Width)x$($vs.Height)" -Level Info
        Write-Log "activeWorkspace=$($script:ActiveWorkspace) gap=$($script:Config.Gap) masterRatio=$($script:Config.MasterRatio) hideTaskbar=$($script:Config.HideTaskbar) statusBar=$($script:Config.ShowStatusBar)/$($script:Config.StatusBarHeight)" -Level Info
        $ratios = ($script:WorkspaceMasterRatio.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ', '
        Write-Log "workspaceMasterRatio: $ratios" -Level Info
        # A taskbar/AppBar that's grown to an unexpected size is itself a way to lose usable screen.
        foreach ($hwnd in [Win32]::GetTopLevelWindows()) {
            $class = [Win32]::GetClass($hwnd)
            if ($class -eq 'Shell_TrayWnd' -or $class -eq 'Shell_SecondaryTrayWnd') {
                Write-Log "taskbar $class visible=$([Win32]::IsWindowVisible($hwnd)) rect=$([Win32]::GetRectString($hwnd))" -Level Info
            }
        }
        Write-Log "foreground: $(Get-WindowDescription -Hwnd ([Win32]::GetForegroundWindow()))" -Level Info
        foreach ($key in $script:ManagedWindows.Keys) {
            $list = $script:ManagedWindows[$key]
            Write-Log "monitor '$key': $($list.Count) tiled window(s)" -Level Info
            for ($i = 0; $i -lt $list.Count; $i++) {
                Write-Log "  [$i]$(if ($i -eq 0) { ' master' } else { ' stack ' }) $(Get-WindowDescription -Hwnd $list[$i])" -Level Info
            }
        }
        if ($script:FloatingWindows.Count -gt 0) {
            Write-Log "floating: $($script:FloatingWindows.Count) window(s)" -Level Info
            foreach ($hwnd in $script:FloatingWindows) { Write-Log "  $(Get-WindowDescription -Hwnd $hwnd)" -Level Info }
        }
        Write-Log "--- END SNAPSHOT ---" -Level Info
    } catch { Write-Log "Write-DiagnosticSnapshot failed: $_" }
}

function Test-DisplayTopologyChanged {
    # Cheap per-poll guard: catches monitor add/remove/resolution/DPI/taskbar-size changes
    # even when the WM_DISPLAYCHANGE-driven event below doesn't fire (RDP, dock/undock).
    $sig = Get-ScreenSignature
    if ($script:LastScreenSignature -and $script:LastScreenSignature -ne $sig) {
        Write-Log "Display topology changed:" -Level Info
        Write-Log "  was: $($script:LastScreenSignature)" -Level Info
        Write-Log "  now: $sig" -Level Info
        $script:LastScreenSignature = $sig
        return $true
    }
    $script:LastScreenSignature = $sig
    return $false
}

# ---------------------------------------------------------------------------
# Layout engine (master-stack, per monitor)
# ---------------------------------------------------------------------------

function Set-TiledWindowPos {
    # Single choke point for every tile placement so each one is logged, Win32 failures
    # surface with a real error code, and windows that silently refuse the requested size
    # (the usual cause of "half my screen is unusable") get called out by name.
    param([IntPtr]$Hwnd, [string]$Role, [int]$X, [int]$Y, [int]$Width, [int]$Height, [uint32]$Flags)

    if ($Width -le 0 -or $Height -le 0) {
        Write-Log "Refusing degenerate tile for $Role - computed ${Width}x${Height} at $X,$Y. $(Get-WindowDescription -Hwnd $Hwnd)"
        return
    }
    $before = [Win32]::GetRectString($Hwnd)
    # A maximized window ignores SetWindowPos sizing and stays full-screen (Edge reopens
    # maximized, for example), so restore it first - without activating it.
    if ([Win32]::IsZoomed($Hwnd)) {
        Write-Log "Restoring maximized window before tiling ($Role). $(Get-WindowDescription -Hwnd $Hwnd)" -Level Debug
        [Win32]::ShowWindow($Hwnd, 4) | Out-Null # SW_SHOWNOACTIVATE
    }
    $err = [Win32]::SetWindowPosEx($Hwnd, $X, $Y, $Width, $Height, $Flags)
    if ($err -ne 0) {
        Write-Log "SetWindowPos failed (win32 error $err) for $Role -> $X,$Y ${Width}x${Height}. $(Get-WindowDescription -Hwnd $Hwnd)"
        return
    }
    $r = New-Object 'Win32+RECT'
    if (-not [Win32]::GetWindowRect($Hwnd, [ref]$r)) { return }
    $actualW = $r.Right - $r.Left
    $actualH = $r.Bottom - $r.Top
    # Tolerance covers invisible DWM shadow borders and apps with a minimum size / step sizing.
    $tolerance = 24
    if ([Math]::Abs($actualW - $Width) -gt $tolerance -or [Math]::Abs($actualH - $Height) -gt $tolerance -or
        [Math]::Abs($r.Left - $X) -gt $tolerance -or [Math]::Abs($r.Top - $Y) -gt $tolerance) {
        Write-Log "Window did not accept its tile ($Role): asked $X,$Y ${Width}x${Height}, got $($r.Left),$($r.Top) ${actualW}x${actualH} (was $before, maximized=$([Win32]::IsZoomed($Hwnd)), minimized=$([Win32]::IsIconic($Hwnd))). $(Get-WindowDescription -Hwnd $Hwnd)"
    } else {
        Write-Log "tile $Role -> $X,$Y ${Width}x${Height} $(Get-WindowDescription -Hwnd $Hwnd)" -Level Debug
    }
}

function Set-MonitorLayout {
    param([string]$MonitorKey)

    $list = $script:ManagedWindows[$MonitorKey]
    if (-not $list -or $list.Count -eq 0) { return }

    $screen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.DeviceName -eq $MonitorKey } | Select-Object -First 1
    if (-not $screen) {
        # Windows enumerated this monitor when the windows were assigned to it, and doesn't now -
        # every window tracked here is about to be left un-tiled wherever it happens to sit.
        Write-Log "Cannot lay out monitor '$MonitorKey' - no matching screen. $($list.Count) window(s) left untiled. Screens now: $(Get-ScreenSignature)"
        return
    }

    # With the taskbar hidden, Windows never updates the reported working area (we hide it
    # ourselves rather than toggling the OS auto-hide setting), so use the full monitor
    # bounds instead of leaving a permanent dead gap where the taskbar used to be.
    $wa = if ($script:Config.HideTaskbar) { $screen.Bounds } else { $screen.WorkingArea }
    if ($script:Config.ShowStatusBar -and $screen.Primary) {
        # Reserve space at the top for the workspace status bar (it isn't a real
        # AppBar, so nothing else shrinks the reported working area for us).
        $barHeight = [int]$script:Config.StatusBarHeight
        $wa = [System.Drawing.Rectangle]::new($wa.X, $wa.Y + $barHeight, $wa.Width, $wa.Height - $barHeight)
    }
    # A working area much smaller than the monitor it belongs to means something external
    # reserved that space (a rogue AppBar, a stuck full-screen-sized taskbar, a stale
    # pre-resolution-change working area) - that shows up as "I can only use part of my
    # screen" with no error anywhere, so make it loud and record both rectangles.
    if ($wa.Width -lt ($screen.Bounds.Width * 0.9) -or $wa.Height -lt ($screen.Bounds.Height * 0.75)) {
        Write-Log "Usable area on '$MonitorKey' is much smaller than the monitor: tiling into $($wa.X),$($wa.Y) $($wa.Width)x$($wa.Height) of bounds $($screen.Bounds.X),$($screen.Bounds.Y) $($screen.Bounds.Width)x$($screen.Bounds.Height) (workingArea=$($screen.WorkingArea.X),$($screen.WorkingArea.Y) $($screen.WorkingArea.Width)x$($screen.WorkingArea.Height), hideTaskbar=$($script:Config.HideTaskbar), statusBarHeight=$($script:Config.StatusBarHeight))"
    }

    $g = [int]$script:Config.Gap
    $ratioKey = "$($script:ActiveWorkspace)|$MonitorKey"
    $ratio = if ($script:WorkspaceMasterRatio.ContainsKey($ratioKey)) { [double]$script:WorkspaceMasterRatio[$ratioKey] } else { [double]$script:Config.MasterRatio }
    $flags = 0x0004 -bor 0x0010 # SWP_NOZORDER | SWP_NOACTIVATE
    Write-Log "layout '$MonitorKey': $($list.Count) window(s), area $($wa.X),$($wa.Y) $($wa.Width)x$($wa.Height), gap=$g, ratio=$ratio (key '$ratioKey'), workspace=$($script:ActiveWorkspace)" -Level Debug

    if ($list.Count -eq 1) {
        Set-TiledWindowPos -Hwnd $list[0] -Role 'only' -X ($wa.X + $g) -Y ($wa.Y + $g) -Width ($wa.Width - (2 * $g)) -Height ($wa.Height - (2 * $g)) -Flags $flags
        return
    }

    $availableWidth = $wa.Width - (3 * $g)
    $masterWidth = [int]($availableWidth * $ratio)
    $stackWidth = $availableWidth - $masterWidth
    $masterX = $wa.X + $g
    $masterY = $wa.Y + $g
    $masterHeight = $wa.Height - (2 * $g)
    Set-TiledWindowPos -Hwnd $list[0] -Role 'master' -X $masterX -Y $masterY -Width $masterWidth -Height $masterHeight -Flags $flags

    $stackX = $masterX + $masterWidth + $g
    $stackCount = $list.Count - 1
    $stackTotalHeight = $wa.Height - (2 * $g) - (($stackCount - 1) * $g)
    $eachHeight = [int]($stackTotalHeight / $stackCount)
    $y = $wa.Y + $g

    for ($i = 1; $i -lt $list.Count; $i++) {
        Set-TiledWindowPos -Hwnd $list[$i] -Role "stack$i" -X $stackX -Y $y -Width $stackWidth -Height $eachHeight -Flags $flags
        $y += $eachHeight + $g
    }
}

function Update-WindowSets {
    param([switch]$Force)

    # A resolution/monitor/DPI change silently invalidates every cached tile - log it (so a
    # later "half my screen" report can be lined up against it) and force a full relayout.
    if (Test-DisplayTopologyChanged) {
        Write-DiagnosticSnapshot -Reason 'display topology changed'
        $Force = [switch]$true
    }

    $allHwnds = [Win32]::GetTopLevelWindows()
    $byMonitor = @{}
    $procNameCache = @{} # pid -> process name, scoped to this single pass - see Test-ManageableWindow

    foreach ($hwnd in $allHwnds) {
        if ($hwnd -eq $script:HotKeyWindowHandle) { continue }
        # Outlook (classic) sometimes leaves behind a blank/titleless top-level frame - its
        # rctrl_renwnd32 window class is reused by both the Explorer and Inspector windows - after
        # a window is closed. Since it has no title, it would otherwise fall through the checks
        # below untracked: never assigned to a workspace, so workspace switches never hide it, and
        # it just sits there as a permanent "ghost" no matter how many times it's closed. Suppress
        # it outright instead.
        if ([Win32]::IsWindowVisible($hwnd) -and [Win32]::GetWindowTextLength($hwnd) -eq 0 -and [Win32]::GetClass($hwnd) -eq 'rctrl_renwnd32') {
            [Win32]::ShowWindow($hwnd, 0) | Out-Null # SW_HIDE
            continue
        }
        # Outlook's reminder dialog (#32770) and Inspector windows (rctrl_renwnd32 - a compose
        # or read window) are singleton-ish: Outlook just hides the hwnd instead of destroying it
        # when the user dismisses/closes it. Without this, Switch-Workspace's own "show windows
        # tagged to this workspace" logic re-shows that very same hwnd next time the user returns
        # to this workspace, making a dismissed reminder/compose window look like it "reopens
        # itself". Detect the visible -> hidden transition happening on its own (i.e. not because
        # *we* just hid it for an outgoing workspace) and stop showing that window for good.
        $isOutlookSingleton = @('#32770', 'rctrl_renwnd32') -contains [Win32]::GetClass($hwnd)
        if ($isOutlookSingleton -and $script:WindowWorkspace.ContainsKey($hwnd) -and $script:WindowWorkspace[$hwnd] -eq $script:ActiveWorkspace) {
            $procId = 0
            [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
            $isOutlookProc = $false
            try { $isOutlookProc = (Get-Process -Id $procId -ErrorAction Stop).ProcessName -eq 'OUTLOOK' } catch { }
            $visibleNow = [Win32]::IsWindowVisible($hwnd)
            if ($isOutlookProc -and $script:LastWindowVisible.ContainsKey($hwnd) -and $script:LastWindowVisible[$hwnd] -and -not $visibleNow) {
                [void]$script:DismissedWindows.Add($hwnd)
            }
            $script:LastWindowVisible[$hwnd] = $visibleNow
        }
        if ($script:DismissedWindows.Contains($hwnd)) {
            if ([Win32]::IsWindowVisible($hwnd)) { [Win32]::ShowWindow($hwnd, 0) | Out-Null } # SW_HIDE
            continue
        }
        # Track workspace membership for any real window, even ones excluded from tiling
        # (floating/other-workspace), so hide/show on workspace switch still works for them.
        if (-not $script:WindowWorkspace.ContainsKey($hwnd) -and [Win32]::IsWindowVisible($hwnd) -and [Win32]::GetWindowTextLength($hwnd) -gt 0) {
            $script:WindowWorkspace[$hwnd] = $script:ActiveWorkspace
        }
        # Some apps (e.g. Outlook reminder popups) re-show their own window on a timer,
        # bypassing the one-time hide from Switch-Workspace - re-suppress it every poll.
        # Exception: always-visible windows (WS_EX_TOPMOST alerts, or an AlwaysVisible*
        # config match) are left alone here - an app choosing to show one of these while
        # a different workspace is active is exactly the "incoming call" case that should
        # stay on screen rather than get silently hidden again.
        if ($script:WindowWorkspace.ContainsKey($hwnd) -and $script:WindowWorkspace[$hwnd] -ne $script:ActiveWorkspace) {
            if (Test-AlwaysVisibleWindow -Hwnd $hwnd -ProcCache $procNameCache) { continue }
            if ([Win32]::IsWindowVisible($hwnd)) { [Win32]::ShowWindow($hwnd, 0) | Out-Null } # SW_HIDE
            continue
        }
        if (-not (Test-ManageableWindow -Hwnd $hwnd -ProcCache $procNameCache)) { continue }
        $screen = [System.Windows.Forms.Screen]::FromHandle($hwnd)
        $key = $screen.DeviceName
        if (-not $byMonitor.ContainsKey($key)) { $byMonitor[$key] = New-Object 'System.Collections.Generic.List[IntPtr]' }
        $byMonitor[$key].Add($hwnd)
    }

    foreach ($hwnd in @($script:WindowWorkspace.Keys)) {
        if ($allHwnds -notcontains $hwnd) { $script:WindowWorkspace.Remove($hwnd) }
    }
    # Purge bookkeeping for any hwnd that's been fully destroyed, not just hidden, so a genuinely
    # new window (a fresh Outlook reminder/compose instance reusing a recycled-looking title) isn't
    # mistaken for one already marked dismissed, and these dictionaries don't grow unbounded.
    foreach ($hwnd in @($script:LastWindowVisible.Keys)) {
        if ($allHwnds -notcontains $hwnd) { $script:LastWindowVisible.Remove($hwnd) }
    }
    foreach ($hwnd in @($script:DismissedWindows)) {
        if ($allHwnds -notcontains $hwnd) { [void]$script:DismissedWindows.Remove($hwnd) }
    }

    $changed = $Force.IsPresent

    foreach ($key in $byMonitor.Keys) {
        $current = $byMonitor[$key]
        if (-not $script:ManagedWindows.ContainsKey($key)) {
            $script:ManagedWindows[$key] = New-Object 'System.Collections.Generic.List[IntPtr]'
        }
        $existing = $script:ManagedWindows[$key]

        for ($i = $existing.Count - 1; $i -ge 0; $i--) {
            if (-not $current.Contains($existing[$i])) {
                $existing.RemoveAt($i)
                $changed = $true
            }
        }
        foreach ($hwnd in $current) {
            if (-not $existing.Contains($hwnd)) {
                Write-Verbose "Managing window: '$([Win32]::GetTitle($hwnd))'"
                $existing.Add($hwnd)
                $changed = $true
            }
        }
    }

    foreach ($key in @($script:ManagedWindows.Keys)) {
        if (-not $byMonitor.ContainsKey($key)) {
            if ($script:ManagedWindows[$key].Count -gt 0) { $changed = $true }
            $script:ManagedWindows.Remove($key)
        }
    }

    if ($changed) {
        foreach ($key in $script:ManagedWindows.Keys) {
            Set-MonitorLayout -MonitorKey $key
        }
    }
}

# ---------------------------------------------------------------------------
# Focus / layout actions (bound to hotkeys)
# ---------------------------------------------------------------------------

function Get-FocusedManagedWindow {
    $fg = [Win32]::GetForegroundWindow()
    foreach ($key in $script:ManagedWindows.Keys) {
        $list = $script:ManagedWindows[$key]
        $idx = $list.IndexOf($fg)
        if ($idx -ge 0) {
            return [PSCustomObject]@{ MonitorKey = $key; Index = $idx; Hwnd = $fg; List = $list }
        }
    }
    return $null
}

function Invoke-FocusFollowsMouseTick {
    # Skip while the app launcher is focused - otherwise nudging the mouse over a tiled window
    # steals focus back to it, which makes the launcher hide itself (it closes on deactivate).
    if (Test-AppLauncherForeground) { return }
    $pos = [System.Windows.Forms.Cursor]::Position
    # Without this, a stationary cursor resting over some other tiled window (top-right
    # corner, wherever) would still re-force focus to it every single tick, fighting any
    # focus change made another way (a hotkey, Alt-Tab, clicking a taskbar entry) within
    # 100ms of it happening - this is what "the top right of the screen unfocuses my
    # window" actually was: it wasn't specific to that corner, just wherever the mouse
    # happened to be idling. Only act when the cursor has actually moved since last tick.
    if ($script:LastMousePos -and $pos.X -eq $script:LastMousePos.X -and $pos.Y -eq $script:LastMousePos.Y) { return }
    $script:LastMousePos = $pos
    $hwnd = [Win32]::GetTopLevelWindowAtCursor()
    if ($hwnd -eq [IntPtr]::Zero) { return }
    if ($hwnd -eq [Win32]::GetForegroundWindow()) { return }
    # Only steal focus for windows we're actually tiling, so hovering the
    # taskbar/tray/desktop/floating windows can't yank focus unexpectedly.
    foreach ($list in $script:ManagedWindows.Values) {
        if ($list.Contains($hwnd)) {
            # Plain SetForegroundWindow from this background timer almost always just flashes
            # the taskbar entry instead of actually focusing anything - Windows only grants
            # foreground to a process that itself "generated" the last input event, and polling
            # GetCursorPos doesn't count. ForceForegroundWindow works around that.
            [Win32]::ForceForegroundWindow($hwnd)
            return
        }
    }
}

function Invoke-FocusDirection {
    # Vim-style spatial focus: master column is "left", stack column is "right",
    # Up/Down cycle (with wraparound) among the stacked windows only.
    param([ValidateSet('Left', 'Right', 'Up', 'Down')][string]$Direction)
    $focused = Get-FocusedManagedWindow
    if (-not $focused) {
        $any = $script:ManagedWindows.Values | Where-Object { $_.Count -gt 0 } | Select-Object -First 1
        if ($any) { [Win32]::SetForegroundWindow($any[0]) | Out-Null }
        return
    }
    $list = $focused.List
    $count = $list.Count
    if ($count -le 1) { return }

    switch ($Direction) {
        'Left' {
            if ($focused.Index -ne 0) { [Win32]::SetForegroundWindow($list[0]) | Out-Null }
        }
        'Right' {
            if ($focused.Index -eq 0) { [Win32]::SetForegroundWindow($list[1]) | Out-Null }
        }
        'Up' {
            if ($focused.Index -gt 1) {
                [Win32]::SetForegroundWindow($list[$focused.Index - 1]) | Out-Null
            } elseif ($focused.Index -eq 1 -and $count -gt 2) {
                [Win32]::SetForegroundWindow($list[$count - 1]) | Out-Null
            }
        }
        'Down' {
            if ($focused.Index -ge 1 -and $focused.Index -lt $count - 1) {
                [Win32]::SetForegroundWindow($list[$focused.Index + 1]) | Out-Null
            } elseif ($focused.Index -eq $count - 1 -and $count -gt 2) {
                [Win32]::SetForegroundWindow($list[1]) | Out-Null
            }
        }
    }
}

function Invoke-SwapMaster {
    $focused = Get-FocusedManagedWindow
    if (-not $focused -or $focused.List.Count -lt 2) { return }
    $list = $focused.List
    $swapIndex = if ($focused.Index -eq 0) { 1 } else { $focused.Index }
    $tmp = $list[0]; $list[0] = $list[$swapIndex]; $list[$swapIndex] = $tmp
    Set-MonitorLayout -MonitorKey $focused.MonitorKey
    [Win32]::SetForegroundWindow($focused.Hwnd) | Out-Null
}

function Invoke-MoveInStack {
    param([int]$Direction)
    $focused = Get-FocusedManagedWindow
    if (-not $focused -or $focused.List.Count -lt 2) { return }
    $list = $focused.List
    $count = $list.Count
    $newIndex = (($focused.Index + $Direction) % $count + $count) % $count
    $tmp = $list[$focused.Index]; $list[$focused.Index] = $list[$newIndex]; $list[$newIndex] = $tmp
    Set-MonitorLayout -MonitorKey $focused.MonitorKey
    [Win32]::SetForegroundWindow($focused.Hwnd) | Out-Null
}

function Invoke-MoveToMaster {
    # Vim-style spatial move: send the focused stack window to the master column.
    $focused = Get-FocusedManagedWindow
    if (-not $focused -or $focused.List.Count -lt 2 -or $focused.Index -eq 0) { return }
    $list = $focused.List
    $tmp = $list[0]; $list[0] = $list[$focused.Index]; $list[$focused.Index] = $tmp
    Set-MonitorLayout -MonitorKey $focused.MonitorKey
    [Win32]::SetForegroundWindow($focused.Hwnd) | Out-Null
}

function Invoke-MoveToStack {
    # Vim-style spatial move: send the focused master window into the stack column.
    $focused = Get-FocusedManagedWindow
    if (-not $focused -or $focused.List.Count -lt 2 -or $focused.Index -ne 0) { return }
    $list = $focused.List
    $tmp = $list[0]; $list[0] = $list[1]; $list[1] = $tmp
    Set-MonitorLayout -MonitorKey $focused.MonitorKey
    [Win32]::SetForegroundWindow($focused.Hwnd) | Out-Null
}

function Invoke-ResizeMaster {
    # Adjusts the master ratio for the active workspace only, so other workspaces keep their own widths.
    param([double]$Delta)
    foreach ($key in $script:ManagedWindows.Keys) {
        $ratioKey = "$($script:ActiveWorkspace)|$key"
        $current = if ($script:WorkspaceMasterRatio.ContainsKey($ratioKey)) { [double]$script:WorkspaceMasterRatio[$ratioKey] } else { [double]$script:Config.MasterRatio }
        $script:WorkspaceMasterRatio[$ratioKey] = [Math]::Min(0.9, [Math]::Max(0.1, $current + $Delta))
        Write-Log "Master ratio for '$ratioKey': $current -> $($script:WorkspaceMasterRatio[$ratioKey])" -Level Info
        Set-MonitorLayout -MonitorKey $key
    }
}

function Invoke-CloseFocusedWindow {
    $fg = [Win32]::GetForegroundWindow()
    if ($fg -ne [IntPtr]::Zero) {
        [Win32]::PostMessage($fg, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null # WM_CLOSE
    }
}

function Invoke-ToggleFloating {
    $fg = [Win32]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero) { return }
    if ($script:FloatingWindows.Contains($fg)) {
        [void]$script:FloatingWindows.Remove($fg)
    } else {
        [void]$script:FloatingWindows.Add($fg)
        foreach ($key in @($script:ManagedWindows.Keys)) {
            [void]$script:ManagedWindows[$key].Remove($fg)
        }
    }
    Update-WindowSets -Force
}

function Invoke-BringFloatingToFront {
    # Floating windows keep whatever z-order they last had (tiled windows are repositioned
    # with SWP_NOZORDER so they never disturb it), so a floating window can end up buried
    # behind tiled ones after a focus change elsewhere. Raise every floating window tracked
    # on the active workspace back above everything else, without stealing focus.
    $flags = 0x0001 -bor 0x0002 -bor 0x0010 # SWP_NOSIZE | SWP_NOMOVE | SWP_NOACTIVATE
    $topHwnd = [IntPtr]::Zero
    foreach ($hwnd in $script:FloatingWindows) {
        if (-not [Win32]::IsWindowVisible($hwnd)) { continue }
        if ($script:WindowWorkspace.ContainsKey($hwnd) -and $script:WindowWorkspace[$hwnd] -ne $script:ActiveWorkspace) { continue }
        [Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, 0, 0, 0, 0, $flags) | Out-Null # HWND_TOP
        $topHwnd = $hwnd
    }
    if ($topHwnd -ne [IntPtr]::Zero) { [Win32]::SetForegroundWindow($topHwnd) | Out-Null }
}

function Invoke-Quit {
    [System.Windows.Forms.Application]::Exit()
}

function Invoke-Restart {
    # Relaunches a fresh instance of this same script (picking up any edits to it or to
    # TilingWM.config.psd1) and exits this one.
    Write-Log "Restarting..." -Level Info
    try {
        $exePath = (Get-Process -Id $PID).Path
        Start-Process -FilePath $exePath -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    } catch {
        Write-Log "Failed to relaunch for restart: $_"
        return
    }
    Invoke-Quit
}

function Set-TaskbarVisible {
    # Hides/restores the taskbar by toggling its top-level windows directly (Shell_TrayWnd
    # plus one Shell_SecondaryTrayWnd per extra monitor) rather than touching the OS
    # auto-hide setting, so it's cheap to guarantee restoration on exit even after a crash.
    param([bool]$Visible)
    $cmd = if ($Visible) { 5 } else { 0 } # SW_SHOW | SW_HIDE
    foreach ($hwnd in [Win32]::GetTopLevelWindows()) {
        $class = [Win32]::GetClass($hwnd)
        if ($class -eq 'Shell_TrayWnd' -or $class -eq 'Shell_SecondaryTrayWnd') {
            [Win32]::ShowWindow($hwnd, $cmd) | Out-Null
        }
    }
}

function Invoke-LaunchApp {
    param([string]$Name)
    $entry = $script:Config.AppShortcuts[$Name]
    if (-not $entry -or -not $entry.Path) { return }
    try {
        if ($entry.Arguments) {
            Start-Process -FilePath $entry.Path -ArgumentList $entry.Arguments
        } else {
            Start-Process -FilePath $entry.Path
        }
    } catch {
        Write-Log "Failed to launch app shortcut '$Name' ($($entry.Path)): $_"
    }
}

# ---------------------------------------------------------------------------
# App launcher - runs as its own process (AppLauncher.ps1) that owns its hotkey and
# window, so it can take focus reliably and never blocks (or is blocked by) tiling.
# ---------------------------------------------------------------------------

$script:AppLauncherWindowTitle = 'power-tile launcher' # must match AppLauncher.ps1
$script:AppLauncherProcess = $null

function Start-AppLauncher {
    $launcherPath = Join-Path $PSScriptRoot 'AppLauncher.ps1'
    if (-not (Test-Path -LiteralPath $launcherPath)) {
        Write-Log "App launcher script not found at '$launcherPath' - launcher disabled."
        return
    }
    try {
        $exePath = (Get-Process -Id $PID).Path
        $script:AppLauncherProcess = Start-Process -FilePath $exePath -WindowStyle Hidden -PassThru -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`" -ParentPid $PID"
        Write-Log "App launcher started (pid $($script:AppLauncherProcess.Id))." -Level Info
    } catch {
        Write-Log "Failed to start app launcher: $_"
    }
}

function Stop-AppLauncher {
    if (-not $script:AppLauncherProcess) { return }
    try {
        if (-not $script:AppLauncherProcess.HasExited) { Stop-Process -Id $script:AppLauncherProcess.Id -Force -ErrorAction Stop }
    } catch { Write-Log "Failed to stop app launcher: $_" }
    $script:AppLauncherProcess = $null
}

function Test-AppLauncherForeground {
    $fg = [Win32]::GetForegroundWindow()
    return $fg -ne [IntPtr]::Zero -and [Win32]::GetTitle($fg) -eq $script:AppLauncherWindowTitle
}

# ---------------------------------------------------------------------------
# Status bar (top-of-screen workspace/app indicator)
# ---------------------------------------------------------------------------

function ConvertTo-BarColor {
    param([string]$Spec, [System.Drawing.Color]$Default)
    if (-not $Spec) { return $Default }
    try { return [System.Drawing.ColorTranslator]::FromHtml($Spec) } catch {
        Write-Log "Invalid status bar color '$Spec', using default."
        return $Default
    }
}

function Initialize-PowerMenu {
    param([System.Windows.Forms.Screen]$Screen, [int]$Height)

    $buttonSize = $Height
    $buttonX = $Screen.Bounds.X
    $buttonY = $Screen.Bounds.Y

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.BackColor = $script:StatusBarColors.Busy
    $form.MinimumSize = [System.Drawing.Size]::new($buttonSize, $buttonSize)
    $form.MaximumSize = [System.Drawing.Size]::new($buttonSize, $buttonSize)
    $form.Bounds = [System.Drawing.Rectangle]::new($buttonX, $buttonY, $buttonSize, $buttonSize)

    $button = New-Object System.Windows.Forms.Button
    $button.Dock = 'Fill'
    $button.FlatStyle = 'Flat'
    $button.FlatAppearance.BorderSize = 0
    $button.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI Symbol', 11
    $button.ForeColor = $script:StatusBarColors.Text
    $button.BackColor = $script:StatusBarColors.Busy
    $button.Text = [char]0x23FB
    $button.Padding = [System.Windows.Forms.Padding]::Empty
    $button.TabStop = $false
    $form.Controls.Add($button)

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $menu.BackColor = $script:StatusBarColors.Busy
    $menu.ForeColor = $script:StatusBarColors.Text
    $menu.AutoClose = $true
    $menu.ShowImageMargin = $false
    $menu.ShowCheckMargin = $false
    [void]$menu.Items.Add('Lock', $null, {
        try { Start-Process -FilePath 'rundll32.exe' -ArgumentList 'user32.dll,LockWorkStation' } catch { Write-Log "Lock failed: $_" }
    })
    [void]$menu.Items.Add('Sleep', $null, {
        try { [System.Windows.Forms.Application]::SetSuspendState('Suspend', $false, $false) | Out-Null } catch { Write-Log "Sleep failed: $_" }
    })
    [void]$menu.Items.Add('Restart computer', $null, {
        try { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/r /t 0' } catch { Write-Log "Computer restart failed: $_" }
    })
    [void]$menu.Items.Add('Shut down', $null, {
        try { Start-Process -FilePath 'shutdown.exe' -ArgumentList '/s /t 0' } catch { Write-Log "Shut down failed: $_" }
    })
    [void]$menu.Items.Add('-')
    [void]$menu.Items.Add('Exit power-tile', $null, {
        try { Invoke-Quit } catch { Write-Log "Exit failed: $_" }
    })

    $button.add_Click({
        try {
            $script:PowerMenu.Show($script:PowerMenuButton, [System.Drawing.Point]::new(0, $script:PowerMenuButton.Height))
        } catch { Write-Log "Power menu failed: $_" }
    })

    $dismissTimer = New-Object System.Windows.Forms.Timer
    $dismissTimer.Interval = 50
    $dismissTimer.add_Tick({
        try {
            if (-not $script:PowerMenu.Visible) { return }
            $clicked = $false
            foreach ($virtualKey in @(0x01, 0x02, 0x04)) {
                $mouseState = [Win32]::GetAsyncKeyState($virtualKey)
                if ($mouseState -lt 0 -or ($mouseState -band 1) -ne 0) { $clicked = $true; break }
            }
            if (-not $clicked) { return }

            $cursor = [System.Windows.Forms.Cursor]::Position
            $buttonOrigin = $script:PowerMenuButton.PointToScreen([System.Drawing.Point]::Empty)
            $buttonBounds = [System.Drawing.Rectangle]::new($buttonOrigin.X, $buttonOrigin.Y, $script:PowerMenuButton.Width, $script:PowerMenuButton.Height)
            if (-not $script:PowerMenu.Bounds.Contains($cursor) -and -not $buttonBounds.Contains($cursor)) {
                $script:PowerMenu.Close()
            }
        } catch { Write-Log "Power menu dismissal failed: $_" }
    })
    $menu.add_Opened({ try { $script:PowerMenuDismissTimer.Start() } catch { Write-Log "Power menu dismissal timer failed: $_" } })
    $menu.add_Closed({ try { $script:PowerMenuDismissTimer.Stop() } catch { Write-Log "Power menu dismissal timer failed: $_" } })

    [void]$form.Handle
    $exStyle = [Win32]::GetWindowLong($form.Handle, -20)
    $exStyle = $exStyle -bor 0x08000000 -bor 0x00000080 # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW
    [Win32]::SetWindowLong($form.Handle, -20, $exStyle) | Out-Null

    $script:PowerMenuForm = $form
    $script:PowerMenu = $menu
    $script:PowerMenuButton = $button
    $script:PowerMenuDismissTimer = $dismissTimer
    $form.Show()
}

function Initialize-StatusBar {
    $screen = [System.Windows.Forms.Screen]::PrimaryScreen
    $height = [int]$script:Config.StatusBarHeight

    $script:StatusBarColors = @{
        Background = ConvertTo-BarColor $script:Config.StatusBarBackColor ([System.Drawing.Color]::FromArgb(24, 24, 24))
        Active     = ConvertTo-BarColor $script:Config.StatusBarActiveColor ([System.Drawing.Color]::FromArgb(0, 120, 215))
        Busy       = ConvertTo-BarColor $script:Config.StatusBarBusyColor ([System.Drawing.Color]::FromArgb(60, 60, 60))
        Text       = ConvertTo-BarColor $script:Config.StatusBarTextColor ([System.Drawing.Color]::White)
        IdleText   = ConvertTo-BarColor $script:Config.StatusBarIdleTextColor ([System.Drawing.Color]::Gray)
    }
    $bg = $script:StatusBarColors.Background
    # Exact color that Form.TransparencyKey punches a see-through hole for - anything not
    # painted with this color stays opaque/visible.
    $keyColor = [System.Drawing.Color]::FromArgb(255, 1, 2, 3)

    $form = New-Object System.Windows.Forms.Form
    $form.FormBorderStyle = 'None'
    $form.StartPosition = 'Manual'
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.BackColor = $keyColor
    $form.TransparencyKey = $keyColor
    $form.MinimumSize = [System.Drawing.Size]::new($screen.Bounds.Width, $height)
    $form.MaximumSize = [System.Drawing.Size]::new($screen.Bounds.Width, $height)
    $form.Bounds = [System.Drawing.Rectangle]::new($screen.Bounds.X, $screen.Bounds.Y, $screen.Bounds.Width, $height)

    $flow = New-Object System.Windows.Forms.FlowLayoutPanel
    $flow.AutoSize = $true
    $flow.AutoSizeMode = 'GrowAndShrink'
    $flow.FlowDirection = 'LeftToRight'
    $flow.WrapContents = $false
    $flow.BackColor = $keyColor
    $form.Controls.Add($flow)
    $script:StatusBarFlow = $flow

    $script:StatusBarLabels = @{}
    for ($i = 1; $i -le 9; $i++) {
        $label = New-Object System.Windows.Forms.Label
        $label.AutoSize = $true
        $label.Padding = [System.Windows.Forms.Padding]::new(8, 4, 8, 4)
        $label.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $label.ForeColor = $script:StatusBarColors.IdleText
        $label.BackColor = $bg
        $label.Text = "$i"
        $flow.Controls.Add($label)
        $script:StatusBarLabels[$i] = $label
    }

    # Force handle creation so we can mark it non-activating before it's ever shown -
    # otherwise Show() would steal the foreground from whatever the user was using. Also
    # ClickThroughOverlayForm returns HTTRANSPARENT for every hit test, so pointer input reaches
    # the window underneath, including through the visible clock/battery text in the top-right.
    # WS_EX_TRANSPARENT also preserves the intended transparent-overlay paint ordering.
    [void]$form.Handle
    $exStyle = [Win32]::GetWindowLong($form.Handle, -20) # GWL_EXSTYLE
    $exStyle = $exStyle -bor 0x08000000 -bor 0x00000080 -bor 0x00000020  # WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT
    [Win32]::SetWindowLong($form.Handle, -20, $exStyle) | Out-Null

    $script:StatusBarForm = $form

    $script:StatusBarClockLabel = $null
    if ($script:Config.HideTaskbar -and $script:Config.StatusBarShowClock) {
        # Only shown when the taskbar is hidden, since that's what takes away the clock
        # you'd normally get for free - floats directly on the form (no flow panel), so it
        # can sit flush against the right edge regardless of the workspace slots' alignment.
        $clock = New-Object System.Windows.Forms.Label
        $clock.AutoSize = $true
        $clock.Padding = [System.Windows.Forms.Padding]::new(8, 4, 8, 4)
        $clock.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $clock.ForeColor = $script:StatusBarColors.Text
        $clock.BackColor = $script:StatusBarColors.Busy
        $form.Controls.Add($clock)
        $script:StatusBarClockLabel = $clock
    }

    $script:StatusBarBatteryLabel = $null
    if ($script:Config.StatusBarShowBattery -and (Test-HasBattery)) {
        # Unlike the clock, this isn't gated on HideTaskbar - it's useful info the real
        # taskbar doesn't surface either without a click, so show it whenever present.
        $battery = New-Object System.Windows.Forms.Label
        $battery.AutoSize = $true
        $battery.Padding = [System.Windows.Forms.Padding]::new(8, 4, 8, 4)
        $battery.Font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9
        $battery.ForeColor = $script:StatusBarColors.Text
        $battery.BackColor = $script:StatusBarColors.Busy
        $form.Controls.Add($battery)
        $script:StatusBarBatteryLabel = $battery
    }

    Update-StatusBarClock
    Update-StatusBarBattery
    Update-StatusBarRightWidgets
    Initialize-PowerMenu -Screen $screen -Height $height

    $form.Show()
}

function Test-HasBattery {
    try {
        return [System.Windows.Forms.SystemInformation]::PowerStatus.BatteryChargeStatus -ne [System.Windows.Forms.BatteryChargeStatus]::NoSystemBattery
    } catch {
        return $false
    }
}

function Update-StatusBarClock {
    $label = $script:StatusBarClockLabel
    if (-not $label -or $label.IsDisposed) { return }
    $label.Text = Get-Date -Format 'ddd, MMM d  h:mm tt'
}

function Update-StatusBarBattery {
    $label = $script:StatusBarBatteryLabel
    if (-not $label -or $label.IsDisposed) { return }
    try {
        $status = [System.Windows.Forms.SystemInformation]::PowerStatus
        $pct = [Math]::Max(0, [Math]::Min(100, [int][Math]::Round($status.BatteryLifePercent * 100)))
        $charging = $status.PowerLineStatus -eq [System.Windows.Forms.PowerLineStatus]::Online
        $label.Text = if ($charging) { "$pct`%+" } else { "$pct`%" }
    } catch {
        $label.Text = ''
    }
}

function Update-StatusBarRightWidgets {
    # Lays the clock and battery labels out from the right edge of the bar, in that
    # order - both float directly on the form (not the flow panel) so they stay flush
    # right regardless of the workspace slots' own alignment setting.
    $form = $script:StatusBarForm
    if (-not $form -or $form.IsDisposed) { return }
    $x = $form.ClientSize.Width - 12
    foreach ($label in @($script:StatusBarClockLabel, $script:StatusBarBatteryLabel)) {
        if (-not $label -or $label.IsDisposed) { continue }
        $x -= $label.Width
        $y = [int](($form.ClientSize.Height - $label.Height) / 2)
        $label.Location = [System.Drawing.Point]::new([Math]::Max(0, $x), [Math]::Max(0, $y))
        $x -= 12
    }
}

function Update-StatusBarAlignment {
    # The flow panel is auto-sized to its content, so it must be repositioned
    # whenever label text changes width, and whenever the alignment setting changes.
    if (-not $script:StatusBarFlow -or $script:StatusBarForm.IsDisposed) { return }
    $flow = $script:StatusBarFlow
    $form = $script:StatusBarForm
    $flow.PerformLayout()
    $x = switch ($script:Config.StatusBarAlignment) {
        'Center' { [int](($form.ClientSize.Width - $flow.Width) / 2) }
        'Right' { $form.ClientSize.Width - $flow.Width }
        default { if ($script:PowerMenuForm) { $script:PowerMenuForm.Width + 8 } else { 0 } }
    }
    $y = [int](($form.ClientSize.Height - $flow.Height) / 2)
    $flow.Location = [System.Drawing.Point]::new([Math]::Max(0, $x), [Math]::Max(0, $y))
}

function Update-StatusBarContent {
    if (-not $script:StatusBarForm -or $script:StatusBarForm.IsDisposed) { return }

    $activeColor = $script:StatusBarColors.Active
    $busyColor = $script:StatusBarColors.Busy
    $textColor = $script:StatusBarColors.Text

    $byWorkspace = @{}
    foreach ($hwnd in @($script:WindowWorkspace.Keys)) {
        $className = [Win32]::GetClass($hwnd)
        if ($script:Config.ExcludedClasses -contains $className) { continue }
        $procId = 0
        [Win32]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
        try { $procName = (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { $procName = $null }
        if (-not $procName -or ($script:Config.ExcludedProcesses -contains $procName)) { continue }

        $ws = $script:WindowWorkspace[$hwnd]
        if (-not $byWorkspace.ContainsKey($ws)) { $byWorkspace[$ws] = New-Object 'System.Collections.Generic.List[string]' }
        if (-not $byWorkspace[$ws].Contains($procName)) { [void]$byWorkspace[$ws].Add($procName) }
    }

    for ($i = 1; $i -le 9; $i++) {
        $label = $script:StatusBarLabels[$i]
        if (-not $label) { continue }
        $apps = if ($byWorkspace.ContainsKey($i)) { $byWorkspace[$i] -join ', ' } else { $null }
        $isActive = $i -eq $script:ActiveWorkspace
        $label.Visible = [bool]($apps -or $isActive)
        if (-not $label.Visible) { continue }
        $text = if ($apps) { "$i`: $apps" } else { "$i" }
        if ($label.Text -ne $text) { $label.Text = $text }

        if ($isActive) {
            $label.BackColor = $activeColor
            $label.ForeColor = $textColor
        } elseif ($apps) {
            $label.BackColor = $busyColor
            $label.ForeColor = $textColor
        }
    }

    Update-StatusBarAlignment
}

function Set-TrayWorkspaceIcon {
    # Draws the active workspace number onto a small bitmap and uses it as the tray icon.
    param([int]$Workspace)
    $text = if ($Workspace -ge 10) { '9+' } else { [string]$Workspace }
    $bmp = New-Object System.Drawing.Bitmap 16, 16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::FromArgb(0, 120, 215))
    $font = New-Object System.Drawing.Font -ArgumentList 'Segoe UI', 9, ([System.Drawing.FontStyle]::Bold)
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $rect = New-Object System.Drawing.RectangleF 0, 0, 16, 16
    $g.DrawString($text, $font, [System.Drawing.Brushes]::White, $rect, $fmt)

    $hIcon = $bmp.GetHicon()
    $script:trayIcon.Icon = [System.Drawing.Icon]::FromHandle($hIcon)
    $script:trayIcon.Text = "PS Tiling Manager - Workspace $Workspace"

    $g.Dispose(); $font.Dispose(); $fmt.Dispose(); $bmp.Dispose()
    if ($script:TrayIconHandle -ne [IntPtr]::Zero) { [Win32]::DestroyIcon($script:TrayIconHandle) | Out-Null }
    $script:TrayIconHandle = $hIcon
}

function Invoke-DelayedRelayout {
    # A window just un-hidden via SW_SHOWNA sometimes doesn't accept the SetWindowPos we
    # apply in the same tick - a suspended/backgrounded UWP app resuming, or an Electron/WPF
    # app re-asserting its own remembered position a moment after being shown - so windows
    # sent to (or already waiting on) a workspace can land stacked on top of each other and
    # stay that way until manually dragged apart. A short follow-up pass re-applies the tile
    # layout once things have settled, without needing the user to force a retile themselves.
    param([int]$DelayMs = 250)
    $t = New-Object System.Windows.Forms.Timer
    $t.Interval = $DelayMs
    $t.add_Tick({
            param($sender, $e)
            try { Update-WindowSets -Force } catch { Write-Log "Delayed relayout failed: $_" }
            $sender.Stop(); $sender.Dispose()
        })
    $t.Start()
}

function Switch-Workspace {
    # Fakes virtual desktops: hides windows on the outgoing workspace, shows the incoming one.
    param([int]$Workspace)
    if ($script:PowerMenu -and $script:PowerMenu.Visible) { $script:PowerMenu.Close() }
    if ($Workspace -eq $script:ActiveWorkspace) { return }

    foreach ($hwnd in @($script:WindowWorkspace.Keys)) {
        $ws = $script:WindowWorkspace[$hwnd]
        if ($ws -eq $script:ActiveWorkspace) {
            # Don't hide an always-visible alert (e.g. an incoming-call toast) just because
            # we're leaving the workspace it happens to be tagged to - see Test-AlwaysVisibleWindow.
            if (Test-AlwaysVisibleWindow -Hwnd $hwnd) { continue }
            [Win32]::ShowWindow($hwnd, 0) | Out-Null # SW_HIDE
        } elseif ($ws -eq $Workspace -and -not $script:DismissedWindows.Contains($hwnd)) {
            [Win32]::ShowWindow($hwnd, 8) | Out-Null # SW_SHOWNA (no activation)
        }
    }

    $script:ActiveWorkspace = $Workspace
    Update-WindowSets -Force
    Set-TrayWorkspaceIcon -Workspace $Workspace
    Update-StatusBarContent

    $any = $script:ManagedWindows.Values | Where-Object { $_.Count -gt 0 } | Select-Object -First 1
    if ($any) { [Win32]::SetForegroundWindow($any[0]) | Out-Null }
    Invoke-DelayedRelayout
    Write-Log "Workspace $Workspace" -Level Info
}

function Move-FocusedWindowToWorkspace {
    param([int]$Workspace)
    $fg = [Win32]::GetForegroundWindow()
    if ($fg -eq [IntPtr]::Zero -or $Workspace -eq $script:ActiveWorkspace) { return }

    $script:WindowWorkspace[$fg] = $Workspace
    [Win32]::ShowWindow($fg, 0) | Out-Null # SW_HIDE
    foreach ($key in @($script:ManagedWindows.Keys)) {
        [void]$script:ManagedWindows[$key].Remove($fg)
    }
    Update-WindowSets -Force
    Update-StatusBarContent
    Invoke-DelayedRelayout
}


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------

$hotkeyWindow = New-Object HotKeyWindow
$null = $hotkeyWindow.Handle # force handle creation so RegisterHotKey has a target
$script:HotKeyWindowHandle = $hotkeyWindow.Handle

$nextId = 1
foreach ($name in $script:Config.HotKeys.Keys) {
    # AppLauncher.ps1 registers this one itself - see Start-AppLauncher.
    if ($name -eq 'AppLauncher') { continue }
    try {
        $spec = ConvertTo-HotKeySpec -Spec $script:Config.HotKeys[$name]
        $id = $nextId
        $nextId++
        $ok = [HotKeyWindow]::RegisterHotKey($hotkeyWindow.Handle, $id, $spec.Modifiers, $spec.VirtualKey)
        if ($ok) {
            $script:HotKeyActions[$id] = $name
        } else {
            Write-Log "Could not register hotkey for '$name' ($($script:Config.HotKeys[$name])) - it may already be in use by another application."
        }
    } catch {
        Write-Log "Invalid hotkey spec for '$name': $_"
    }
}

foreach ($name in $script:Config.AppShortcuts.Keys) {
    try {
        $spec = ConvertTo-HotKeySpec -Spec $script:Config.AppShortcuts[$name].Key
        $id = $nextId
        $nextId++
        $ok = [HotKeyWindow]::RegisterHotKey($hotkeyWindow.Handle, $id, $spec.Modifiers, $spec.VirtualKey)
        if ($ok) {
            $script:HotKeyActions[$id] = "Launch:$name"
        } else {
            Write-Log "Could not register app shortcut '$name' ($($script:Config.AppShortcuts[$name].Key)) - it may already be in use by another application."
        }
    } catch {
        Write-Log "Invalid hotkey spec for app shortcut '$name': $_"
    }
}

$hotkeyWindow.add_HotKeyPressed({
        # An uncaught exception here would otherwise unwind through the WinForms message
        # loop and silently kill the whole app - keep the WM alive and log it instead.
        try {
            $action = $script:HotKeyActions[$hotkeyWindow.LastHotKeyId]
            if ($action -match '^Workspace(\d+)$') {
                Switch-Workspace -Workspace ([int]$Matches[1])
                return
            }
            if ($action -match '^MoveToWorkspace(\d+)$') {
                Move-FocusedWindowToWorkspace -Workspace ([int]$Matches[1])
                return
            }
            if ($action -match '^Launch:(.+)$') {
                Invoke-LaunchApp -Name $Matches[1]
                return
            }
            switch ($action) {
                'FocusLeft' { Invoke-FocusDirection -Direction 'Left' }
                'FocusRight' { Invoke-FocusDirection -Direction 'Right' }
                'FocusUp' { Invoke-FocusDirection -Direction 'Up' }
                'FocusDown' { Invoke-FocusDirection -Direction 'Down' }
                'SwapMaster' { Invoke-SwapMaster }
                'MoveLeft' { Invoke-MoveToMaster }
                'MoveRight' { Invoke-MoveToStack }
                'MoveDown' { Invoke-MoveInStack -Direction 1 }
                'MoveUp' { Invoke-MoveInStack -Direction -1 }
                'ShrinkMaster' { Invoke-ResizeMaster -Delta -0.05 }
                'GrowMaster' { Invoke-ResizeMaster -Delta 0.05 }
                'CloseWindow' { Invoke-CloseFocusedWindow }
                'ToggleFloating' { Invoke-ToggleFloating }
                'FloatingToFront' { Invoke-BringFloatingToFront }
                'Retile' { Update-WindowSets -Force }
                'Quit' { Invoke-Quit }
                'Restart' { Invoke-Restart }
            }
        } catch { Write-Log "Hotkey action '$action' failed: $_" }
    })

$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Visible = $true
$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$trayMenu.Items.Add('Retile now', $null, { try { Update-WindowSets -Force } catch { Write-Log "Retile now failed: $_" } })
# Dumps the current screen/window geometry to TilingWM.log - click this while a layout
# problem is on screen, before retiling or restarting destroys the evidence.
[void]$trayMenu.Items.Add('Log diagnostic snapshot', $null, { try { Write-DiagnosticSnapshot -Reason 'tray menu' } catch { Write-Log "Diagnostic snapshot failed: $_" } })
[void]$trayMenu.Items.Add('Restart', $null, { try { Invoke-Restart } catch { Write-Log "Restart failed: $_" } })
[void]$trayMenu.Items.Add('Exit', $null, { try { Invoke-Quit } catch { Write-Log "Exit failed: $_" } })
$trayIcon.ContextMenuStrip = $trayMenu
Set-TrayWorkspaceIcon -Workspace $script:ActiveWorkspace

if ($script:Config.HotKeys.AppLauncher) { Start-AppLauncher }
if ($script:Config.ShowStatusBar) { Initialize-StatusBar }
if ($script:Config.HideTaskbar) { Set-TaskbarVisible -Visible $false }

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = [int]$script:Config.PollIntervalMs
# An uncaught exception here would otherwise unwind through the WinForms message
# loop and silently kill the whole app - keep the WM alive and log it instead.
$timer.add_Tick({
    try {
        Update-WindowSets; Update-StatusBarContent; Update-StatusBarClock; Update-StatusBarBattery; Update-StatusBarRightWidgets
    } catch { Write-Log "Update-WindowSets failed: $_" }
})

$mouseTimer = New-Object System.Windows.Forms.Timer
$mouseTimer.Interval = [int]$script:Config.FocusFollowsMousePollMs
$mouseTimer.add_Tick({
    try { Invoke-FocusFollowsMouseTick } catch { Write-Log "Invoke-FocusFollowsMouseTick failed: $_" }
})

# Fires the instant the user finishes dragging/resizing ANY top-level window (mouse-up after
# a title-bar drag or border resize) - snaps a tiled window straight back into its grid slot
# instead of leaving it wherever it was dropped until the next poll or a manual Alt+Shift+R.
# WINEVENT_OUTOFCONTEXT (dwFlags=0) delivers this callback synchronously on this same thread's
# message pump, so touching $script:-scoped state from it is safe.
$script:MoveSizeEndProc = {
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $dwEventThread, $dwmsEventTime)
    try {
        if ($idObject -ne 0 -or $hwnd -eq [IntPtr]::Zero) { return } # OBJID_WINDOW only
        foreach ($key in @($script:ManagedWindows.Keys)) {
            if ($script:ManagedWindows[$key].Contains($hwnd)) {
                Set-MonitorLayout -MonitorKey $key
                break
            }
        }
    } catch { Write-Log "MoveSizeEnd hook failed: $_" }
}
# EVENT_SYSTEM_MOVESIZEEND = 0x000B for both eventMin/eventMax - only that one event.
$script:MoveSizeEndHook = [Win32]::SetWinEventHook(0x000B, 0x000B, [IntPtr]::Zero, $script:MoveSizeEndProc, 0, 0, 0)

# Window show/hide/minimize/cloak events trigger an immediate (debounced) rescan, so new and
# closed windows tile right away; the poll timer above is just a safety net for anything
# these events miss (e.g. a window that only gets its title after it's shown).
$script:WindowWatcher = New-Object WindowChangeWatcher -ArgumentList 60, 250
$script:WindowWatcher.add_Changed({
        try { Update-WindowSets; Update-StatusBarContent } catch { Write-Log "Window-change rescan failed: $_" }
    })
$script:WindowWatcher.Start()

Update-WindowSets -Force
Update-StatusBarContent
$timer.Start()
if ($script:Config.FocusFollowsMouse) { $mouseTimer.Start() }

Write-Log "PS Tiling Manager starting (pid $PID, $($PSVersionTable.PSVersion), logLevel=$($script:Config.LogLevel))" -Level Info
Write-DiagnosticSnapshot -Reason 'startup'
Write-Log "PS Tiling Manager running. Press Alt+Shift+E (or use the tray icon) to quit." -Level Info

try {
    [System.Windows.Forms.Application]::Run($hotkeyWindow)
} finally {
    $timer.Stop()
    $timer.Dispose()
    $mouseTimer.Stop()
    $mouseTimer.Dispose()
    if ($script:MoveSizeEndHook -and $script:MoveSizeEndHook -ne [IntPtr]::Zero) { [Win32]::UnhookWinEvent($script:MoveSizeEndHook) | Out-Null }
    if ($script:WindowWatcher) { $script:WindowWatcher.Dispose() }
    # Un-hide anything parked on an inactive fake workspace so it can't be stranded when we quit.
    foreach ($hwnd in $script:WindowWorkspace.Keys) {
        [Win32]::ShowWindow($hwnd, 8) | Out-Null # SW_SHOWNA
    }
    Set-TaskbarVisible -Visible $true
    # Application.Exit() already closes/disposes $hotkeyWindow before Run() returns, so use the
    # handle captured while it was still alive rather than re-querying the (now disposed) form.
    foreach ($id in $script:HotKeyActions.Keys) {
        try { [HotKeyWindow]::UnregisterHotKey($script:HotKeyWindowHandle, $id) | Out-Null } catch { }
    }
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    if ($script:TrayIconHandle -ne [IntPtr]::Zero) { [Win32]::DestroyIcon($script:TrayIconHandle) | Out-Null }
    if ($script:StatusBarForm -and -not $script:StatusBarForm.IsDisposed) { $script:StatusBarForm.Dispose() }
    if ($script:PowerMenuDismissTimer) { $script:PowerMenuDismissTimer.Stop(); $script:PowerMenuDismissTimer.Dispose() }
    if ($script:PowerMenu -and -not $script:PowerMenu.IsDisposed) { $script:PowerMenu.Dispose() }
    if ($script:PowerMenuForm -and -not $script:PowerMenuForm.IsDisposed) { $script:PowerMenuForm.Dispose() }
    Stop-AppLauncher
    if (-not $hotkeyWindow.IsDisposed) { $hotkeyWindow.Dispose() }
    try { $script:InstanceMutex.ReleaseMutex() } catch { }
    $script:InstanceMutex.Dispose()
}
