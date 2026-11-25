import AppKit
import WebKit

/// The main window: native glass in the back, the web UI (tabs + xterm.js) on top and a thin
/// layer that turns the empty part of the tab bar into a draggable "title bar".
///
/// Closing the window does NOT end the shells: it is only hidden and the app stays in the menu bar.
final class TerminalWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate, TerminalBridgeDelegate {
    static let tabBarHeight: CGFloat = 38

    let bridge = TerminalBridge()
    private let webView: TerminalWebView
    private let dragView = DragRegionView()
    private let glassView: NSView

    init() {
        let window = TerminalWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Ronic JustTerminal"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: .darkAqua)
        window.minSize = NSSize(width: 480, height: 260)
        window.tabbingMode = .disallowed
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("RonicJustTerminalMainWindow")

        // Glass: Liquid Glass (macOS 26+) or the classic translucent material.
        glassView = Self.makeGlassView()

        let config = WKWebViewConfiguration()
        config.userContentController = WKUserContentController()
        config.suppressesIncrementalRendering = false
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        if ProcessInfo.processInfo.environment["JT_DEVTOOLS"] == "1" {
            config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        }
        webView = TerminalWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")   // fundo transparente: o vidro aparece
        webView.allowsMagnification = false
        webView.allowsBackForwardNavigationGestures = false

        super.init(window: window)

        config.userContentController.add(bridge, name: "jt")
        bridge.webView = webView
        bridge.delegate = self
        webView.navigationDelegate = self
        window.delegate = self

        let content = NSView()
        content.wantsLayer = true
        for v in [glassView, webView, dragView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                v.topAnchor.constraint(equalTo: content.topAnchor),
                v.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        window.contentView = content
        applyOpacity(SettingsStore.shared.opacity)
        loadInterface()
        #if DEBUG
        SelfTest.runIfRequested(bridge: bridge, webView: webView)
        #endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) não é usado") }

    // MARK: - Interface web

    private func loadInterface() {
        guard let dir = Self.webDirectory() else {
            webView.loadHTMLString("<body style='color:#eee;font:14px -apple-system;padding:40px;background:#111'>"
                + "Pasta <b>web</b> não encontrada no app.</body>", baseURL: nil)
            return
        }
        webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    /// In the .app: Contents/Resources/web. In development (`swift run`): the repo's ../shared-web.
    private static func webDirectory() -> URL? {
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["JT_WEB_DIR"] {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent("web")) }
        let source = URL(fileURLWithPath: #filePath)   // macos/Sources/JustTerminal/Window/…
        candidates.append(source.deletingLastPathComponent().appendingPathComponent("../../../../shared-web").standardized)
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("index.html").path) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // The page never navigates away: links open in the default browser.
        if action.navigationType == .linkActivated, let url = action.request.url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        // If the web process crashes, the shells stay alive but the page loses its state.
        bridge.terminateAll()
        loadInterface()
    }

    // MARK: - Mostrar / esconder

    func show() {
        if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
        if #available(macOS 14.0, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
        layoutTrafficLights()
        window?.makeFirstResponder(webView)
        bridge.send(["t": "shown"])
    }

    func hide() {
        window?.orderOut(nil)
        // In the background: leaves the Dock and ⌘Tab; only the menu bar icon remains.
        NSApp.setActivationPolicy(.accessory)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    // MARK: - Vidro e opacidade

    private static func makeGlassView() -> NSView {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.style = .regular
            glass.cornerRadius = 0
            glass.tintColor = NSColor(calibratedWhite: 0.02, alpha: 0.35)
            return glass
        }
        #endif
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        return effect
    }

    /// At 100% opacity the glass is hidden: nothing to composite, less GPU work.
    private func applyOpacity(_ opacity: Double) {
        glassView.isHidden = opacity >= 0.999
        window?.invalidateShadow()
    }

    // MARK: - Window buttons (traffic lights) centered in the tab bar

    private func layoutTrafficLights() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(type), let container = button.superview else { continue }
            let y = container.bounds.height - Self.tabBarHeight / 2 - button.frame.height / 2
            if abs(button.frame.origin.y - y) > 0.5 {
                button.setFrameOrigin(NSPoint(x: button.frame.origin.x, y: y))
            }
        }
    }

    func windowDidResize(_ notification: Notification) { layoutTrafficLights() }
    func windowDidBecomeKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidResignKey(_ notification: Notification) { layoutTrafficLights() }
    func windowDidExitFullScreen(_ notification: Notification) {
        bridge.send(["t": "fullscreen", "on": false])
        layoutTrafficLights()
    }
    func windowWillEnterFullScreen(_ notification: Notification) { bridge.send(["t": "fullscreen", "on": true]) }

    // MARK: - TerminalBridgeDelegate

    func bridgeDidUpdateDragRegions(_ rects: [NSRect]) { dragView.regions = rects }
    func bridgeDidChangeOpacity(_ opacity: Double) { applyOpacity(opacity) }
    func bridgeLastTabClosed() { hide() }
    func bridgeTabsChanged(count: Int, title: String) {
        window?.title = title.isEmpty ? "Ronic JustTerminal" : title
    }
}

/// Window that hands ⌘ shortcuts to the menu BEFORE the WKWebView: the terminal never receives
/// ⌘T, ⌘W, ⌘C… and the native menu decides what to do (new tab, copy the xterm selection, etc.).
final class TerminalWindow: NSWindow {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags
        let ctrlTab = event.keyCode == 48 && flags.contains(.control)   // ⌃Tab / ⌃⇧Tab switch tabs
        if flags.contains(.command) || ctrlTab, NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// WKWebView that accepts the first click (clicking an inactive window already places the cursor/tab).
final class TerminalWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Transparent layer over the tab bar: it only "exists" (hitTest) in the empty areas reported by
/// the page; there a click drags the window and a double click zooms, like a title bar.
final class DragRegionView: NSView {
    var regions: [NSRect] = []

    override var isFlipped: Bool { true }   // same coordinates as the page (origin at the top)

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return regions.contains { $0.contains(local) } ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Minimize" { window.performMiniaturize(nil) } else if action != "None" { window.performZoom(nil) }
        } else {
            window.performDrag(with: event)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
