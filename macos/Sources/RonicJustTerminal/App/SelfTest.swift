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
        main.asyncAfter(deadline: .now() + 7.5) { finish(bridge) }
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

        at(0) { webView.window?.setContentSize(NSSize(width: 1180, height: 700)); webView.window?.center() }
        type("ls")
        type("make help")
        type("ls shared-web")
        at(0.6) { bridge.command("newTab") }
        type("cd macos/Sources/RonicJustTerminal")
        type("ls -1")
        at(0.5) { bridge.command("selectTab", arg: 1) }
        shot("shot-main")
        at(0.3) { bridge.command("settings") }
        shot("shot-settings")
        at(0.3) { bridge.command("settings"); bridge.command("selectTab", arg: 2); bridge.command("toggleSidebar") }
        shot("shot-minimal")
        at(0.3) { bridge.command("toggleSidebar") }
        at(1.0) { finish(bridge) }
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
