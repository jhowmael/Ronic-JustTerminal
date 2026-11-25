import AppKit
import WebKit

/// What the bridge needs from the window (implemented by TerminalWindowController).
protocol TerminalBridgeDelegate: AnyObject {
    func bridgeDidUpdateDragRegions(_ rects: [NSRect])
    func bridgeDidChangeOpacity(_ opacity: Double)
    func bridgeLastTabClosed()
    func bridgeTabsChanged(count: Int, title: String)
}

/// Bridge between the UI (shared-web, inside the WKWebView) and the PTY sessions.
/// Message contract: docs/BRIDGE.md.
final class TerminalBridge: NSObject, WKScriptMessageHandler {
    weak var webView: WKWebView?
    weak var delegate: TerminalBridgeDelegate?

    private(set) var tabCount = 0
    private var sessions: [Int: PTYSession] = [:]
    private let profiles = ShellProfile.detect()
    private var pageReady = false
    private var queuedScripts: [String] = []

    // PTY output is batched: several chunks read between two main-thread cycles become a
    // single evaluateJavaScript call (less IPC with the web process).
    private let pendingLock = NSLock()
    private var pending: [Int: Data] = [:]
    private var pendingOrder: [Int] = []
    private var flushScheduled = false

    var sessionCount: Int { sessions.count }

    // MARK: - Messages from the page

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? String,
              let data = body.data(using: .utf8),
              let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = msg["t"] as? String else { return }
        let id = (msg["id"] as? NSNumber)?.intValue ?? 0

        switch type {
        case "ready":
            pageReady = true
            send([
                "t": "init",
                "platform": "mac",
                "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                "settings": SettingsStore.shared.values,
                "profiles": profiles.map { p -> [String: Any] in var j = p.json; j["home"] = Self.home; return j },
                "home": Self.home,
                "places": Self.places(),
                "renderer": ProcessInfo.processInfo.environment["JT_RENDERER"] ?? "webgl",
                "history": SettingsStore.shared.history,
            ])
            queuedScripts.forEach { evaluate($0) }
            queuedScripts.removeAll()

        case "spawn":
            let cols = (msg["cols"] as? NSNumber)?.intValue ?? 80
            let rows = (msg["rows"] as? NSNumber)?.intValue ?? 24
            spawn(id: id, profileID: msg["profile"] as? String ?? "", cwd: msg["cwd"] as? String ?? "", cols: cols, rows: rows)

        case "input":
            guard let text = msg["data"] as? String, let session = sessions[id] else { return }
            if msg["binary"] as? Bool == true {
                session.write(Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }))
            } else {
                session.write(Data(text.utf8))
            }

        case "resize":
            let cols = (msg["cols"] as? NSNumber)?.intValue ?? 80
            let rows = (msg["rows"] as? NSNumber)?.intValue ?? 24
            sessions[id]?.resize(cols: cols, rows: rows)

        case "ack":
            sessions[id]?.ack((msg["bytes"] as? NSNumber)?.intValue ?? 0)

        case "run":
            // Folder click in the sidebar: types the "cd" only if the shell is at its prompt.
            guard let text = msg["text"] as? String, let session = sessions[id] else { return }
            if session.isBusy {
                send(["t": "toast", "text": "Há um programa rodando nesta aba. Saia dele para navegar pelas pastas."])
            } else {
                session.write(Data(text.utf8))
            }

        case "listDir":
            let reqId = (msg["reqId"] as? NSNumber)?.intValue ?? 0
            let path = msg["path"] as? String ?? ""
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Self.listDirectory(path)
                DispatchQueue.main.async {
                    self.send(["t": "dirList", "reqId": reqId, "path": path, "entries": result.entries, "error": result.error])
                }
            }

        case "reveal":
            if let path = msg["path"] as? String {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }

        case "saveHistory":
            SettingsStore.shared.replaceHistory(with: msg["items"] as? [Any] ?? [])

        case "kill":
            sessions.removeValue(forKey: id)?.terminate()

        case "saveSettings":
            if let settings = msg["settings"] as? [String: Any] {
                SettingsStore.shared.replace(with: settings)
                delegate?.bridgeDidChangeOpacity(SettingsStore.shared.opacity)
            }

        case "opacity":
            delegate?.bridgeDidChangeOpacity((msg["value"] as? NSNumber)?.doubleValue ?? 1)

        case "copy":
            if let text = msg["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }

        case "paste":
            send(["t": "pasteText", "text": NSPasteboard.general.string(forType: .string) ?? ""])

        case "openUrl":
            if let s = msg["url"] as? String, let url = URL(string: s), ["http", "https", "mailto", "file"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
            }

        case "dragRegions":
            let rects = (msg["rects"] as? [[String: Any]] ?? []).map { r in
                NSRect(x: (r["x"] as? NSNumber)?.doubleValue ?? 0, y: (r["y"] as? NSNumber)?.doubleValue ?? 0,
                       width: (r["w"] as? NSNumber)?.doubleValue ?? 0, height: (r["h"] as? NSNumber)?.doubleValue ?? 0)
            }
            delegate?.bridgeDidUpdateDragRegions(rects)

        case "tabs":
            tabCount = (msg["count"] as? NSNumber)?.intValue ?? 0
            delegate?.bridgeTabsChanged(count: tabCount, title: msg["title"] as? String ?? "")

        case "lastTabClosed":
            tabCount = 0
            delegate?.bridgeLastTabClosed()

        default:
            NSLog("Ronic JustTerminal: unknown message \(type)")
        }
    }

    // MARK: - Sessions

    private func spawn(id: Int, profileID: String, cwd: String, cols: Int, rows: Int) {
        let profile = profiles.first { $0.id == profileID } ?? profiles[0]
        let session = PTYSession(id: id)
        session.onData = { [weak self] data in self?.enqueueOutput(id: id, data: data) }
        session.onCwdChange = { [weak self] path in
            DispatchQueue.main.async { self?.send(["t": "cwd", "id": id, "path": path]) }
        }
        session.onExit = { [weak self] code in
            guard let self else { return }
            self.flushOutput()
            self.sessions.removeValue(forKey: id)
            self.send(["t": "exit", "id": id, "code": Int(code)])
        }
        do {
            var isDir: ObjCBool = false
            let dir = !cwd.isEmpty && FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir) && isDir.boolValue
                ? cwd : Self.home
            var extraEnv = SettingsStore.shared.fullPathPrompt ? ShellIntegration.environment(for: profile) : [:]
            if ProcessInfo.processInfo.environment["JT_DATA_DIR"] != nil {
                // Self-test / screenshots: nothing goes to the real ~/.zsh_history or ~/.bash_history.
                let hist = SettingsStore.shared.dataDirectory.appendingPathComponent("shell_history").path
                extraEnv["HISTFILE"] = hist
                extraEnv["JT_HISTFILE"] = hist
                extraEnv["CLICOLOR"] = "1"
            }
            try session.start(profile: profile, cols: cols, rows: rows, cwd: dir, extraEnv: extraEnv)
            sessions[id] = session
        } catch {
            send(["t": "spawnError", "id": id, "message": error.localizedDescription])
        }
    }

    #if DEBUG
    /// Self-test only: writes to the most recent session.
    func debugWrite(_ text: String) {
        sessions.max { $0.key < $1.key }?.value.write(Data(text.utf8))
    }
    #endif

    // MARK: - Pastas (barra lateral)

    /// Start folder. JT_DEMO_HOME (screenshots) swaps home for another folder so the real
    /// home contents are not exposed.
    static let home = ProcessInfo.processInfo.environment["JT_DEMO_HOME"] ?? NSHomeDirectory()

    /// Shortcuts for the "Places" section, with Finder's localized names (Desktop, Documents…).
    private static func places() -> [[String: Any]] {
        if ProcessInfo.processInfo.environment["JT_DEMO_HOME"] != nil {
            let demo = Self.home
            let subs = ["docs", "macos", "shared-web", "windows"].map { demo + "/" + $0 }
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { ["name": ($0 as NSString).lastPathComponent, "path": $0, "icon": "dir"] as [String: Any] }
            return [["name": (demo as NSString).lastPathComponent, "path": demo, "icon": "home"]] + subs
                + [["name": "Macintosh HD", "path": "/", "icon": "disk"]]
        }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var list: [[String: Any]] = [["name": NSUserName(), "path": home, "icon": "home"]]
        for (dir, icon) in [(FileManager.SearchPathDirectory.desktopDirectory, "dir"), (.documentDirectory, "dir"),
                            (.downloadsDirectory, "dir"), (.applicationDirectory, "dir")] {
            let domain: FileManager.SearchPathDomainMask = dir == .applicationDirectory ? .localDomainMask : .userDomainMask
            if let url = fm.urls(for: dir, in: domain).first, fm.fileExists(atPath: url.path) {
                list.append(["name": fm.displayName(atPath: url.path), "path": url.path, "icon": icon])
            }
        }
        let volume = (try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        list.append(["name": volume ?? "Disco", "path": "/", "icon": "disk"])
        return list
    }

    /// Folder contents: folders first, then files, in "natural" order (like Finder).
    private static func listDirectory(_ path: String) -> (entries: [[String: Any]], error: String) {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isHiddenKey, .isSymbolicLinkKey, .isPackageKey]
        let items: [URL]
        do {
            items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: [])
        } catch let error as NSError {
            let denied = error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError
            return ([], denied ? "sem permissão para ler esta pasta" : "não foi possível ler esta pasta")
        }
        var entries: [(name: String, dir: Bool, hidden: Bool)] = []
        for item in items.prefix(5000) {
            let v = try? item.resourceValues(forKeys: Set(keys))
            var isDir = v?.isDirectory ?? false
            if v?.isSymbolicLink == true {   // a link to a folder counts as a folder
                var target: ObjCBool = false
                isDir = FileManager.default.fileExists(atPath: item.path, isDirectory: &target) && target.boolValue
            }
            if v?.isPackage == true { isDir = false }   // .app and other bundles show up as files, like in Finder
            let name = item.lastPathComponent
            entries.append((name, isDir, (v?.isHidden ?? false) || name.hasPrefix(".")))
        }
        entries.sort { a, b in
            if a.dir != b.dir { return a.dir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return (entries.map { ["n": $0.name, "d": $0.dir, "h": $0.hidden] }, "")
    }

    /// Terminates every shell (app quitting).
    func terminateAll() {
        sessions.values.forEach { $0.terminate() }
        sessions.removeAll()
    }

    // MARK: - Output to the page

    private func enqueueOutput(id: Int, data: Data) {
        pendingLock.lock()
        if pending[id] == nil {
            pending[id] = data
            pendingOrder.append(id)
        } else {
            pending[id]!.append(data)
        }
        let schedule = !flushScheduled
        flushScheduled = true
        pendingLock.unlock()
        if schedule { DispatchQueue.main.async { self.flushOutput() } }
    }

    private func flushOutput() {
        pendingLock.lock()
        let batch = pending
        let order = pendingOrder
        pending.removeAll(keepingCapacity: true)
        pendingOrder.removeAll(keepingCapacity: true)
        flushScheduled = false
        pendingLock.unlock()
        guard !order.isEmpty else { return }

        var script = ""
        for id in order {
            guard let data = batch[id] else { continue }
            script += "JT.data(\(id),'\(data.base64EncodedString())');"
        }
        evaluate(script + "void 0")
    }

    /// Sends a JSON message to the page (JT.recv).
    func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        evaluate("JT.recv(\(json));void 0")
    }

    /// Runs a UI command (from the native menu or the menu bar icon).
    func command(_ name: String, arg: Any? = nil) {
        var msg: [String: Any] = ["t": "cmd", "name": name]
        if let arg { msg["arg"] = arg }
        send(msg)
    }

    private func evaluate(_ script: String) {
        guard pageReady, let webView else {
            queuedScripts.append(script)
            return
        }
        webView.evaluateJavaScript(script, completionHandler: nil)
    }
}
