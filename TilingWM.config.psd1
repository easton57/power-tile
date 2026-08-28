# PS Tiling Manager configuration.
# Delete or rename this file to fall back to the built-in defaults.
# NOTE: if you include the HotKeys key at all, it replaces the whole default
# HotKeys table, so list every binding you want (not just the ones you change).
@{
    Gap                = 8      # pixels between tiled windows and screen edges
    MasterRatio        = 0.55   # fraction of monitor width given to the master pane
    PollIntervalMs     = 400    # how often (ms) to scan for new/closed windows

    FocusFollowsMouse       = $true  # hover a tiled window to focus it, no click needed
    FocusFollowsMousePollMs = 100    # how often (ms) to check the cursor position

    ShowStatusBar      = $true   # top-of-screen bar listing which apps are on which workspace
    StatusBarHeight    = 28      # pixels reserved at the top of the primary monitor for it
    StatusBarAlignment = 'Center' # 'Left', 'Center', or 'Right' placement of the workspace slots
    HideTaskbar        = $true   # hide the real Windows taskbar too (restored automatically on exit)
    StatusBarShowClock = $true   # show a clock/date on the status bar - only matters when HideTaskbar is $true
    StatusBarShowBattery = $true # show battery % next to the clock - only if a battery is detected

    # colors accept '#RRGGBB' hex or named colors (e.g. 'DodgerBlue')
    # Only the workspace slot labels are opaque - the rest of the bar is transparent.
    StatusBarBackColor     = '#181818'  # empty (idle) workspace slots
    StatusBarActiveColor   = '#8800d7'  # active workspace slot background
    StatusBarBusyColor     = '#3C3C3C'  # non-active workspace slots that have apps open
    StatusBarTextColor     = '#FFFFFF'  # text on active/busy slots
    StatusBarIdleTextColor = '#808080'  # text on empty workspace slots

    ExcludedProcesses  = @(
        'explorer'
        'ShellExperienceHost'
        'SearchHost'
        'StartMenuExperienceHost'
        'TextInputHost'
        'SystemSettings'
    )

    ExcludedClasses    = @(
        'Shell_TrayWnd'
        'Shell_SecondaryTrayWnd'
        'Progman'
        'WorkerW'
        'Windows.UI.Core.CoreWindow'
        'MultitaskingViewFrame'
    )

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
        Retile         = 'Alt+Shift+R'
        Quit           = 'Alt+Shift+E'
        AppLauncher    = 'Alt+Space'   # fuzzy-search installed apps, Enter to run

        # Workspace1-9 switches to that (fake/virtual) workspace; MoveToWorkspaceN
        # moves the focused window there. Windows on inactive workspaces are hidden.
        Workspace1        = 'Alt+1'
        Workspace2        = 'Alt+2'
        Workspace3        = 'Alt+3'
        Workspace4        = 'Alt+4'
        Workspace5        = 'Alt+5'
        Workspace6        = 'Alt+6'
        Workspace7        = 'Alt+7'
        Workspace8        = 'Alt+8'
        Workspace9        = 'Alt+9'
        MoveToWorkspace1  = 'Alt+Shift+1'
        MoveToWorkspace2  = 'Alt+Shift+2'
        MoveToWorkspace3  = 'Alt+Shift+3'
        MoveToWorkspace4  = 'Alt+Shift+4'
        MoveToWorkspace5  = 'Alt+Shift+5'
        MoveToWorkspace6  = 'Alt+Shift+6'
        MoveToWorkspace7  = 'Alt+Shift+7'
        MoveToWorkspace8  = 'Alt+Shift+8'
        MoveToWorkspace9  = 'Alt+Shift+9'
    }

    # App-launcher shortcuts: each entry is name = @{ Key = '...'; Path = '...'; Arguments = '...' (optional) }.
    # None are bound by default; uncomment/edit the examples below or add your own.
    AppShortcuts       = @{
        Terminal = @{ Key = 'Alt+T'; Path = 'wt.exe' }
        Browser  = @{ Key = 'Alt+B'; Path = '"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"' }
        Outlook = @{ Key = 'Alt+O'; Path = '"C:\Program Files (x86)\Microsoft Office\root\Office16\OUTLOOK.EXE"' }
        Teams = @{ Key = 'Alt+Shift+T'; Path = 'ms-teams.exe' }
        FileExplorer = @{ Key = 'Alt+F'; Path = 'explorer.exe' }
    }
}
