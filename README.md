# InYourFaceHello

Forces the Windows Hello / Credential UI prompt to the front and gives it keyboard focus the moment it appears. Pure PowerShell, no dependencies.

## Why

The Windows Hello (fingerprint/PIN) prompt runs as `CredentialUIBroker.exe` and often pops up behind other windows, so you can end up staring at nothing while a prompt you can't see is waiting for input. This watches for that window and raises it automatically.

## Usage

```
powershell -File InYourFaceHello.ps1
```

It relaunches itself elevated (one UAC prompt) if needed, then runs headless — no window, no tray icon — watching for the target window and raising it whenever it appears. Ctrl+C, or close the console, to stop it.

To watch for a different process's window instead, pass `-ProcessName`:

```
powershell -File InYourFaceHello.ps1 -ProcessName SomeOtherProcess
```

## Why elevation is required

`CredentialUIBroker` runs at a higher UAC integrity level than a normal process. Windows' UIPI blocks a lower-integrity process from touching its window at all (`SetForegroundWindow` fails silently, `SetWindowPos` fails with `ACCESS_DENIED`), so the script needs to run elevated to be able to raise it.
