import Darwin
import Foundation

/// Uma sessão de terminal: um shell rodando num pseudo-terminal (forkpty).
///
/// Camada de PTY do macOS. Não sabe nada de abas nem de interface: recebe bytes para escrever,
/// entrega bytes lidos e avisa quando o processo termina.
///
/// Desempenho:
/// - a leitura roda numa fila de I/O dedicada (DispatchSourceRead, sem polling);
/// - controle de fluxo: se a interface ainda não desenhou `highWater` bytes, a leitura pausa
///   até chegar o "ack" (assim um `yes` ou `cat arquivo-enorme` não congela a janela).
final class PTYSession {
    let id: Int
    private(set) var pid: pid_t = 0

    /// Chamado na fila de I/O com cada bloco lido.
    var onData: ((Data) -> Void)?
    /// Chamado na main thread quando o processo termina (depois de toda a saída ter sido lida).
    var onExit: ((Int32) -> Void)?
    /// Chamado na fila de I/O quando a pasta atual do shell muda (cd).
    var onCwdChange: ((String) -> Void)?

    private static let ioQueue = DispatchQueue(label: "justterminal.pty.io", qos: .userInteractive)
    private static let highWater = 512 * 1024
    private static let lowWater = 128 * 1024

    private var master: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pendingWrite = Data()
    private var inFlight = 0
    private var readPaused = false
    private var closed = false
    private var exitStatus: Int32?
    private var lastCwd = ""
    private var cwdCheckScheduled = false

    init(id: Int) {
        self.id = id
    }

    /// Inicia o shell. `profile.path` é executado como shell de login (argv[0] = "-zsh").
    func start(profile: ShellProfile, cols: Int, rows: Int, cwd: String) throws {
        // Tudo que o processo filho usa é preparado ANTES do fork: depois do fork só chamamos
        // funções seguras (chdir, execve, _exit).
        let argv0 = profile.login ? "-" + (profile.path as NSString).lastPathComponent : profile.path
        let args = [argv0] + profile.args
        let env = Self.environment()

        let cArgs = args.map { strdup($0) } + [nil]
        let cEnv = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        let cPath = strdup(profile.path)
        let cCwd = strdup(cwd)
        defer {
            cArgs.forEach { free($0) }
            cEnv.forEach { free($0) }
            free(cPath)
            free(cCwd)
        }

        var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
        var fd: Int32 = -1
        let pid = forkpty(&fd, nil, nil, &size)
        if pid < 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        if pid == 0 {
            // Processo filho.
            _ = chdir(cCwd)
            cArgs.withUnsafeBufferPointer { argvPtr in
                cEnv.withUnsafeBufferPointer { envPtr in
                    _ = execve(cPath, argvPtr.baseAddress, envPtr.baseAddress)
                }
            }
            _exit(127)
        }

        self.pid = pid
        self.master = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)

        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: Self.ioQueue)
        rs.setEventHandler { [weak self] in self?.readAvailable() }
        rs.setCancelHandler { close(fd) }
        readSource = rs
        rs.resume()

        let ps = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: Self.ioQueue)
        ps.setEventHandler { [weak self] in self?.processExited() }
        processSource = ps
        ps.resume()
        scheduleCwdCheck()
    }

    // MARK: - Pasta atual (sem configurar nada no shell)

    /// Depois de cada saída (o prompt reaparece após um `cd`), consulta a pasta atual do processo
    /// em primeiro plano direto no kernel (proc_pidinfo). No máximo ~6 consultas por segundo.
    private func scheduleCwdCheck() {
        guard !cwdCheckScheduled, onCwdChange != nil else { return }
        cwdCheckScheduled = true
        Self.ioQueue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.cwdCheckScheduled = false
            guard !self.closed, let path = self.currentDirectory(), path != self.lastCwd else { return }
            self.lastCwd = path
            self.onCwdChange?(path)
        }
    }

    /// Pasta atual do processo em primeiro plano (um shell aninhado também conta) ou do shell.
    private func currentDirectory() -> String? {
        let fg = master >= 0 ? tcgetpgrp(master) : -1
        return Self.cwd(of: fg > 0 ? fg : pid) ?? Self.cwd(of: pid)
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        return path.isEmpty ? nil : path
    }

    /// Algum programa (vim, npm, ssh…) está em primeiro plano, em vez do prompt do shell?
    var isBusy: Bool {
        guard master >= 0, pid > 0 else { return false }
        let fg = tcgetpgrp(master)
        guard fg > 0, fg != pid else { return false }
        var name = [CChar](repeating: 0, count: 256)
        proc_name(fg, &name, UInt32(name.count))
        let shells: Set<String> = ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "nu"]
        return !shells.contains(String(cString: name))
    }

    // MARK: - Leitura

    private func readAvailable() {
        guard !closed else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
            if n > 0 {
                inFlight += n
                onData?(Data(buffer[0..<n]))
                scheduleCwdCheck()
                if inFlight > Self.highWater {
                    pauseReading()
                    return
                }
                if n < buffer.count { return }
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                return
            } else {
                // EOF / EIO: o lado escravo fechou (shell saiu). Para de ler.
                stopReading()
                finishIfDone()
                return
            }
        }
    }

    private func pauseReading() {
        guard !readPaused, let rs = readSource else { return }
        readPaused = true
        rs.suspend()
    }

    private func resumeReading() {
        guard readPaused, let rs = readSource else { return }
        readPaused = false
        rs.resume()
    }

    private func stopReading() {
        guard let rs = readSource else { return }
        readSource = nil
        if readPaused { readPaused = false; rs.resume() }   // uma fonte suspensa não pode ser cancelada
        rs.cancel()
    }

    /// A interface confirmou que desenhou `bytes` bytes desta sessão.
    func ack(_ bytes: Int) {
        Self.ioQueue.async {
            self.inFlight = max(0, self.inFlight - bytes)
            if self.inFlight < Self.lowWater { self.resumeReading() }
        }
    }

    // MARK: - Escrita

    func write(_ data: Data) {
        Self.ioQueue.async {
            guard !self.closed, self.master >= 0 else { return }
            self.pendingWrite.append(data)
            self.flushWrites()
        }
    }

    private func flushWrites() {
        while !pendingWrite.isEmpty {
            let n = pendingWrite.withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
            if n > 0 {
                pendingWrite.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && errno == EAGAIN {
                // Buffer do PTY cheio (colar um texto enorme): espera o kernel liberar espaço.
                if writeSource == nil {
                    let ws = DispatchSource.makeWriteSource(fileDescriptor: master, queue: Self.ioQueue)
                    ws.setEventHandler { [weak self] in self?.flushWrites() }
                    writeSource = ws
                    ws.resume()
                }
                return
            } else {
                pendingWrite.removeAll()
            }
        }
        writeSource?.cancel()
        writeSource = nil
    }

    // MARK: - Tamanho

    func resize(cols: Int, rows: Int) {
        Self.ioQueue.async {
            guard !self.closed, self.master >= 0 else { return }
            var size = winsize(ws_row: UInt16(clamping: rows), ws_col: UInt16(clamping: cols), ws_xpixel: 0, ws_ypixel: 0)
            _ = ioctl(self.master, TIOCSWINSZ, &size)
        }
    }

    // MARK: - Fim

    private func processExited() {
        var status: Int32 = 0
        let r = waitpid(pid, &status, WNOHANG)
        guard r == pid || r < 0 else { return }
        processSource?.cancel()
        processSource = nil
        // WIFEXITED/WEXITSTATUS são macros em C; aqui vão em aritmética direta.
        let signaled = (status & 0x7f) != 0
        exitStatus = signaled ? 128 + (status & 0x7f) : (status >> 8) & 0xff
        // Lê o que sobrou no PTY antes de avisar a interface.
        if readSource != nil { readAvailable() }
        stopReading()
        finishIfDone()
    }

    private func finishIfDone() {
        guard !closed, readSource == nil, let code = exitStatus else { return }
        closed = true
        writeSource?.cancel()
        writeSource = nil
        DispatchQueue.main.async { self.onExit?(code) }
    }

    /// Fecha a aba: SIGHUP para o grupo de processos (como fechar uma janela do Terminal).
    func terminate() {
        let pid = self.pid
        guard pid > 0 else { return }
        Self.ioQueue.async {
            self.onData = nil
            kill(-pid, SIGHUP)
            kill(pid, SIGHUP)
            self.stopReading()
        }
        // Processo que ignora SIGHUP: força depois de 3 s.
        Self.ioQueue.asyncAfter(deadline: .now() + 3) {
            if self.exitStatus == nil, kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
        }
    }

    /// Ambiente do shell: o do app + variáveis de terminal. Apps abertos pelo Finder não
    /// herdam LANG, então definimos um UTF-8 a partir do idioma do sistema.
    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "RonicJustTerminal"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        if env["LANG"] == nil {
            let id = Locale.current.identifier.replacingOccurrences(of: "-", with: "_")
            env["LANG"] = (id.isEmpty ? "en_US" : id.components(separatedBy: "@").first!) + ".UTF-8"
        }
        if env["HOME"] == nil { env["HOME"] = NSHomeDirectory() }
        env["BASH_SILENCE_DEPRECATION_WARNING"] = "1"   // o bash do sistema não insiste em "use zsh"
        // Variáveis de quem lançou o app que não fazem sentido dentro do shell.
        for key in ["__CFBundleIdentifier", "XPC_SERVICE_NAME", "XPC_FLAGS", "TERM_SESSION_ID", "ITERM_SESSION_ID"] {
            env.removeValue(forKey: key)
        }
        return env
    }
}
