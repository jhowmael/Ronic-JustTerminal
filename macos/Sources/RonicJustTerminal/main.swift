import AppKit

// Ponto de entrada. Sem storyboard/xib: o menu e a janela são montados em código.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
