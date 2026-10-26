# Helpers shared by TilingWM.ps1 and AppLauncher.ps1.

function Get-PowerTileDataDirectory {
    # Logs and runtime state live under %LOCALAPPDATA% rather than next to the scripts, so they
    # stay out of the git checkout and out of any OneDrive-synced folder (where concurrent
    # writes produce "(... copy)" conflict files instead of one log).
    $base = $env:LOCALAPPDATA
    if (-not $base) { $base = [Environment]::GetFolderPath('LocalApplicationData') }
    $dir = Join-Path $base 'power-tile'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function ConvertTo-HotKeySpec {
    # "Alt+Shift+J" -> RegisterHotKey modifiers (with MOD_NOREPEAT) + virtual key code.
    param([string]$Spec)

    $parts = $Spec -split '\+'
    $key = $parts[-1].Trim()
    $modFlags = 0x4000 # MOD_NOREPEAT
    if ($parts.Count -gt 1) {
        foreach ($m in $parts[0..($parts.Count - 2)]) {
            switch ($m.Trim().ToLower()) {
                'alt' { $modFlags = $modFlags -bor 0x1 }
                'ctrl' { $modFlags = $modFlags -bor 0x2 }
                'control' { $modFlags = $modFlags -bor 0x2 }
                'shift' { $modFlags = $modFlags -bor 0x4 }
                'win' { $modFlags = $modFlags -bor 0x8 }
                default { throw "Unknown modifier '$m' in hotkey spec '$Spec'" }
            }
        }
    }

    $keyMap = @{ 'Enter' = 0x0D; 'Space' = 0x20; 'Tab' = 0x09; 'Escape' = 0x1B; 'Esc' = 0x1B; 'Left' = 0x25; 'Up' = 0x26; 'Right' = 0x27; 'Down' = 0x28; '[' = 0xDB; ']' = 0xDD }
    if ($keyMap.ContainsKey($key)) {
        $vk = $keyMap[$key]
    } elseif ($key.Length -eq 1) {
        $vk = [byte][char]$key.ToUpper()
    } elseif ($key -match '^[Ff](\d{1,2})$') {
        $vk = 0x70 + [int]$Matches[1] - 1
    } else {
        throw "Unknown key '$key' in hotkey spec '$Spec'"
    }

    [PSCustomObject]@{ Modifiers = [uint32]$modFlags; VirtualKey = [uint32]$vk }
}

Export-ModuleMember -Function Get-PowerTileDataDirectory, ConvertTo-HotKeySpec
