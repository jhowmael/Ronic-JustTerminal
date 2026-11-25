# Ponte interface ↔ app nativo

A interface (`shared-web/`: abas, barra lateral, xterm.js) é a mesma no macOS e no Windows. Ela não conhece PTY nem sistema operacional: conversa com o app nativo por **mensagens JSON**. Cada app nativo implementa o mesmo contrato:

| | macOS | Windows |
|---|---|---|
| Página → nativo | `webkit.messageHandlers.jt.postMessage(json)` | `chrome.webview.postMessage(json)` |
| Nativo → página | `evaluateJavaScript("JT.recv(msg)")` / `JT.data(id, b64)` | `PostWebMessageAsJson(msg)` |
| Implementação | `macos/.../Terminal/TerminalBridge.swift` | `windows/RonicJustTerminal/TerminalBridge.cs` |
| PTY | `PTYSession.swift` (`forkpty`) | `ConPtySession.cs` (ConPTY) |

Sem app nativo (abrindo `shared-web/index.html` no navegador), a página entra em **modo demonstração**, com eco local e um sistema de arquivos falso. Esse modo serve para trabalhar na interface.

## Página → nativo

| `t` | Campos | O que faz |
|---|---|---|
| `ready` | | Página carregada. O nativo responde com `init`. |
| `spawn` | `id`, `profile`, `cols`, `rows`, `cwd?` | Abre um shell para a aba `id`, opcionalmente numa pasta. |
| `input` | `id`, `data`, `binary?` | Bytes digitados (UTF-8; com `binary`, cada caractere vira 1 byte). |
| `run` | `id`, `text` | Comando gerado pela barra lateral (`cd`). No macOS, é recusado se um programa estiver em primeiro plano. |
| `resize` | `id`, `cols`, `rows` | Novo tamanho do terminal. |
| `ack` | `id`, `bytes` | Controle de fluxo: bytes já desenhados (veja abaixo). |
| `kill` | `id` | Aba fechada: encerra o shell. |
| `listDir` | `reqId`, `id`, `path`, `host` | Conteúdo de uma pasta, para a árvore. |
| `reveal` | `id`, `path`, `host` | Mostra no Finder / Explorador. |
| `saveSettings` | `settings` | Grava os ajustes. O nativo só guarda e lê `opacity`. |
| `saveHistory` | `items` | Grava o histórico de comandos. |
| `opacity` | `value` | Prévia ao arrastar o controle (liga/desliga o vidro). |
| `copy` | `text` | Área de transferência. |
| `paste` | | Pede o texto da área de transferência (`pasteText`). |
| `openUrl` | `url` | Abre no navegador padrão (http/https/mailto). |
| `tabs` | `count`, `title` | Resumo das abas, usado no título da janela e na confirmação ao sair. |
| `lastTabClosed` | | A última aba foi fechada: o nativo esconde a janela. |
| `dragRegions` | `rects` | Só no macOS: áreas vazias da barra de abas que arrastam a janela. |

## Nativo → página

| `t` | Campos | O que faz |
|---|---|---|
| `init` | `platform`, `version`, `settings`, `profiles`, `home`, `places`, `history`, `windowsBuild?` | Estado inicial. |
| `data` | `id`, `b64` | Saída do PTY em base64. O xterm.js decodifica UTF-8 parcial sozinho. |
| `exit` | `id`, `code` | O shell terminou. |
| `spawnError` | `id`, `message` | O shell não abriu. |
| `cwd` | `id`, `path`, `host?` | Pasta atual mudou (macOS: lida do kernel). |
| `dirList` | `reqId`, `path`, `entries[{n,d,h}]`, `error` | Resposta de `listDir` (n = nome, d = pasta, h = oculto). |
| `cmd` | `name`, `arg?` | Comando do menu nativo ou da bandeja: `newTab`, `closeTab`, `nextTab`, `prevTab`, `selectTab`, `renameTab`, `settings`, `toggleSidebar`, `copy`, `paste`, `selectAll`, `clear`, `zoomIn`, `zoomOut`, `zoomReset`. |
| `pasteText` | `text` | Resposta de `paste`. |
| `shown` | | A janela voltou do segundo plano. |
| `fullscreen` | `on` | macOS: entrou ou saiu da tela cheia. |
| `toast` | `text` | Aviso rápido na interface. |

## Pasta atual (barra lateral)

* **macOS:** sem configurar nada no shell. Depois de cada saída, o app consulta a pasta do processo em primeiro plano com `proc_pidinfo(PROC_PIDVNODEPATHINFO)`.
* **Windows:** cada perfil injeta uma integração no prompt, só na sessão, sem alterar arquivos do usuário:
  * PowerShell: `-EncodedCommand` que embrulha a função `prompt` (inclusive oh-my-posh) e emite `OSC 9;9;"C:\pasta"` e `OSC 133;A/B`.
  * cmd: a variável `PROMPT` ganha `$e]9;9;$P$e\` e `OSC 133`.
  * WSL e Git Bash: `PROMPT_COMMAND` emite `OSC 7` (`file://distro/caminho`).
* A página também entende `OSC 7`, `OSC 9;9` e `OSC 133` de qualquer shell que já os emita (fish, starship, configurações próprias).

## Histórico de comandos

Quando o usuário aperta Enter, a página lê do buffer do xterm o texto entre o fim do prompt e o cursor. O fim do prompt vem de `OSC 133;B`, quando existe. Sem ele, é deduzido assim: depois de um Enter, a última saída antes de o terminal ficar quieto é o prompt novo. O eco da digitação não move essa marca. Telas cheias (vim, less, htop) usam o buffer alternativo e são ignoradas.

## Controle de fluxo

O nativo conta os bytes enviados e ainda não confirmados de cada sessão. Acima de 512 KB, a leitura do PTY pausa. Abaixo de 128 KB, ela volta. A página confirma (`ack`) no callback de `term.write`, em lotes de 32 KB. Assim, `yes` ou `cat arquivo-enorme` não travam a janela, e o processo fica naturalmente limitado à velocidade de desenho.
