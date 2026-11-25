# Ronic JustTerminal: Windows

Native app for Windows 10 (1809+) and 11, x64, written in **C# / .NET 10 / WinForms** with **WebView2** and **ConPTY**. It does not reimplement the UI: it loads `/shared-web` (copied to `web\` next to the `.exe`) and follows the same contract as the macOS app ([`docs/BRIDGE.md`](../docs/BRIDGE.md)).

## Files

| File | Responsibility | macOS counterpart |
|---|---|---|
| `Program.cs` | Entry point, single instance (launching again just shows the window), PerMonitorV2 DPI | `main.swift` |
| `MainForm.cs` | Window with a dark title bar, Acrylic glass, transparent WebView2, **system tray** (closing = keep running in the background) | `TerminalWindowController.swift` + `StatusBarController.swift` |
| `TerminalBridge.cs` | Page messages, sessions, batched output, folders, history | `TerminalBridge.swift` |
| `ConPtySession.cs` | Pseudo console, reading on its own thread, flow control | `PTYSession.swift` |
| `ShellProfile.cs` | PowerShell 7, Windows PowerShell, cmd, WSL and Git Bash, with a prompt integration (current directory) | `ShellProfile.swift` + `ShellIntegration.swift` |
| `SettingsStore.cs` | `%APPDATA%\RonicJustTerminal\settings.json`, `history.json` and `window.json` | `SettingsStore.swift` |
| `Native.cs` | P/Invoke: ConPTY (bundled `conpty.dll`, falling back to kernel32) and DWM (dark mode, Acrylic) | — |

## ConPTY

The app ships the **Microsoft.Windows.Console.ConPTY** NuGet package, the same pseudo console Windows Terminal uses:

```
RonicJustTerminal.exe
conpty.dll
x64\OpenConsole.exe
arm64\OpenConsole.exe
WebView2Loader.dll
web\
```

The ConPTY built into Windows 10 drops the OSC sequences the sidebar relies on (current directory, prompt marks). The bundled one passes them through. If the bundled files are missing, `Native.cs` falls back to the system ConPTY (kernel32): the terminal still works, but the sidebar may not follow `cd` on Windows 10.

## Glass and opacity

* **100% opacity** (default): solid window, title bar in the terminal color.
* **Below 100%**: on Windows 11 22H2+, the app enables the **Acrylic** backdrop (`DWMWA_SYSTEMBACKDROP_TYPE`) and extends the frame into the client area. The transparent WebView2 lets the glass show through. On Windows 10 the window stays solid and only the dark layer gets lighter.

## Build

Works on Windows, macOS or Linux, thanks to `EnableWindowsTargeting`:

```bash
# from the repository root
./scripts/package-windows.sh          # → dist/RonicJustTerminal-Windows.zip
```

To run on Windows during development:

```powershell
cd windows\RonicJustTerminal
dotnet run            # finds ..\..\shared-web on its own
$env:JT_DEVTOOLS=1    # (optional) enables F12 / DevTools in WebView2
```

Requirements to run: Windows 10 1809 or later (ConPTY) and the **Microsoft Edge WebView2 Runtime**. It ships with Windows 11 and up-to-date Windows 10; if it is missing, the app offers the download link.
