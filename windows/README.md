# Ronic JustTerminal: Windows

App nativo para Windows 10 (1809+) e 11, x64, em **C# / .NET 10 / WinForms**, com **WebView2** e **ConPTY**. Ele não reimplementa a interface: carrega `/shared-web` (copiado para `web\` ao lado do `.exe`) e segue o mesmo contrato do app do macOS ([`docs/BRIDGE.md`](../docs/BRIDGE.md)).

## Arquivos

| Arquivo | Responsabilidade | Equivalente no macOS |
|---|---|---|
| `Program.cs` | Entrada, instância única (abrir de novo só mostra a janela), DPI PerMonitorV2 | `main.swift` |
| `MainForm.cs` | Janela com barra de título escura, vidro Acrylic, WebView2 transparente, **bandeja do sistema** (fechar = continuar em segundo plano) | `TerminalWindowController.swift` + `StatusBarController.swift` |
| `TerminalBridge.cs` | Mensagens da página, sessões, saída agrupada, pastas, histórico | `TerminalBridge.swift` |
| `ConPtySession.cs` | Pseudo-console (CreatePseudoConsole), leitura em thread própria, controle de fluxo | `PTYSession.swift` |
| `ShellProfile.cs` | PowerShell 7, Windows PowerShell, cmd, WSL e Git Bash, com integração de prompt (pasta atual) | `ShellProfile.swift` |
| `SettingsStore.cs` | `%APPDATA%\RonicJustTerminal\settings.json`, `history.json` e `window.json` | `SettingsStore.swift` |
| `Native.cs` | P/Invoke: ConPTY (kernel32) e DWM (tema escuro, Acrylic) | — |

## Vidro e opacidade

* **Opacidade 100%** (padrão): janela sólida e barra de título na cor do terminal.
* **Menos de 100%**: no Windows 11 22H2+, o app liga o backdrop **Acrylic** (`DWMWA_SYSTEMBACKDROP_TYPE`) e estende o frame para a área cliente. O WebView2 transparente deixa o vidro aparecer. No Windows 10, a janela continua sólida e só a camada escura fica mais clara.

## Compilar

Funciona no Windows, no macOS ou no Linux, graças a `EnableWindowsTargeting`:

```bash
# na raiz do repositório
./scripts/package-windows.sh          # → dist/RonicJustTerminal-Windows.zip
```

Para rodar no Windows durante o desenvolvimento:

```powershell
cd windows\RonicJustTerminal
dotnet run            # acha ..\..\shared-web sozinho
$env:JT_DEVTOOLS=1    # (opcional) habilita F12 / DevTools no WebView2
```

Requisitos para usar: Windows 10 1809 ou mais recente (ConPTY) e o **Microsoft Edge WebView2 Runtime** (já vem no Windows 11 e no Windows 10 atualizado; se faltar, o app oferece o link).
