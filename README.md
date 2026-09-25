# power-tile

**THIS WAS 90% BUILT BY AI, IF THAT BOTHERS YOU THEN MOVE ON**

Power tile is a PowerShell tiling window manager for those poor souls stuck on a corporate Windows machine for their day-to-day work.

## Features

* Automatic master-stack tiling with configurable gaps and master ratio
* Nine simulated workspaces with configurable navigation and window-movement hotkeys
* Focus-follows-mouse and keyboard-driven focus, movement, resizing, and floating controls
* A fuzzy application launcher because the Start menu, after all these years, is still hot garbage
* Configurable quick-launch shortcuts
* A persistent top bar showing occupied workspaces and their open applications; empty workspaces are hidden
* Clock and battery widgets styled consistently with occupied workspaces
* A top-left power menu with Lock, Sleep, Restart, Shut down, and Exit actions
* Optional Windows taskbar hiding, restored automatically when power-tile exits
* Configurable status-bar colors and alignment

## Running power-tile

```powershell
git clone https://github.com/easton57/power-tile.git
cd power-tile
powershell.exe -ExecutionPolicy Bypass -File .\TilingWM.ps1
```

Run PowerShell as administrator if you also want power-tile to manage elevated windows.

## Configuration

Edit `TilingWM.config.psd1` to change gaps, layout ratio, status-bar behavior, colors, excluded applications, shortcuts, and hotkeys. Restart the running manager with `Ctrl+Shift+R` to apply changes.

The `HotKeys` table replaces the complete default table when provided, so keep every binding you want when editing it.

## Default controls

| Action | Shortcut |
| --- | --- |
| Focus left/down/up/right | `Alt+H/J/K/L` |
| Swap focused window with master | `Alt+Enter` |
| Move window left/down/up/right | `Alt+Shift+H/J/K/L` |
| Shrink/grow master area | `Alt+[` / `Alt+]` |
| Close focused window | `Alt+Q` |
| Toggle floating | `Alt+Shift+Space` |
| Bring floating windows forward | `Alt+Shift+F` |
| Retile | `Alt+Shift+R` |
| Switch workspace | `Alt+1..9` |
| Move window to workspace | `Alt+Shift+1..9` |
| Open application launcher | `Ctrl+Shift+Space` |
| Restart power-tile | `Ctrl+Shift+R` |
| Exit power-tile | `Alt+Shift+E` |

## Future features

* Install script
* Crash watcher
* Full multi-monitor support