import Foundation

/// Runs `git` in the background for the Git sidebar (status, branches, diff, stage…).
/// Commands that the user should watch (commit, push, switch…) are typed into the terminal by
/// the UI instead; this runner never prompts: no terminal, GIT_TERMINAL_PROMPT=0, no askpass.
enum GitRunner {
    struct Result {
        let code: Int32
        let out: String
        let err: String
    }

    private static let queue = DispatchQueue(label: "justterminal.git", qos: .userInitiated, attributes: .concurrent)
    private static let maxOutput = 2 * 1024 * 1024

    /// Homebrew's git first; /usr/bin/git only when the developer tools are installed (without
    /// them, that shim opens the "install Command Line Tools" dialog).
    static let gitPath: String? = {
        let fm = FileManager.default
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git"] where fm.isExecutableFile(atPath: path) {
            return path
        }
        let toolchains = ["/Library/Developer/CommandLineTools/usr/bin/git",
                          "/Applications/Xcode.app/Contents/Developer/usr/bin/git"]
        return toolchains.contains(where: { fm.isExecutableFile(atPath: $0) }) ? "/usr/bin/git" : nil
    }()

    /// `write`: the command changes the repository (no GIT_OPTIONAL_LOCKS=0).
    /// `background`: started by the app itself (auto-fetch): longer timeout, never asks anything.
    static func run(_ args: [String], cwd: String, write: Bool, background: Bool,
                    completion: @escaping (Result) -> Void) {
        let done = { (r: Result) in DispatchQueue.main.async { completion(r) } }
        guard let git = gitPath else { return done(Result(code: 127, out: "", err: "git not found")) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir), isDir.boolValue else {
            return done(Result(code: 128, out: "", err: "fatal: not a directory: \(cwd)"))
        }

        queue.async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: git)
            process.arguments = ["-c", "color.ui=false", "-c", "core.quotepath=false"] + args
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)

            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["SSH_ASKPASS_REQUIRE"] = "never"
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
            if !write { env["GIT_OPTIONAL_LOCKS"] = "0" }   // reads never take the index lock
            if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
            process.environment = env

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return done(Result(code: 127, out: "", err: error.localizedDescription))
            }

            // Both pipes are drained in parallel, or a big diff would block git on a full pipe.
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + (background ? 90 : 20), execute: timeout)
            process.waitUntilExit()
            group.wait()
            timeout.cancel()

            if outData.count > maxOutput { outData = outData.prefix(maxOutput) }
            done(Result(code: process.terminationStatus,
                        out: String(decoding: outData, as: UTF8.self),
                        err: String(decoding: errData, as: UTF8.self)))
        }
    }
}
