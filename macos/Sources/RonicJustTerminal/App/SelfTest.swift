#if DEBUG
import AppKit
import WebKit

/// Development tools (DEBUG builds only). Always use with JT_DATA_DIR so the real settings
/// and history are left untouched.
///
/// Self-test (`make mac-test`):
///   JT_SELFTEST=<out> JT_DATA_DIR=<data> swift run --package-path macos RonicJustTerminal
///   Types commands into a real shell, navigates through the sidebar, opens a second tab and
///   writes the UI state to selftest-*.json.
///
/// README screenshots (`make screenshots`):
///   JT_SHOTS=<out> JT_DATA_DIR=<data> JT_DEMO_HOME=<repo> JT_RENDERER=dom swift run …
///   Runs a sample session and saves shot-*.png (WKWebView snapshots don't include WebGL, hence
///   the DOM renderer).
enum SelfTest {
    static func runIfRequested(bridge: TerminalBridge, webView: WKWebView) {
        let env = ProcessInfo.processInfo.environment
        if let out = env["JT_SELFTEST"] { selfTest(out: out, bridge: bridge, webView: webView) }
        if let out = env["JT_SHOTS"] { screenshots(out: out, bridge: bridge, webView: webView) }
    }

    private static func js(_ webView: WKWebView, _ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }

    private static func selfTest(out: String, bridge: TerminalBridge, webView: WKWebView) {
        let main = DispatchQueue.main
        func save(_ name: String) {
            let probe = """
            JSON.stringify({
              crumbs: [...document.querySelectorAll('.crumbs button')].map(b => b.textContent),
              current: document.querySelector('#sb-folders .node.current')?.dataset.path || null,
              places: [...document.querySelectorAll('#sb-places .name')].map(n => n.textContent),
              treeRows: document.querySelectorAll('#sb-folders .node').length,
              history: [...document.querySelectorAll('.history li code')].slice(0, 5).map(c => c.textContent),
              focus: (document.activeElement && (document.activeElement.className || document.activeElement.tagName)) || null,
              git: JT.git(),
              gitHead: document.querySelector('#git-head').innerText.replace(/\\n+/g, ' | '),
              search: JT.search(),
              overflowPx: (() => { const p = document.querySelector('.pane.active'); const sc = p.querySelector('.xterm-screen').getBoundingClientRect();
                const sb = p.querySelector('.xterm-scrollable-element > .scrollbar.vertical'); return Math.round(sc.right - (sb ? sb.getBoundingClientRect().left : p.getBoundingClientRect().right)); })(),
              tabs: JT.dump().map(t => ({ title: t.title, active: t.active, tail: t.text.split('\\n').slice(-4) }))
            })
            """
            webView.evaluateJavaScript(probe) { result, error in
                let text = (result as? String) ?? "erro: \(String(describing: error))"
                try? text.write(to: URL(fileURLWithPath: out).appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        main.asyncAfter(deadline: .now() + 2.0) { js(webView, "JT.type('cd /usr/bin\\r')") }
        main.asyncAfter(deadline: .now() + 3.0) { js(webView, "JT.type('echo JT_OK $TERM_PROGRAM; printf \"ação 日本 🙂\\\\n\"\\r')") }
        main.asyncAfter(deadline: .now() + 4.0) { save("selftest-1.json") }
        main.asyncAfter(deadline: .now() + 4.2) { js(webView, "document.querySelector('#sb-places .node[data-path=\"/\"]').click()") }
        main.asyncAfter(deadline: .now() + 5.5) { save("selftest-2.json") }
        main.asyncAfter(deadline: .now() + 5.7) { bridge.command("newTab") }
        main.asyncAfter(deadline: .now() + 7.0) { save("selftest-3.json") }
        // Ctrl+C must stop a long-running foreground program, like in any terminal.
        // JT_CTRLC_CMD: program to start (default: an idle node process); JT_CTRLC_WAIT: seconds
        // before pressing Ctrl+C; JT_CTRLC_HIDE=1 hides the window while the program runs.
        let env = ProcessInfo.processInfo.environment
        let cmd = env["JT_CTRLC_CMD"] ?? #"node -e "setInterval(()=>{},1000)""#
        let wait = Double(env["JT_CTRLC_WAIT"] ?? "1.5") ?? 1.5
        main.asyncAfter(deadline: .now() + 7.5) { js(webView, "JT.type(\(jsString(cmd + "\r")))") }
        if env["JT_CTRLC_HIDE"] == "1" {
            // Same as the red button (hide) and reopening from the menu bar icon (show).
            main.asyncAfter(deadline: .now() + 8.0) { NSApp.sendAction(#selector(AppDelegate.hideWindow(_:)), to: nil, from: nil) }
            main.asyncAfter(deadline: .now() + 7.5 + wait - 1.0) { NSApp.sendAction(#selector(AppDelegate.showWindow(_:)), to: nil, from: nil) }
        }
        if env["JT_CTRLC_CLICK_SIDEBAR"] == "1" {
            // A real mouse click on an empty spot of the sidebar (history area) before Ctrl+C.
            main.asyncAfter(deadline: .now() + 7.5 + wait - 0.7) { click(in: webView, at: NSPoint(x: 120, y: 30)) }
        }
        if env["JT_SELECT_BEFORE"] == "1" {
            main.asyncAfter(deadline: .now() + 7.5 + wait - 0.3) { bridge.command("selectAll") }
        }
        main.asyncAfter(deadline: .now() + 7.5 + wait) {
            if env["JT_CTRLC_KEYBOARD"] == "1" { pressCtrlC(in: webView) } else { js(webView, "JT.type('\\u0003')") }
        }
        main.asyncAfter(deadline: .now() + 7.5 + wait + 3) { js(webView, "JT.type('echo CTRL_C_OK\\r')") }
        if env["JT_GIT_ACTIONS"] == "1" {
            // Git sidebar end to end: stage the first changed file (background), then commit
            // (typed into the terminal).
            let start = 7.5 + wait - 2.5
            main.asyncAfter(deadline: .now() + start) {
                js(webView, "document.querySelector('.file-row[data-group=\"unstaged\"] button[data-act=\"stage\"]').click()")
            }
            main.asyncAfter(deadline: .now() + start + 1.2) {
                js(webView, "document.querySelector('#git-message').value = 'test: commit from the Git sidebar'; document.querySelector('#git-commit').click()")
            }
        }
        if let query = env["JT_SEARCH"] {
            // Types into the terminal search field, like the user would.
            main.asyncAfter(deadline: .now() + 7.5 + wait - 0.6) {
                js(webView, "(() => { const i = document.querySelector('#search-input'); i.value = \(jsString(query)); i.dispatchEvent(new Event('input')); })()")
            }
        }
        main.asyncAfter(deadline: .now() + 7.5 + wait + 4) { save("selftest-4.json") }
        main.asyncAfter(deadline: .now() + 7.5 + wait + 4.5) { finish(bridge) }
    }

    private static func screenshots(out: String, bridge: TerminalBridge, webView: WKWebView) {
        let main = DispatchQueue.main
        var t = 1.5
        func at(_ delay: Double, _ block: @escaping () -> Void) { t += delay; main.asyncAfter(deadline: .now() + t, execute: block) }
        func type(_ text: String) { at(0.9) { js(webView, "JT.type(\(jsString(text + "\r")))") } }
        func shot(_ name: String) {
            at(1.2) {
                let config = WKSnapshotConfiguration()
                config.afterScreenUpdates = true
                config.snapshotWidth = NSNumber(value: Double(webView.bounds.width * 2))   // 2x, sharp on Retina displays
                webView.takeSnapshot(with: config) { image, _ in
                    guard let image, let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
                    let rep = NSBitmapImageRep(cgImage: cg)
                    try? rep.representation(using: .png, properties: [:])?
                        .write(to: URL(fileURLWithPath: out).appendingPathComponent("\(name).png"))
                }
            }
        }

        at(0) { webView.window?.setContentSize(NSSize(width: 1440, height: 820)); webView.window?.center() }
        type("ls")
        type("make help")
        type("ls shared-web")
        at(0.6) { bridge.command("newTab") }
        type("cd macos/Sources/RonicJustTerminal")
        type("ls -1")
        at(0.5) { bridge.command("selectTab", arg: 1) }
        at(0.3) { js(webView, "(() => { const i = document.querySelector('#search-input'); i.value = 'make'; i.dispatchEvent(new Event('input')); })()") }
        shot("shot-main")
        at(0.3) { js(webView, "document.querySelector('.file-row[data-group=\"unstaged\"] .fname').click()") }
        shot("shot-diff")
        at(0.3) { js(webView, "document.querySelector('#diff-close').click(); (() => { const i = document.querySelector('#search-input'); i.value = ''; i.dispatchEvent(new Event('input')); })()") }
        at(0.3) { bridge.command("settings") }
        shot("shot-settings")
        at(0.3) { bridge.command("settings"); bridge.command("selectTab", arg: 2); bridge.command("toggleSidebar"); bridge.command("toggleGit") }
        shot("shot-minimal")
        at(0.3) { bridge.command("toggleSidebar"); bridge.command("toggleGit") }
        at(1.0) { finish(bridge) }
    }

    /// A real Ctrl+C key press, delivered through NSApp like a physical key (menu key equivalents,
    /// window, WKWebView, xterm.js, PTY).
    private static func pressCtrlC(in webView: WKWebView) {
        guard let window = webView.window else { return }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            // JT_CTRLC_AS_COMMAND=1: deliver it as ⌘C, the way Ronic MacToWindows rewrites Ctrl+C
            // (combine with JT_FAKE_PHYSICAL_CTRL=1 to simulate the physical Control key).
            let asCommand = ProcessInfo.processInfo.environment["JT_CTRLC_AS_COMMAND"] == "1"
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: asCommand ? [.command] : [.control],
                                            timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: window.windowNumber, context: nil,
                                            characters: asCommand ? "c" : "\u{03}", charactersIgnoringModifiers: "c",
                                            isARepeat: false, keyCode: 8) {
                if asCommand && ProcessInfo.processInfo.environment["JT_FAKE_PHYSICAL_CTRL"] != "1" {
                    // A real ⌘C: queued like a physical key, so AppKit routes it (key equivalents,
                    // menu "Copy") with this event as NSApp.currentEvent.
                    NSApp.postEvent(event, atStart: false)
                } else if asCommand {
                    // What NSApp does with a ⌘ key while this window is key: the window's key
                    // equivalents first, then the main menu, then the regular key event. (The
                    // self-test app is launched in the background, so its window may not be key.)
                    print("SELFTEST window key=\(window.isKeyWindow)")
                    if type == .keyDown, window.performKeyEquivalent(with: event) { continue }
                    if type == .keyDown, NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
                    window.sendEvent(event)
                } else {
                    NSApp.sendEvent(event)
                }
            }
        }
    }

    /// A real left click at `point` (window coordinates, origin at the bottom left).
    private static func click(in webView: WKWebView, at point: NSPoint) {
        guard let window = webView.window else { return }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                              timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: 1) {
                NSApp.sendEvent(event)
            }
        }
    }

    private static func jsString(_ s: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: [s])
        return String(data: data, encoding: .utf8)!.dropFirst().dropLast().description
    }

    private static func finish(_ bridge: TerminalBridge) {
        print("SELFTEST sessions=\(bridge.sessionCount) tabs=\(bridge.tabCount)")
        bridge.terminateAll()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }
}
#endif
