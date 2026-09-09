<#
InYourFaceHello - forces the Windows Hello / Credential UI prompt to the
front and gives it keyboard focus the moment it appears.

Why: that prompt (process CredentialUIBroker.exe) often pops up behind
other windows, so a fingerprint/PIN prompt you can't see just sits there
waiting. This watches for it and raises it automatically.

Usage:
  powershell -File InYourFaceHello.ps1

Requires elevation: CredentialUIBroker runs at a higher UAC integrity
level (High, S-1-16-8202-ish) than a normal process (Medium), and
UIPI blocks a lower-integrity process from touching its window at all
(SetWindowPos/SetForegroundWindow fail with ACCESS_DENIED). The script
relaunches itself elevated (one UAC prompt) if it isn't already.

Runs headless - no window, no tray icon. Ctrl+C, or close the console
window, to stop it.
#>

param(
    # Process image name (no .exe) of the window to force to the front.
    [string]$ProcessName = "CredentialUIBroker"
)

# ---------------- Elevate if needed ----------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
if (-not $isAdmin) {
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList @(
        "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"", "-ProcessName", "`"$ProcessName`""
    )
    exit
}

Add-Type @"
using System;
using System.Runtime.InteropServices;

public struct POINT { public int X; public int Y; }
public struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; }

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);
public delegate void WinEventDelegate(IntPtr hWinEventHook, uint eventType, IntPtr hwnd, int idObject, int idChild, uint idEventThread, uint dwmsEventTime);

public static class Native {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern IntPtr SetWinEventHook(uint eventMin, uint eventMax, IntPtr hmodWinEventProc, WinEventDelegate lpfnWinEventProc, uint idProcess, uint idThread, uint dwFlags);
    [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")] public static extern bool TranslateMessage(ref MSG lpMsg);
    [DllImport("user32.dll")] public static extern IntPtr DispatchMessage(ref MSG lpMsg);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
}
"@

$EVENT_OBJECT_SHOW = 0x8002
$WINEVENT_OUTOFCONTEXT = 0x0000
$WINEVENT_SKIPOWNPROCESS = 0x0002
$SW_RESTORE = 9

function Test-IsTargetWindow([IntPtr]$hwnd) {
    if (-not [Native]::IsWindowVisible($hwnd)) { return $false }
    $procId = 0
    [Native]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
    if ($procId -eq 0) { return $false }
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    return ($proc -and $proc.ProcessName -eq $ProcessName)
}

function Bring-ToFront([IntPtr]$hwnd) {
    if ([Native]::IsIconic($hwnd)) { [Native]::ShowWindow($hwnd, $SW_RESTORE) | Out-Null }
    $dummy = 0
    $fgThread  = [Native]::GetWindowThreadProcessId([Native]::GetForegroundWindow(), [ref]$dummy)
    $curThread = [Native]::GetCurrentThreadId()
    $attached = $false
    if ($fgThread -ne 0 -and $fgThread -ne $curThread) { $attached = [Native]::AttachThreadInput($curThread, $fgThread, $true) }
    [Native]::BringWindowToTop($hwnd) | Out-Null
    $ok = [Native]::SetForegroundWindow($hwnd)
    if ($attached) { [Native]::AttachThreadInput($curThread, $fgThread, $false) | Out-Null }
    Write-Host "Raised $ProcessName window (hwnd=$hwnd, SetForegroundWindow=$ok)"
}

# Catch it if it's already open when we start.
$enumProc = {
    param($hwnd, $lparam)
    if (Test-IsTargetWindow $hwnd) { Bring-ToFront $hwnd }
    return $true
} -as [EnumWindowsProc]
[Native]::EnumWindows($enumProc, [IntPtr]::Zero) | Out-Null

# Then watch for it appearing from here on.
$winEventProc = {
    param($hWinEventHook, $eventType, $hwnd, $idObject, $idChild, $idEventThread, $dwmsEventTime)
    if ($idObject -ne 0 -or $idChild -ne 0) { return }
    if (Test-IsTargetWindow $hwnd) { Bring-ToFront $hwnd }
} -as [WinEventDelegate]

$hook = [Native]::SetWinEventHook($EVENT_OBJECT_SHOW, $EVENT_OBJECT_SHOW, [IntPtr]::Zero, $winEventProc, 0, 0, ($WINEVENT_OUTOFCONTEXT -bor $WINEVENT_SKIPOWNPROCESS))

Write-Host "Watching for '$ProcessName' windows. Ctrl+C to stop."

$msg = New-Object MSG
while ([Native]::GetMessage([ref]$msg, [IntPtr]::Zero, 0, 0) -gt 0) {
    [Native]::TranslateMessage([ref]$msg) | Out-Null
    [Native]::DispatchMessage([ref]$msg) | Out-Null
}
