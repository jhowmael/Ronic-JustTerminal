import Foundation

/// Prompt with the full path of the current directory ("/Users/jonatan/development $"), like on
/// Windows, instead of the macOS default ("Mac-mini:development jonatan$"), which only shows the last folder.
///
/// Rules:
/// - applies only to Ronic JustTerminal sessions: no user file is modified;
/// - only replaces the prompt while it is still the SYSTEM DEFAULT: custom prompts
///   (oh-my-zsh, starship, your own PS1) are left alone;
/// - can be turned off in Settings ("fullPathPrompt").
enum ShellIntegration {
    /// Default bash prompt on macOS (/etc/bashrc) and zsh prompt (/etc/zshrc).
    private static let bashDefaultPS1 = #"\h:\W \u\$ "#
    private static let zshDefaultPS1 = "%n@%m %1~ %# "

    /// Path color in the prompt: the same light blue as the sidebar folders (#7fb4ff), as 24-bit RGB
    /// so it looks identical whatever the terminal palette is.
    private static let pathColor = "1;38;2;127;180;255"

    /// Extra environment variables for this shell's session.
    static func environment(for profile: ShellProfile) -> [String: String] {
        let name = (profile.path as NSString).lastPathComponent
        let env = ProcessInfo.processInfo.environment
        switch name {
        case "bash":
            // PROMPT_COMMAND runs before every prompt; it swaps PS1 only while it is still the default.
            let hook = #"[ "$PS1" = '\#(bashDefaultPS1)' ] && PS1='\[\e[\#(pathColor)m\]${PWD}\[\e[0m\] \$ '"#
            let existing = env["PROMPT_COMMAND"].map { "; " + $0 } ?? ""
            return ["PROMPT_COMMAND": hook + existing]
        case "zsh":
            // zsh has no PROMPT_COMMAND: use our own ZDOTDIR, which loads the user's files
            // (.zshenv, .zprofile, .zshrc, .zlogin) and only then adjusts the prompt.
            guard let dir = installZsh() else { return [:] }
            var extra = ["ZDOTDIR": dir.path, "JT_USER_ZDOTDIR": env["ZDOTDIR"] ?? NSHomeDirectory()]
            if env["ZDOTDIR"] != nil { extra["JT_ZDOTDIR_WAS_SET"] = "1" }
            return extra
        default:
            return [:]
        }
    }

    /// Writes the zsh startup files to the data folder (once per app run).
    private static var zshDir: URL?
    private static func installZsh() -> URL? {
        if let zshDir { return zshDir }
        let dir = SettingsStore.shared.dataDirectory.appendingPathComponent("shell/zsh", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (file, body) in zshFiles {
                try (header + body).write(to: dir.appendingPathComponent(file), atomically: true, encoding: .utf8)
            }
        } catch {
            NSLog("Ronic JustTerminal: could not install the zsh integration: \(error)")
            return nil
        }
        zshDir = dir
        return dir
    }

    private static let header = """
        # Ronic JustTerminal: generated automatically on every app run; do not edit.
        # Loads your zsh files as usual and only replaces the prompt if it is the macOS default.

        """

    /// Each stage: point ZDOTDIR at the user's folder, load their file and come back here
    /// (zsh looks up the next file in $ZDOTDIR).
    private static func stage(_ file: String) -> String {
        """
        ZDOTDIR="$JT_USER_ZDOTDIR"
        [[ -r "$ZDOTDIR/\(file)" ]] && source "$ZDOTDIR/\(file)"
        JT_USER_ZDOTDIR="$ZDOTDIR"
        ZDOTDIR="$__jt_zdotdir"

        """
    }

    private static let zshFiles: [(String, String)] = [
        (".zshenv", "__jt_zdotdir=\"$ZDOTDIR\"\n" + stage(".zshenv")),
        (".zprofile", stage(".zprofile")),
        (".zshrc", stage(".zshrc") + """
            # /etc/zshrc computes HISTFILE from our ZDOTDIR: put the history back where it belongs.
            [[ "$HISTFILE" == "$__jt_zdotdir/.zsh_history" ]] && HISTFILE="$JT_USER_ZDOTDIR/.zsh_history"
            # Self-test / screenshots (JT_DATA_DIR): the shell history stays in the test folder.
            [[ -n "$JT_HISTFILE" ]] && HISTFILE="$JT_HISTFILE"
            # Default prompt ("user@mac folder %") → full path, like on Windows.
            [[ "$PS1" == '\(zshDefaultPS1)' ]] && PS1=$'%{\\e[\(pathColor)m%}%/%{\\e[0m%} %# '

            """),
        (".zlogin", """
            ZDOTDIR="$JT_USER_ZDOTDIR"
            [[ -r "$ZDOTDIR/.zlogin" ]] && source "$ZDOTDIR/.zlogin"
            # End of startup: ZDOTDIR goes back to the user's value (or is unset).
            [[ -z "$JT_ZDOTDIR_WAS_SET" ]] && unset ZDOTDIR
            unset __jt_zdotdir JT_USER_ZDOTDIR JT_ZDOTDIR_WAS_SET

            """),
    ]
}
