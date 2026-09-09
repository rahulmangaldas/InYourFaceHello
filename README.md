# InYourFaceHello

A minimal [DeskPins](https://efotinis.neocities.org/deskpins/) clone in pure PowerShell — pin any window (including the Windows Hello prompt) always-on-top.

## Usage

```
powershell -File InYourFaceHello.ps1
```

(Windows PowerShell 5.1 runs STA by default; on PowerShell 7 use `pwsh -sta -File InYourFaceHello.ps1`.)

A tray icon appears (it may be tucked into the "Show hidden icons" overflow). Left-click it — or use "Pin a Window" from its right-click menu — to arm pin mode: the cursor turns into a crosshair. Click any window to toggle it always-on-top. Press Esc, or click the tray icon again, to cancel.

Pinned windows get a small pin glyph overlaid on their corner, and the tray icon's right-click menu lists everything currently pinned above a divider (click an entry to unpin it).

Windows are remembered by executable (image) name, not window title, and persist across restarts in `%APPDATA%\InYourFaceHello\settings.json`. On launch, and whenever a new window appears, any window whose process image name is remembered gets auto-pinned — useful for prompts like Windows Hello that reappear under a new window each time and are otherwise easy to lose behind other windows.

Note: pinning the Windows Hello / Credential UI prompt requires running this script elevated, since it runs at a higher UAC integrity level.
