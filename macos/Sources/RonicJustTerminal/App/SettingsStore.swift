import Foundation

/// Settings persisted in ~/Library/Application Support/RonicJustTerminal/settings.json.
///
/// The format is owned by the web UI (shared-web/app.js); the native side only stores the JSON
/// and reads what it needs (the opacity, to turn the glass on/off). That way, when the app is
/// reopened, the opacity and every other setting come back exactly as they were.
final class SettingsStore {
    static let shared = SettingsStore()

    private(set) var values: [String: Any] = [:]
    private let url: URL
    private let queue = DispatchQueue(label: "justterminal.settings", qos: .utility)

    private init() {
        // JT_DATA_DIR: alternate folder (self-test), so the real data is never touched.
        let base = ProcessInfo.processInfo.environment["JT_DATA_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("RonicJustTerminal", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("settings.json")
        // Migration: the first builds wrote to ~/Library/Application Support/JustTerminal.
        let legacy = base.appendingPathComponent("JustTerminal/settings.json")
        if !FileManager.default.fileExists(atPath: url.path), FileManager.default.fileExists(atPath: legacy.path) {
            try? FileManager.default.copyItem(at: legacy, to: url)
        }
        if let data = try? Data(contentsOf: url),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            values = obj
        }
    }

    /// Sidebar command history (history.json, next to the settings).
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

    /// App data folder (settings, history, shell integration).
    var dataDirectory: URL { url.deletingLastPathComponent() }

    /// Prompt with the full path (default: on).
    var fullPathPrompt: Bool { (values["fullPathPrompt"] as? Bool) ?? true }

    /// Opacity of the dark layer over the glass (1 = fully dark, the default).
    var opacity: Double { (values["opacity"] as? NSNumber)?.doubleValue ?? 1 }

    func replace(with newValues: [String: Any]) {
        values = newValues
        guard let data = try? JSONSerialization.data(withJSONObject: newValues, options: [.prettyPrinted, .sortedKeys]) else { return }
        let url = self.url
        queue.async { try? data.write(to: url, options: .atomic) }
    }
}
