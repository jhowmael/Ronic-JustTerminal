import Foundation

/// Ajustes persistidos em ~/Library/Application Support/RonicJustTerminal/settings.json.
///
/// O formato é definido pela interface (shared-web/app.js); o lado nativo só guarda o JSON
/// e lê o que precisa (a opacidade, para ligar/desligar o vidro). Assim, ao reabrir o app,
/// a opacidade e os demais ajustes voltam exatamente como estavam.
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var values: [String: Any] = [:]
    private let url: URL
    private let queue = DispatchQueue(label: "justterminal.settings", qos: .utility)

    private init() {
        // JT_DATA_DIR: pasta alternativa (autoteste), para não mexer nos dados reais.
        let base = ProcessInfo.processInfo.environment["JT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RonicJustTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
        // Migração: as primeiras builds gravavam em ~/Library/Application Support/JustTerminal.
        let legacy = base.appendingPathComponent("JustTerminal/settings.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: url)
        }
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = obj
        }
    }

    /// Histórico de comandos da barra lateral (history.json, ao lado dos ajustes).
    private(set) lazy var history: [Any] = {
        guard let data = try? Data(contentsOf: historyURL),
              let list = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return [] }
        return list
    }()

    private var historyURL: URL { url.deletingLastPathComponent().appendingPathComponent("history.json") }

    func replaceHistory(with items: [Any]) {
        history = items
        guard let data = try? JSONSerialization.data(withJSONObject: items) else { return }
        let url = historyURL
        queue.async { try? data.write(to: url, options: .atomic) }
    }

    /// Opacidade da camada escura sobre o vidro (1 = totalmente escuro, o padrão).
    var opacity: Double { (values["opacity"] as? NSNumber)?.doubleValue ?? 1 }

    func replace(with newValues: [String: Any]) {
        values = newValues
        guard let data = try? JSONSerialization.data(withJSONObject: newValues, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = self.url
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}
