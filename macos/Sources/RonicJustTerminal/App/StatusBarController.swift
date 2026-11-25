import AppKit

/// Ícone discreto na barra de menus (canto superior direito). Continua lá com a janela fechada:
/// reabrir a janela, abrir uma aba nova (com qualquer shell) ou encerrar o app de vez.
final class StatusBarController: NSObject, NSMenuDelegate {
    private weak var app: AppDelegate?
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()

    init(app: AppDelegate) {
        self.app = app
        super.init()
        statusItem.button?.image = StatusIcon.image
        statusItem.button?.toolTip = "Ronic JustTerminal"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard let app else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "Ronic JustTerminal", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let count = app.sessionCount
        let status = NSMenuItem(title: count == 0 ? "Nenhuma sessão aberta"
                                : count == 1 ? "1 sessão rodando" : "\(count) sessões rodando",
                                action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let show = NSMenuItem(title: app.isWindowVisible ? "Mostrar Janela" : "Reabrir Janela",
                              action: #selector(AppDelegate.showWindow(_:)), keyEquivalent: "")
        show.target = app
        menu.addItem(show)

        let newTab = NSMenuItem(title: "Nova Aba", action: #selector(AppDelegate.newTab(_:)), keyEquivalent: "")
        newTab.target = app
        menu.addItem(newTab)

        let profiles = ShellProfile.detect()
        if profiles.count > 1 {
            let sub = NSMenu()
            for p in profiles {
                let it = NSMenuItem(title: p.name, action: #selector(AppDelegate.newTabWithProfile(_:)), keyEquivalent: "")
                it.representedObject = p.id
                it.target = app
                sub.addItem(it)
            }
            let withShell = NSMenuItem(title: "Nova Aba com", action: nil, keyEquivalent: "")
            withShell.submenu = sub
            menu.addItem(withShell)
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Encerrar Ronic JustTerminal", action: #selector(AppDelegate.quit(_:)), keyEquivalent: "")
        quit.target = app
        menu.addItem(quit)
    }
}

/// Versão monocromática do logo para a barra de menus: "R" + cursor de terminal.
/// Imagem template: se adapta sozinha ao tema claro/escuro da barra.
enum StatusIcon {
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let font = NSFont.systemFont(ofSize: 15, weight: .black)
            let r = NSAttributedString(string: "R", attributes: [.font: font, .foregroundColor: NSColor.black])
            let rSize = r.size()
            let x: CGFloat = 1
            r.draw(at: NSPoint(x: x, y: (rect.height - rSize.height) / 2))

            // Cursor "_" à direita, na linha de base do R.
            NSColor.black.setFill()
            NSBezierPath(roundedRect: NSRect(x: x + rSize.width + 1, y: 3.2, width: 5, height: 1.8),
                         xRadius: 0.9, yRadius: 0.9).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Ronic JustTerminal"
        return image
    }()
}
