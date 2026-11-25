import AppKit

/// Main menu. Every ⌘ shortcut lives here (the window hands them to the menu before the
/// terminal sees them), and each item just forwards a command to the web UI.
enum MainMenu {
    static func build(target: AppDelegate) -> NSMenu {
        let main = NSMenu()

        func item(_ title: String, _ action: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: action, keyEquivalent: key)
            it.keyEquivalentModifierMask = mods
            it.target = target
            return it
        }

        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let root = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            root.submenu = menu
            return root
        }

        // JustTerminal
        let hideOthers = NSMenuItem(title: "Ocultar Outros", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        main.addItem(submenu("Ronic JustTerminal", [
            item("Sobre o Ronic JustTerminal", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            item("Ajustes…", #selector(AppDelegate.openSettings(_:)), ","),
            .separator(),
            NSMenuItem(title: "Ocultar Ronic JustTerminal", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            hideOthers,
            NSMenuItem(title: "Mostrar Todos", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""),
            .separator(),
            item("Encerrar Ronic JustTerminal", #selector(AppDelegate.quit(_:)), "q"),
        ]))

        // Shell
        main.addItem(submenu("Shell", [
            item("Nova Aba", #selector(AppDelegate.newTab(_:)), "t"),
            item("Renomear Aba…", #selector(AppDelegate.renameTab(_:)), "r", [.command, .shift]),
            .separator(),
            item("Fechar Aba", #selector(AppDelegate.closeTab(_:)), "w"),
            item("Fechar Janela", #selector(AppDelegate.hideWindow(_:)), "w", [.command, .shift]),
        ]))

        // Editar
        main.addItem(submenu("Editar", [
            item("Recortar", #selector(AppDelegate.cutText(_:)), "x"),
            item("Copiar", #selector(AppDelegate.copyText(_:)), "c"),
            item("Colar", #selector(AppDelegate.pasteText(_:)), "v"),
            item("Selecionar Tudo", #selector(AppDelegate.selectAllText(_:)), "a"),
            .separator(),
            item("Limpar", #selector(AppDelegate.clearBuffer(_:)), "k"),
        ]))

        // Visualizar
        let zoomInAlt = item("Aumentar Fonte", #selector(AppDelegate.zoomIn(_:)), "+")
        zoomInAlt.isHidden = true
        zoomInAlt.allowsKeyEquivalentWhenHidden = true
        let fullScreen = NSMenuItem(title: "Tela Cheia", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        main.addItem(submenu("Visualizar", [
            item("Mostrar/Ocultar Barra Lateral", #selector(AppDelegate.toggleSidebar(_:)), "s", [.command, .control]),
            item("Mostrar/Ocultar Git", #selector(AppDelegate.toggleGit(_:)), "g", [.command, .control]),
            .separator(),
            item("Aumentar Fonte", #selector(AppDelegate.zoomIn(_:)), "="),
            zoomInAlt,
            item("Diminuir Fonte", #selector(AppDelegate.zoomOut(_:)), "-"),
            item("Tamanho Padrão", #selector(AppDelegate.zoomReset(_:)), "0"),
            .separator(),
            fullScreen,
        ]))

        // Janela
        var windowItems: [NSMenuItem] = [
            NSMenuItem(title: "Minimizar", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
            NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""),
            .separator(),
            item("Aba Anterior", #selector(AppDelegate.previousTab(_:)), "[", [.command, .shift]),
            item("Próxima Aba", #selector(AppDelegate.nextTab(_:)), "]", [.command, .shift]),
        ]
        let altPrev = item("Aba Anterior", #selector(AppDelegate.previousTab(_:)), "\t", [.control, .shift])
        let altNext = item("Próxima Aba", #selector(AppDelegate.nextTab(_:)), "\t", [.control])
        for alt in [altPrev, altNext] {
            alt.isHidden = true
            alt.allowsKeyEquivalentWhenHidden = true
            windowItems.append(alt)
        }
        for n in 1...9 {
            let it = item("Aba \(n)", #selector(AppDelegate.selectTab(_:)), "\(n)")
            it.tag = n
            it.isHidden = true
            it.allowsKeyEquivalentWhenHidden = true
            windowItems.append(it)
        }
        windowItems.append(.separator())
        windowItems.append(item("Mostrar Ronic JustTerminal", #selector(AppDelegate.showWindow(_:)), ""))
        let windowMenu = submenu("Janela", windowItems)
        main.addItem(windowMenu)
        NSApp.windowsMenu = windowMenu.submenu

        return main
    }
}
