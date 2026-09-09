<#
InYourFaceHello - a minimal DeskPins clone in pure PowerShell.

Usage:
  - Run this script (Windows, PowerShell 5.1+). A tray icon appears (it may be
    tucked inside the "Show hidden icons" overflow next to the clock).
  - Left-click the tray icon (or "Pin a Window" in its right-click menu) to arm
    pin mode: the cursor turns into a crosshair. Click any window to toggle it
    always-on-top. Press Esc - or click the tray icon again - to cancel.
  - A small pin glyph is overlaid on the corner of each pinned window, and the
    tray icon's right-click menu lists everything currently pinned above a
    divider (click an entry to unpin it). There are deliberately no toast
    notifications - Windows balloon tips are slow and laggy.
  - Settings (pinned process list, start-with-windows) persist to:
      %APPDATA%\InYourFaceHello\settings.json
    Windows are remembered by executable (image) name, not window title.
    On launch, and whenever a NEW window appears (via SetWinEventHook), any
    window whose process image name is remembered gets auto-pinned. Note that
    this pins EVERY window of a remembered process, not just the instance you
    originally clicked.

Design notes (each of these was arrived at the hard way):
  - Cursor: SetCursor() from inside a mouse hook does NOT stick - the window
    that owns the pointer resets the cursor on its next WM_SETCURSOR, which it
    does far more often than a hook can re-assert. SetSystemCursor() swaps the
    system cursor artwork itself and is actually visible.
  - Pin indicator: SetWindowText() is NOT used. Modern apps (WinUI/UWP/Electron,
    including Windows 11 Notepad) draw their own title bars, so changing the
    window text is invisible there - it only shows in Alt-Tab/taskbar. A small
    overlay window is used instead, so the marker is visible for every app. The
    overlay is click-through (WS_EX_TRANSPARENT) so it can never block a click
    on the window underneath it.
  - The pick click is swallowed by the hook, so clicking a window to pin it
    does not also press whatever was under the cursor.

Notes / limitations:
  - Windows PowerShell 5.1 runs STA by default. On PowerShell 7 (pwsh),
    launch with: pwsh -sta -File InYourFaceHello.ps1
  - GA_ROOT resolves the top-level window under the cursor, so clicking the
    taskbar/desktop can also "pin" those - a simplification vs. real DeskPins.
  - The event hook only sees windows at the same UAC integrity level as this
    script; it won't catch windows from an elevated process unless this script
    is also elevated.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Log unhandled UI-thread exceptions instead of letting them kill the tray app
# silently (a disposed menu item took it down once, with no trace).
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)

Add-Type @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public struct POINT { public int X; public int Y; }
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
public struct SIZE { public int cx; public int cy; }
[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct BLENDFUNCTION { public byte BlendOp; public byte BlendFlags; public byte SourceConstantAlpha; public byte AlphaFormat; }

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
public delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint idEventThread, uint dwmsEventTime);
public delegate IntPtr LowLevelMouseProc(int nCode, IntPtr wParam, IntPtr lParam);

public struct MSLLHOOKSTRUCT {
    public POINT pt;
    public uint mouseData;
    public uint flags;
    public uint time;
    public IntPtr dwExtraInfo;
}

public static class Native {
    [DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern short GetAsyncKeyState(int vKey);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool UnhookWinEvent(IntPtr hWinEventHook);
    [DllImport("user32.dll", SetLastError = true)] public static extern IntPtr SetWindowsHookEx(int idHook, LowLevelMouseProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll")] public static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")] public static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")] public static extern IntPtr LoadCursor(IntPtr hInstance, int lpCursorName);
    [DllImport("user32.dll")] public static extern IntPtr CopyIcon(IntPtr h);
    [DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr hcur, uint id);
    [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint uiAction, uint uiParam, IntPtr pvParam, uint fWinIni);
    [DllImport("user32.dll")] public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);
    [DllImport("user32.dll")] public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtr dwNewLong);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern IntPtr GetDC(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern int ReleaseDC(IntPtr hWnd, IntPtr hDC);
    [DllImport("user32.dll")] public static extern bool UpdateLayeredWindow(IntPtr hwnd, IntPtr hdcDst, ref POINT pptDst, ref SIZE psize, IntPtr hdcSrc, ref POINT pptSrc, int crKey, ref BLENDFUNCTION pblend, int dwFlags);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr hgdiobj);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr hObject);
}
"@

$PinColor = [System.Drawing.Color]::FromArgb(255, 226, 59, 59)   # flat red

$DebugLogFile = "$env:TEMP\inyourfacehello_debug.log"
function Write-DebugLog([string]$msg) {
    try { Add-Content -Path $DebugLogFile -Value "$(Get-Date -Format 'HH:mm:ss.fff') $msg" -ErrorAction SilentlyContinue } catch { }
}

# ---------------- Settings ----------------
$SettingsDir  = Join-Path $env:APPDATA "InYourFaceHello"
$SettingsFile = Join-Path $SettingsDir "settings.json"
if (-not (Test-Path $SettingsDir)) { New-Item -ItemType Directory -Path $SettingsDir -Force | Out-Null }

function Load-Settings {
    if (Test-Path $SettingsFile) {
        try {
            $raw = Get-Content $SettingsFile -Raw | ConvertFrom-Json
            $pinned = @()
            foreach ($item in @($raw.PinnedWindows)) {
                if ($item -is [string]) { $pinned += $item }
                elseif ($item -and $item.Process) { $pinned += [string]$item.Process }
            }
            return [PSCustomObject]@{
                StartWithWindows = [bool]$raw.StartWithWindows
                PinnedWindows    = @($pinned | Select-Object -Unique)
            }
        } catch { }
    }
    return [PSCustomObject]@{ StartWithWindows = $false; PinnedWindows = @() }
}

function Save-Settings {
    $Settings | ConvertTo-Json -Depth 5 | Set-Content -Path $SettingsFile -Encoding UTF8
}

# $Settings.PinnedWindows is the persisted "remember to auto-pin" list of
# process image names. It must survive a window closing, so reopening the same
# executable re-pins it. It is NOT $PinnedMap (the currently-live pinned
# windows) and must never be rebuilt from it - only explicitly added/removed.
function Remember-Process([string]$proc) {
    if ([string]::IsNullOrWhiteSpace($proc)) { return }
    if ($Settings.PinnedWindows -notcontains $proc) {
        $Settings.PinnedWindows = @($Settings.PinnedWindows) + $proc
    }
    Save-Settings
}

function Forget-Process([string]$proc) {
    $Settings.PinnedWindows = @($Settings.PinnedWindows | Where-Object { $_ -ne $proc })
    Save-Settings
}

$Settings  = Load-Settings
$PinnedMap = @{}   # key: hwnd.ToInt64() -> @{ Hwnd; Process; Overlay }
$script:PinModeOn = $false
$script:SwallowNextUp = $false

# ---------------- Helpers ----------------
function Get-WindowTitle([IntPtr]$hwnd) {
    $sb = New-Object System.Text.StringBuilder 512
    [Native]::GetWindowText($hwnd, $sb, 512) | Out-Null
    return $sb.ToString()
}

function Get-WindowProcessName([IntPtr]$hwnd) {
    $procId = 0
    [Native]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
    try { return (Get-Process -Id $procId -ErrorAction Stop).ProcessName } catch { return "" }
}

# ---------------- Pin marker overlay ----------------
# A real overlay window, because SetWindowText is invisible on apps that draw
# their own title bar (WinUI/UWP/Electron - including Windows 11 Notepad).
# The icon is drawn flat with GDI+ and pushed via UpdateLayeredWindow (true
# per-pixel alpha). A colour-key transparency would leave a fringe of the key
# colour around every antialiased edge, which looks awful on a small glyph.
$GlyphSize   = 20
$GlyphInsetX = 180   # from the window's right edge, clearing the caption buttons
$GlyphInsetY = 10

function Get-GlyphPosition([RECT]$rect) {
    return New-Object System.Drawing.Point(($rect.Right - $GlyphInsetX), ($rect.Top + $GlyphInsetY))
}

# Flat pin: round head, tapered point, punched-out centre.
function New-PinBitmap([int]$s, [System.Drawing.Color]$color) {
    $bmp = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear([System.Drawing.Color]::Transparent)

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    # Winding, not the default Alternate: the head and the tip overlap, and
    # Alternate would cancel the overlap out and punch a wedge through the pin.
    $path.FillMode = [System.Drawing.Drawing2D.FillMode]::Winding
    $headD = $s * 0.74
    $path.AddEllipse(($s - $headD) / 2, $s * 0.02, $headD, $headD)
    $tip = New-Object 'System.Drawing.PointF[]' 3
    $tip[0] = New-Object System.Drawing.PointF(($s * 0.32), ($s * 0.62))
    $tip[1] = New-Object System.Drawing.PointF(($s * 0.68), ($s * 0.62))
    $tip[2] = New-Object System.Drawing.PointF(($s * 0.50), ($s * 0.98))
    $path.AddPolygon($tip)

    $brush = New-Object System.Drawing.SolidBrush($color)
    $g.FillPath($brush, $path)

    # punch the centre out so it reads as a pin rather than a blob
    $g.CompositingMode = [System.Drawing.Drawing2D.CompositingMode]::SourceCopy
    $holeD = $s * 0.26
    $g.FillEllipse([System.Drawing.Brushes]::Transparent, ($s - $holeD) / 2, ($s * 0.02) + ($headD - $holeD) / 2, $holeD, $holeD)

    $brush.Dispose(); $path.Dispose(); $g.Dispose()
    return $bmp
}

# UpdateLayeredWindow expects premultiplied alpha, GDI+ produces straight alpha.
# Only the overlay needs this - Icon.FromHandle/GetHicon wants straight alpha,
# so the tray icon is built from an unconverted bitmap.
function ConvertTo-PremultipliedAlpha([System.Drawing.Bitmap]$bmp) {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $bmp.Width, $bmp.Height
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadWrite, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $len = $data.Stride * $data.Height
    $buf = New-Object byte[] $len
    [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $buf, 0, $len)
    for ($i = 0; $i -lt $len; $i += 4) {
        $a = $buf[$i + 3]
        if ($a -ne 255) {
            $buf[$i]     = [byte](($buf[$i]     * $a) / 255)
            $buf[$i + 1] = [byte](($buf[$i + 1] * $a) / 255)
            $buf[$i + 2] = [byte](($buf[$i + 2] * $a) / 255)
        }
    }
    [System.Runtime.InteropServices.Marshal]::Copy($buf, 0, $data.Scan0, $len)
    $bmp.UnlockBits($data)
    return $bmp
}

$PinBitmap = ConvertTo-PremultipliedAlpha (New-PinBitmap $GlyphSize $PinColor)

# Same artwork for the tray icon. Rendered at 32px and left for Windows to
# scale; the bitmap is kept referenced so its GDI handle stays alive.
$TrayBitmap  = New-PinBitmap 32 $PinColor
$TrayPinIcon = [System.Drawing.Icon]::FromHandle($TrayBitmap.GetHicon())

function Update-LayeredIcon([System.Windows.Forms.Form]$f, [int]$x, [int]$y) {
    $hBitmap  = $PinBitmap.GetHbitmap([System.Drawing.Color]::FromArgb(0))
    $screenDc = [Native]::GetDC([IntPtr]::Zero)
    $memDc    = [Native]::CreateCompatibleDC($screenDc)
    $oldBmp   = [Native]::SelectObject($memDc, $hBitmap)
    try {
        $size = New-Object SIZE
        $size.cx = $PinBitmap.Width; $size.cy = $PinBitmap.Height
        $srcPt = New-Object POINT
        $dstPt = New-Object POINT
        $dstPt.X = $x; $dstPt.Y = $y
        $blend = New-Object BLENDFUNCTION
        $blend.BlendOp = 0; $blend.BlendFlags = 0; $blend.SourceConstantAlpha = 255; $blend.AlphaFormat = 1  # AC_SRC_ALPHA
        [Native]::UpdateLayeredWindow($f.Handle, $screenDc, [ref]$dstPt, [ref]$size, $memDc, [ref]$srcPt, 0, [ref]$blend, 2) | Out-Null  # ULW_ALPHA
    } finally {
        [Native]::SelectObject($memDc, $oldBmp) | Out-Null
        [Native]::DeleteObject($hBitmap) | Out-Null
        [Native]::DeleteDC($memDc) | Out-Null
        [Native]::ReleaseDC([IntPtr]::Zero, $screenDc) | Out-Null
    }
}

function New-PinOverlay([IntPtr]$targetHwnd) {
    $rect = New-Object RECT
    [Native]::GetWindowRect($targetHwnd, [ref]$rect) | Out-Null
    $pt = Get-GlyphPosition $rect

    $f = New-Object System.Windows.Forms.Form
    $f.FormBorderStyle = 'None'
    $f.ShowInTaskbar   = $false
    $f.StartPosition   = 'Manual'
    $f.TopMost         = $true
    $f.MinimumSize     = New-Object System.Drawing.Size(0,0)
    $f.Show()

    # Click-through + no activation, so the glyph can never eat a click or steal focus.
    $GWL_EXSTYLE = -20
    $ex = [Native]::GetWindowLongPtr($f.Handle, $GWL_EXSTYLE).ToInt64()
    $ex = $ex -bor 0x80000 -bor 0x20 -bor 0x80 -bor 0x08000000  # LAYERED|TRANSPARENT|TOOLWINDOW|NOACTIVATE
    [Native]::SetWindowLongPtr($f.Handle, $GWL_EXSTYLE, [IntPtr]$ex) | Out-Null

    # UpdateLayeredWindow sets content, size and position in one shot - which also
    # sidesteps the minimum-window-size clamp that Show() applies.
    Update-LayeredIcon $f $pt.X $pt.Y
    return $f
}

# ---------------- Pin / unpin ----------------
# Topmost only puts a window above non-topmost ones - it does not raise or
# focus it. A credential prompt that appears behind something needs an actual
# activate, and Windows blocks foreground changes from a background process
# unless you attach to the current foreground thread's input queue first.
function Bring-ToFront([IntPtr]$hwnd) {
    try {
        if ([Native]::IsIconic($hwnd)) { [Native]::ShowWindow($hwnd, 9) | Out-Null }   # SW_RESTORE
        $dummy = 0
        $fgThread  = [Native]::GetWindowThreadProcessId([Native]::GetForegroundWindow(), [ref]$dummy)
        $curThread = [Native]::GetCurrentThreadId()
        $attached  = $false
        if ($fgThread -ne 0 -and $fgThread -ne $curThread) {
            $attached = [Native]::AttachThreadInput($curThread, $fgThread, $true)
        }
        [Native]::BringWindowToTop($hwnd) | Out-Null
        $ok = [Native]::SetForegroundWindow($hwnd)
        if ($attached) { [Native]::AttachThreadInput($curThread, $fgThread, $false) | Out-Null }
        Write-DebugLog "raise hwnd=$hwnd SetForegroundWindow=$ok"
    } catch {
        Write-DebugLog "Bring-ToFront EXCEPTION: $($_.Exception.Message)"
    }
}

function Pin-Window {
    param([IntPtr]$hwnd, [bool]$persist = $true, [bool]$raise = $true)
    $key = $hwnd.ToInt64()
    if ($PinnedMap.ContainsKey($key)) { return }

    [Native]::SetWindowPos($hwnd, [IntPtr]-1, 0,0,0,0, 0x0001 -bor 0x0002) | Out-Null  # HWND_TOPMOST
    $proc    = Get-WindowProcessName $hwnd
    $overlay = New-PinOverlay $hwnd

    $PinnedMap[$key] = @{ Hwnd = $hwnd; Process = $proc; Overlay = $overlay }
    Write-DebugLog "pinned hwnd=$hwnd proc=$proc"
    if ($raise)   { Bring-ToFront $hwnd }
    if ($persist) { Remember-Process $proc }
}

function Unpin-Window {
    param([Int64]$key)
    $entry = $PinnedMap[$key]
    if (-not $entry) { return }
    [Native]::SetWindowPos($entry.Hwnd, [IntPtr]-2, 0,0,0,0, 0x0001 -bor 0x0002) | Out-Null  # HWND_NOTOPMOST
    if ($entry.Overlay) { $entry.Overlay.Close(); $entry.Overlay.Dispose() }
    $PinnedMap.Remove($key)
    Write-DebugLog "unpinned hwnd=$($entry.Hwnd) proc=$($entry.Process)"
    Forget-Process $entry.Process
}

# ---------------- Pin mode ----------------
# SetSystemCursor swaps the cursor artwork itself, which is the only approach
# that is actually visible; SetCursor from a hook gets reset by whichever
# window owns the pointer before it can ever be seen.
$IDC_CROSS      = 32515
$SPI_SETCURSORS = 0x0057
$CursorIds      = @(32512, 32513, 32649)   # OCR_NORMAL, OCR_IBEAM, OCR_HAND

function Set-CrossCursor {
    try {
        foreach ($id in $CursorIds) {
            $cross = [Native]::LoadCursor([IntPtr]::Zero, $IDC_CROSS)
            [Native]::SetSystemCursor([Native]::CopyIcon($cross), $id) | Out-Null
        }
    } catch { Write-DebugLog "Set-CrossCursor failed: $($_.Exception.Message)" }
}

function Restore-Cursors {
    try { [Native]::SystemParametersInfo($SPI_SETCURSORS, 0, [IntPtr]::Zero, 0) | Out-Null }
    catch { Write-DebugLog "Restore-Cursors failed: $($_.Exception.Message)" }
}

$EscTimer = New-Object System.Windows.Forms.Timer
$EscTimer.Interval = 50
$EscTimer.Add_Tick({
    if ([Native]::GetAsyncKeyState(0x1B) -lt 0) { Cancel-PinMode }   # VK_ESCAPE
})

function Exit-PinMode {
    $script:PinModeOn = $false
    $EscTimer.Stop()
    Restore-Cursors
}

function Cancel-PinMode {
    if (-not $script:PinModeOn) { return }
    Write-DebugLog "pin mode cancelled"
    Exit-PinMode
}

function Enter-PinMode {
    if ($script:PinModeOn) { Cancel-PinMode; return }   # clicking the tray icon again cancels
    Write-DebugLog "pin mode armed"
    $script:PinModeOn = $true
    Set-CrossCursor   # the crosshair is the only "armed" indicator
    $EscTimer.Start()
}

# ---------------- Global low-level mouse hook (click detection) ----------------
$WH_MOUSE_LL    = 14
$WM_LBUTTONDOWN = 0x0201
$WM_LBUTTONUP   = 0x0202

$script:MouseHookCallback = {
    param($nCode, $wParam, $lParam)
    try {
        if ($nCode -ge 0) {
            $msg = [int64]$wParam
            if ($msg -eq $WM_LBUTTONDOWN -and $script:PinModeOn) {
                $hookStruct  = [System.Runtime.InteropServices.Marshal]::PtrToStructure($lParam, [type]"MSLLHOOKSTRUCT")
                $hwndAtPoint = [Native]::WindowFromPoint($hookStruct.pt)
                $root        = [Native]::GetAncestor($hwndAtPoint, 2)  # GA_ROOT
                Write-DebugLog "pick at ($($hookStruct.pt.X),$($hookStruct.pt.Y)) root=$root"
                if ($root -ne [IntPtr]::Zero -and $root -ne $TrayForm.Handle) {
                    $key = $root.ToInt64()
                    if ($PinnedMap.ContainsKey($key)) { Unpin-Window $key } else { Pin-Window $root }
                }
                Exit-PinMode
                # Swallow this click (and its matching mouse-up) so picking a
                # window doesn't also press whatever was under the cursor.
                $script:SwallowNextUp = $true
                return [IntPtr]1
            } elseif ($msg -eq $WM_LBUTTONUP -and $script:SwallowNextUp) {
                $script:SwallowNextUp = $false
                return [IntPtr]1
            }
        }
    } catch {
        Write-DebugLog "hook EXCEPTION: $($_.Exception.Message)"
    }
    return [Native]::CallNextHookEx([IntPtr]::Zero, $nCode, $wParam, $lParam)
}
$script:MouseHookId = [Native]::SetWindowsHookEx($WH_MOUSE_LL, [LowLevelMouseProc]$script:MouseHookCallback, [IntPtr]::Zero, 0)
Write-DebugLog "MouseHookId = $($script:MouseHookId)  (zero means install FAILED)"
if ($script:MouseHookId -eq [IntPtr]::Zero) {
    [System.Windows.Forms.MessageBox]::Show("Failed to install mouse hook - pin mode will not work.", "InYourFaceHello", "OK", "Error") | Out-Null
}

# ---------------- Overlay tracking + dead-window cleanup ----------------
# Never touches $Settings.PinnedWindows: closing a pinned window must not
# forget it - only an explicit unpin should.
$TrackTimer = New-Object System.Windows.Forms.Timer
$TrackTimer.Interval = 200
$TrackTimer.Add_Tick({
    foreach ($key in @($PinnedMap.Keys)) {
        $entry = $PinnedMap[$key]
        if (-not [Native]::IsWindow($entry.Hwnd)) {
            if ($entry.Overlay) { $entry.Overlay.Close(); $entry.Overlay.Dispose() }
            $PinnedMap.Remove($key)
            continue
        }
        if ($entry.Overlay) {
            $rect = New-Object RECT
            [Native]::GetWindowRect($entry.Hwnd, [ref]$rect) | Out-Null
            $pt = Get-GlyphPosition $rect
            $visible = [Native]::IsWindowVisible($entry.Hwnd)
            if ($visible -ne $entry.Overlay.Visible) { $entry.Overlay.Visible = $visible }
            # SWP_NOSIZE|SWP_NOACTIVATE, re-asserting topmost so the glyph stays above its window
            [Native]::SetWindowPos($entry.Overlay.Handle, [IntPtr]-1, $pt.X, $pt.Y, 0, 0, 0x0001 -bor 0x0010) | Out-Null
        }
    }
})

# ---------------- Start with Windows ----------------
$RunKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
function Set-StartWithWindows([bool]$enable) {
    if ($enable) {
        $cmd = "powershell.exe -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$PSCommandPath`""
        Set-ItemProperty -Path $RunKey -Name "InYourFaceHello" -Value $cmd -Force
    } else {
        Remove-ItemProperty -Path $RunKey -Name "InYourFaceHello" -ErrorAction SilentlyContinue
    }
    $Settings.StartWithWindows = $enable
    Save-Settings
}

# ---------------- Tray icon + menu ----------------
$TrayForm = New-Object System.Windows.Forms.Form
$TrayForm.WindowState = 'Minimized'
$TrayForm.ShowInTaskbar = $false
$TrayForm.Visible = $false

$TrayIcon = New-Object System.Windows.Forms.NotifyIcon
$TrayIcon.Icon = $TrayPinIcon
$TrayIcon.Text = "InYourFaceHello"
$TrayIcon.Visible = $true

$Menu = New-Object System.Windows.Forms.ContextMenuStrip
$PinItem      = $Menu.Items.Add("Pin a Window")
$StartItem    = $Menu.Items.Add("Start with Windows")
$StartItem.CheckOnClick = $true
$StartItem.Checked = $Settings.StartWithWindows
$UnpinAllItem = $Menu.Items.Add("Unpin All")
$Menu.Items.Add("-") | Out-Null
$ExitItem     = $Menu.Items.Add("Exit")
$TrayIcon.ContextMenuStrip = $Menu

$PinItem.Add_Click({ Enter-PinMode })
$StartItem.Add_Click({ Set-StartWithWindows $StartItem.Checked })
$UnpinAllItem.Add_Click({ foreach ($key in @($PinnedMap.Keys)) { Unpin-Window $key } })

# Currently-pinned windows are listed at the top of the menu, above a divider.
# Rebuilt every time the menu opens, since pins come and go. Clicking one
# unpins it (they show as checked, so unchecking == unpinning).
function Update-PinnedMenuItems {
    try {
        # Remove only - do NOT dispose. Disposing an item while the menu is
        # opening (in particular the one just clicked) takes the whole app down.
        foreach ($item in @($Menu.Items)) {
            if ($item.Tag -eq 'IyfhDynamic') { $Menu.Items.Remove($item) }
        }
        $index = 0
        foreach ($key in @($PinnedMap.Keys)) {
            $entry = $PinnedMap[$key]
            if (-not $entry -or -not [Native]::IsWindow($entry.Hwnd)) { continue }
            $title = Get-WindowTitle $entry.Hwnd
            $label = if ([string]::IsNullOrWhiteSpace($title)) { $entry.Process } else { "$($entry.Process)  -  $title" }
            if ($label.Length -gt 60) { $label = $label.Substring(0, 57) + "..." }

            $mi = New-Object System.Windows.Forms.ToolStripMenuItem($label)
            $mi.Tag         = 'IyfhDynamic'
            $mi.Checked     = $true
            $mi.ToolTipText = "Click to unpin"
            $capturedKey    = $key
            $mi.Add_Click({ Unpin-Window $capturedKey }.GetNewClosure())
            $Menu.Items.Insert($index, $mi)
            $index++
        }
        if ($index -gt 0) {
            $sep = New-Object System.Windows.Forms.ToolStripSeparator
            $sep.Tag = 'IyfhDynamic'
            $Menu.Items.Insert($index, $sep)
        }
    } catch {
        Write-DebugLog "Update-PinnedMenuItems EXCEPTION: $($_.Exception.Message)"
    }
}

$Menu.Add_Opening({ Update-PinnedMenuItems })

# MouseUp, not MouseClick: NotifyIcon's MouseClick does not reliably fire for a
# left-click on the tray icon on Windows 11 (verified - the right-click menu
# path worked while MouseClick never fired).
$TrayIcon.Add_MouseUp({
    param($s,$e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
        Write-DebugLog "tray left-click"
        Enter-PinMode
    }
})

function Stop-InYourFaceHello {
    if ($script:PinModeOn) { Exit-PinMode }
    Restore-Cursors
    foreach ($key in @($PinnedMap.Keys)) { Unpin-Window $key }
    $TrayIcon.Visible = $false
    $TrackTimer.Stop()
    if ($script:MouseHookId -and $script:MouseHookId -ne [IntPtr]::Zero) {
        [Native]::UnhookWindowsHookEx($script:MouseHookId) | Out-Null
    }
}

$ExitItem.Add_Click({
    Stop-InYourFaceHello
    [System.Windows.Forms.Application]::Exit()
})

# Also clean up on a graceful window close (WM_CLOSE), so the tray icon is
# removed rather than being left as a stale ghost that clicks fall through.
$TrayForm.Add_FormClosing({ Stop-InYourFaceHello })

# ---------------- Restore previously pinned windows ----------------
function Restore-PinnedWindows {
    if (-not $Settings.PinnedWindows -or $Settings.PinnedWindows.Count -eq 0) { return }
    $callback = {
        param($hwnd, $lparam)
        if (-not [Native]::IsWindowVisible($hwnd)) { return $true }
        if ([Native]::GetAncestor($hwnd, 2) -ne $hwnd) { return $true }
        $proc = Get-WindowProcessName $hwnd
        if ($proc -and ($Settings.PinnedWindows -contains $proc)) {
            # No raise here - yanking focus for every remembered window at
            # startup would be obnoxious.
            Pin-Window $hwnd $false $false
        }
        return $true
    }
    [Native]::EnumWindows([EnumWindowsProc]$callback, [IntPtr]::Zero) | Out-Null
}

# ---------------- Auto-pin newly created windows of a remembered process ----------------
$EVENT_OBJECT_SHOW       = 0x8002
$WINEVENT_OUTOFCONTEXT   = 0x0000
$WINEVENT_SKIPOWNPROCESS = 0x0002

# Must stay rooted in a variable for the life of the process, or the GC can
# collect the delegate out from under the native callback.
$script:WinEventCallback = {
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $idEventThread, $dwmsEventTime)
    if ($idObject -ne 0 -or $idChild -ne 0 -or $hwnd -eq [IntPtr]::Zero) { return }
    if (-not $Settings.PinnedWindows -or $Settings.PinnedWindows.Count -eq 0) { return }
    if (-not [Native]::IsWindowVisible($hwnd)) { return }
    if ([Native]::GetAncestor($hwnd, 2) -ne $hwnd) { return }

    # Matching on process image name means there is no title-settling race to
    # work around - the process identity is known immediately.
    $proc = Get-WindowProcessName $hwnd
    if ($proc -and ($Settings.PinnedWindows -contains $proc)) {
        # A remembered window just appeared - raise it, which is the whole
        # point for things like the Windows Hello prompt that open behind.
        Pin-Window $hwnd $false $true
    }
}

$script:WinEventHook = [Native]::SetWinEventHook(
    $EVENT_OBJECT_SHOW, $EVENT_OBJECT_SHOW, [IntPtr]::Zero,
    [WinEventDelegate]$script:WinEventCallback,
    0, 0, ($WINEVENT_OUTOFCONTEXT -bor $WINEVENT_SKIPOWNPROCESS))

[System.Windows.Forms.Application]::add_ThreadException({
    param($s, $e)
    Write-DebugLog "THREAD EXCEPTION: $($e.Exception.Message) | $($e.Exception.StackTrace)"
})

Restore-PinnedWindows
$TrackTimer.Start()

[System.Windows.Forms.Application]::Run($TrayForm)

# Safety net: never leave the system cursor overridden.
Restore-Cursors
if ($script:WinEventHook -and $script:WinEventHook -ne [IntPtr]::Zero) {
    [Native]::UnhookWinEvent($script:WinEventHook) | Out-Null
}
if ($script:MouseHookId -and $script:MouseHookId -ne [IntPtr]::Zero) {
    [Native]::UnhookWindowsHookEx($script:MouseHookId) | Out-Null
}
