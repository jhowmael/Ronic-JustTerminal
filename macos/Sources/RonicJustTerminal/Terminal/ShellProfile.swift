import Darwin
import Foundation

/// Um shell que pode ser aberto numa aba nova.
struct ShellProfile {
    let id: String
    let name: String
    let path: String
    var args: [String] = []
    /// Abre como shell de login (lê ~/.zprofile, ~/.bash_profile…), como o Terminal e o iTerm.
    var login = true

    var json: [String: Any] { ["id": id, "name": name, "kind": "posix", "home": NSHomeDirectory()] }

    /// Shells disponíveis nesta máquina. O primeiro é o shell de login do usuário.
    static func detect() -> [ShellProfile] {
        var result: [ShellProfile] = []
        var seen = Set<String>()

        func add(_ id: String, _ name: String, _ path: String) {
            let resolved = (path as NSString).resolvingSymlinksInPath
            guard FileManager.default.isExecutableFile(atPath: path), !seen.contains(resolved) else { return }
            seen.insert(resolved)
            result.append(ShellProfile(id: id, name: name, path: path))
        }

        let login = userShell()
        add("login", "\((login as NSString).lastPathComponent) (padrão)", login)
        add("zsh", "zsh", "/bin/zsh")
        add("bash", "bash", "/bin/bash")
        for prefix in ["/opt/homebrew/bin", "/usr/local/bin"] {
            add("bash-brew", "bash (Homebrew)", "\(prefix)/bash")
            add("fish", "fish", "\(prefix)/fish")
            add("nu", "nushell", "\(prefix)/nu")
        }
        if result.isEmpty { result.append(ShellProfile(id: "sh", name: "sh", path: "/bin/sh")) }
        return result
    }

    /// Shell configurado em Usuários e Grupos (getpwuid), com $SHELL como alternativa.
    private static func userShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }
}
