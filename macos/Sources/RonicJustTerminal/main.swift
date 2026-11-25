import AppKit

// Entry point. No storyboard/xib: the menu and the window are built in code.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
