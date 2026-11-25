import AppKit

/// App lifecycle: window, main menu, menu bar icon and quitting.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowController: TerminalWindowController!
    private var statusBar: StatusBarController!

    private var bridge: TerminalBridge { windowController.bridge }

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowController = TerminalWindowController()
        NSApp.mainMenu = MainMenu.build(target: self)
        statusBar = StatusBarController(app: self)
        windowController.show()
    }

    /// Closing the last window does not quit the app: it keeps running in the menu bar.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click (or reopening the app from Finder/Spotlight): show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        windowController.show()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.terminateAll()
    }

    var sessionCount: Int { bridge.sessionCount }
    var isWindowVisible: Bool { windowController.isVisible }

    // MARK: - Actions (main menu and menu bar)

    @objc func showWindow(_ sender: Any?) { windowController.show() }

    @objc func hideWindow(_ sender: Any?) { windowController.hide() }

    @objc func toggleWindow(_ sender: Any?) {
        if windowController.isVisible && NSApp.isActive { windowController.hide() } else { windowController.show() }
    }

    @objc func newTab(_ sender: Any?) {
        let wasVisible = windowController.isVisible
        windowController.show()
        // A hidden window with no tabs gets a new one when it reappears ("shown").
        if wasVisible || bridge.tabCount > 0 { bridge.command("newTab") }
    }

    @objc func newTabWithProfile(_ sender: NSMenuItem) {
        windowController.show()
        bridge.command("newTab", arg: sender.representedObject as? String ?? "")
    }

    @objc func closeTab(_ sender: Any?) { bridge.command("closeTab") }
    @objc func renameTab(_ sender: Any?) { bridge.command("renameTab") }
    @objc func nextTab(_ sender: Any?) { bridge.command("nextTab") }
    @objc func previousTab(_ sender: Any?) { bridge.command("prevTab") }
    @objc func selectTab(_ sender: NSMenuItem) { bridge.command("selectTab", arg: sender.tag) }
    @objc func openSettings(_ sender: Any?) { windowController.show(); bridge.command("settings") }
    @objc func copyText(_ sender: Any?) { bridge.command("copy") }
    @objc func pasteText(_ sender: Any?) { bridge.command("paste") }
    @objc func selectAllText(_ sender: Any?) { bridge.command("selectAll") }
    @objc func clearBuffer(_ sender: Any?) { bridge.command("clear") }
    @objc func toggleSidebar(_ sender: Any?) { bridge.command("toggleSidebar") }
    @objc func zoomIn(_ sender: Any?) { bridge.command("zoomIn") }
    @objc func zoomOut(_ sender: Any?) { bridge.command("zoomOut") }
    @objc func zoomReset(_ sender: Any?) { bridge.command("zoomReset") }

    /// Quit for real (⌘Q or "Quit" in the menu bar). Asks for confirmation if shells are open.
    @objc func quit(_ sender: Any?) {
        let count = bridge.sessionCount
        if count > 0 {
            if !windowController.isVisible { windowController.show() }
            let alert = NSAlert()
            alert.messageText = "Encerrar o Ronic JustTerminal?"
            alert.informativeText = count == 1
                ? "Há 1 sessão aberta. Ela será finalizada."
                : "Há \(count) sessões abertas. Todas serão finalizadas."
            alert.addButton(withTitle: "Encerrar")
            alert.addButton(withTitle: "Cancelar")
            alert.alertStyle = .warning
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        NSApp.terminate(nil)
    }

    @objc func showAbout(_ sender: Any?) {
        windowController.show()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Ronic JustTerminal",
            .credits: NSAttributedString(string: "Terminal minimalista da família Ronic.\nhttps://github.com/jhowmael/Ronic-JustTerminal",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }
}
