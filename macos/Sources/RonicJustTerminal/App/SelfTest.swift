#if DEBUG
import AppKit
import WebKit

/// Autoteste de desenvolvimento (só em builds DEBUG):
///   JT_SELFTEST=/caminho/saida JT_DATA_DIR=/tmp/jt-dados swift run --package-path macos RonicJustTerminal
/// (JT_DATA_DIR evita gravar o histórico do teste nos dados reais.)
/// Digita comandos no shell real, navega pela barra lateral, abre uma segunda aba,
/// grava o estado da interface em selftest.json e encerra.
enum SelfTest {
    static func runIfRequested(bridge: TerminalBridge, webView: WKWebView) {
        guard let out = ProcessInfo.processInfo.environment["JT_SELFTEST"] else { return }
        let main = DispatchQueue.main
        func js(_ s: String) { webView.evaluateJavaScript(s, completionHandler: nil) }
        func save(_ name: String) {
            let probe = """
            JSON.stringify({
              crumbs: [...document.querySelectorAll('.crumbs button')].map(b => b.textContent),
              current: document.querySelector('#sb-folders .node.current')?.dataset.path || null,
              places: [...document.querySelectorAll('#sb-places .name')].map(n => n.textContent),
              treeRows: document.querySelectorAll('#sb-folders .node').length,
              history: [...document.querySelectorAll('.history li code')].slice(0, 5).map(c => c.textContent),
              tabs: JT.dump().map(t => ({ title: t.title, active: t.active, tail: t.text.split('\\n').slice(-4) }))
            })
            """
            webView.evaluateJavaScript(probe) { result, error in
                let text = (result as? String) ?? "erro: \(String(describing: error))"
                try? text.write(to: URL(fileURLWithPath: out).appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        }
        main.asyncAfter(deadline: .now() + 2.0) { js("JT.type('cd /usr/bin\\r')") }
        main.asyncAfter(deadline: .now() + 3.0) { js("JT.type('echo JT_OK $TERM_PROGRAM; printf \"ação 日本 🙂\\\\n\"\\r')") }
        main.asyncAfter(deadline: .now() + 4.0) { save("selftest-1.json") }
        main.asyncAfter(deadline: .now() + 4.2) {
            js("document.querySelector('#sb-places .node[data-path=\"/\"]').click()")
        }
        main.asyncAfter(deadline: .now() + 5.5) { save("selftest-2.json") }
        main.asyncAfter(deadline: .now() + 5.7) { bridge.command("newTab") }
        main.asyncAfter(deadline: .now() + 7.0) { save("selftest-3.json") }
        main.asyncAfter(deadline: .now() + 7.5) {
            print("SELFTEST sessions=\(bridge.sessionCount) tabs=\(bridge.tabCount)")
            bridge.terminateAll()
            main.asyncAfter(deadline: .now() + 0.5) { exit(0) }
        }
    }
}
#endif
