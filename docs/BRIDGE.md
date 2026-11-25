# UI ↔ native app bridge

The UI in `shared-web/` (tabs, sidebar, xterm.js) is identical on macOS and Windows. It knows nothing about PTYs or the operating system and talks to the native app through **JSON messages**. Each native app implements the same contract:

| | macOS | Windows |
|---|---|---|
| Page → native | `webkit.messageHandlers.jt.postMessage(json)` | `chrome.webview.postMessage(json)` |
| Native → page | `evaluateJavaScript("JT.recv(msg)")` / `JT.data(id, b64)` | `PostWebMessageAsJson(msg)` |
| Implementation | `macos/.../Terminal/TerminalBridge.swift` | `windows/RonicJustTerminal/TerminalBridge.cs` |
| PTY | `PTYSession.swift` (`forkpty`) | `ConPtySession.cs` (ConPTY, bundled `conpty.dll` + `OpenConsole.exe`) |

Without a native app (opening `shared-web/index.html` in a browser), the page switches to **demo mode**, with a local echo and a fake file system. Use it to work on the UI.

## Page → native

| `t` | Fields | What it does |
|---|---|---|
| `ready` | | Page loaded. The native side answers with `init`. |
| `spawn` | `id`, `profile`, `cols`, `rows`, `cwd?` | Starts a shell for tab `id`, optionally in a given folder. |
| `input` | `id`, `data`, `binary?` | Typed bytes (UTF-8; with `binary`, each character is one byte). |
| `run` | `id`, `text`, `fallback?`, `cmd?`, `cwd?` | Command typed by a sidebar (`cd`, Git actions). On macOS it is rejected while a program is in the foreground: with `fallback`, the native side answers `runRejected` and the UI runs `cmd` in a new tab in `cwd`. |
| `git` | `reqId`, `id`, `cwd`, `args`, `write?`, `background?` | Runs `git <args>` in `cwd` in the background (Git sidebar reads, stage/unstage/discard, auto-fetch) and answers `gitResult`. Never prompts: no terminal, `GIT_TERMINAL_PROMPT=0`, `GCM_INTERACTIVE=never`; reads use `GIT_OPTIONAL_LOCKS=0`. WSL tabs run the Linux git through `wsl.exe`. |
| `resize` | `id`, `cols`, `rows` | New terminal size. |
| `ack` | `id`, `bytes` | Flow control: bytes already drawn (see below). |
| `kill` | `id` | Tab closed: ends the shell. |
| `listDir` | `reqId`, `id`, `path`, `host` | Contents of a folder, for the tree. |
| `reveal` | `id`, `path`, `host` | Shows the item in Finder / File Explorer. |
| `saveSettings` | `settings` | Saves the settings. The native side only stores them and reads `opacity` (and `fullPathPrompt` on macOS). |
| `saveHistory` | `items` | Saves the command history (`[{cmd, cwd, at, tab, run}]`). |
| `opacity` | `value` | Live preview while dragging the slider (turns the glass on/off). |
| `copy` | `text` | Clipboard. |
| `paste` | | Asks for the clipboard text (`pasteText`). |
| `openUrl` | `url` | Opens in the default browser (http/https/mailto). |
| `tabs` | `count`, `title` | Tab summary, used for the window title and the quit confirmation. |
| `lastTabClosed` | | The last tab was closed: the native side hides the window. |
| `dragRegions` | `rects` | macOS only: empty areas of the tab bar that drag the window. |

## Native → page

| `t` | Fields | What it does |
|---|---|---|
| `init` | `platform`, `version`, `settings`, `profiles`, `home`, `places`, `history`, `windowsBuild?`, `renderer?` | Initial state. |
| `data` | `id`, `b64` | PTY output in base64. xterm.js decodes partial UTF-8 on its own. |
| `exit` | `id`, `code` | The shell exited. |
| `spawnError` | `id`, `message` | The shell could not start. |
| `cwd` | `id`, `path`, `host?` | The current directory changed (macOS: read from the kernel). |
| `dirList` | `reqId`, `path`, `entries[{n,d,h}]`, `error` | Reply to `listDir` (n = name, d = folder, h = hidden). The Git sidebar also lists the `.git` folder to detect a merge/rebase/cherry-pick/revert in progress. |
| `gitResult` | `reqId`, `code`, `out`, `err` | Reply to `git` (`code` 127 = git not found; output capped at 2 MB). |
| `runRejected` | `id`, `cmd`, `cwd` | macOS: a `run` with `fallback` hit a busy tab; the UI runs `cmd` in a new tab instead. |
| `cmd` | `name`, `arg?` | Command from the native menu or the tray: `newTab`, `closeTab`, `nextTab`, `prevTab`, `selectTab`, `renameTab`, `settings`, `toggleSidebar`, `copy`, `paste`, `selectAll`, `clear`, `zoomIn`, `zoomOut`, `zoomReset`. |
| `pasteText` | `text` | Reply to `paste`. |
| `shown` | | The window came back from the background. |
| `fullscreen` | `on` | macOS: entered or left full screen. |
| `toast` | `text` | Short notice in the UI. |

## Current directory (sidebar)

* **macOS:** nothing to configure in the shell. After each output, the app reads the foreground process's directory with `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
* **Windows:** each profile injects a prompt integration for that session only, without touching user files:
  * PowerShell: an `-EncodedCommand` that wraps the `prompt` function (oh-my-posh included) and emits `OSC 9;9;"C:\folder"` and `OSC 133;A/B`.
  * cmd: the `PROMPT` variable gets `$e]9;9;$P$e\` and `OSC 133`.
  * WSL and Git Bash: `PROMPT_COMMAND` emits `OSC 7` (`file://distro/path`).
  * The bundled ConPTY (`conpty.dll` + `OpenConsole.exe`, the same as Windows Terminal) passes these sequences through. The ConPTY built into Windows 10 drops them; the app falls back to it only if the bundled files are missing.
* The page also understands `OSC 7`, `OSC 9;9` and `OSC 133` from any shell that already emits them (fish, starship, custom setups).

## Full-path prompt (macOS)

`ShellIntegration.swift` makes new sessions show the full path in the prompt (`/Users/you/development %`), but only while the prompt is still the macOS default:

* **bash:** `PROMPT_COMMAND` replaces `PS1` if it is still `\h:\W \u\$ ` (from `/etc/bashrc`).
* **zsh:** a private `ZDOTDIR` whose `.zshenv`/`.zprofile`/`.zshrc`/`.zlogin` source the user's own files and then replace `PS1` if it is still `%n@%m %1~ %# ` (from `/etc/zshrc`). `HISTFILE` and `ZDOTDIR` are restored to the user's values.

## Git sidebar

`shared-web/git.js` follows the active tab's current directory. On every prompt (and every 4 s while visible, to catch files changed by an editor) it runs, in the background:

* `git rev-parse --show-toplevel --absolute-git-dir`: is this a repository, and where;
* `git status --porcelain=v2 --branch -z`: branch, upstream, ahead/behind, staged/unstaged/untracked/conflicted files;
* `git for-each-ref refs/heads refs/remotes`: branches with upstream, ahead/behind and last commit date;
* a listing of the `.git` folder: `MERGE_HEAD`, `rebase-merge`/`rebase-apply`, `CHERRY_PICK_HEAD`, `REVERT_HEAD`;
* `git rev-list --walk-reflogs --count refs/stash` and `git remote`.

Stage, unstage, discard and "mark resolved" also run in the background. Commit, push, pull, fetch, switch, merge, rebase, branch creation/deletion and continue/abort are typed into the terminal in the shell's dialect (`&&` for posix shells and cmd, `; if ($?) { … }` for PowerShell 5.1), so the user sees them and Git can prompt there.

## Terminal search

The search field in the tab bar uses xterm.js's search addon (`addon-search`) on the active tab: decorations highlight every match (up to 2000), the active one in green, and `onDidChangeResults` feeds the `current/total` counter. Highlights are refreshed as new output arrives, and switching tabs moves the search to the new active tab.

## Command history

When the user presses Enter, the page reads the text between the end of the prompt and the cursor from the xterm buffer. The end of the prompt comes from `OSC 133;B` when available. Otherwise it is inferred: after an Enter, the last output before the terminal goes quiet is the new prompt, and typing echo never moves that mark. Full-screen programs (vim, less, htop) use the alternate buffer and are ignored.

Each entry stores the tab it was typed in (`tab`) and the app run (`run`). The sidebar shows **This tab** by default and **All** on demand, merging every tab and previous runs.

## Flow control

The native side counts the bytes sent and not yet acknowledged for each session. Above 512 KB, PTY reading pauses; below 128 KB it resumes. The page acknowledges (`ack`) in the `term.write` callback, in 32 KB batches. So `yes` or `cat huge-file` never freezes the window, and the process is naturally throttled to the drawing speed.
