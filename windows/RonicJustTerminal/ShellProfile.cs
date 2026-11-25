using System.Text;

namespace RonicJustTerminal;

/// A shell that can be opened in a new tab.
///
/// Kind ("cd" dialect and path format): "powershell", "cmd" or "posix" (WSL, Git Bash).
/// Each profile injects a lightweight prompt integration that reports the current directory to the
/// sidebar (OSC 9;9 / OSC 7) and marks where the prompt ends (OSC 133), without touching user files.
internal sealed class ShellProfile
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Exe { get; init; }
    public string Args { get; init; } = "";
    public required string Kind { get; init; }
    public string Flavor { get; init; } = "";
    /// Root folder of the tree, in the shell's format.
    public string Home { get; init; } = "";
    /// Extra environment variables for this session only.
    public Dictionary<string, string> Env { get; init; } = new();

    public object Json => new { id = Id, name = Name, kind = Kind, flavor = Flavor, home = Home };

    /// Full command line. `cwd` (shell format) only matters for WSL (--cd).
    public string CommandLine(string? cwd)
    {
        var args = Args;
        if (Flavor == "wsl") args = !string.IsNullOrEmpty(cwd) && cwd.StartsWith('/') ? $"--cd \"{cwd}\"" : "~";
        return Quote(Exe) + (args.Length > 0 ? " " + args : "");
    }

    /// Converts a path in the shell's format into a path Windows can open.
    public string ToWindowsPath(string path, string host)
    {
        if (Kind != "posix") return path;
        if (Flavor == "wsl")
        {
            var distro = string.IsNullOrEmpty(host) ? DefaultWslDistro() : host;
            var unc = $@"\\wsl.localhost\{distro}{path.Replace('/', '\\')}";
            return Directory.Exists(unc) ? unc : $@"\\wsl$\{distro}{path.Replace('/', '\\')}";
        }
        // Git Bash: /c/Users/x → C:\Users\x; /usr/bin → <Git>\usr\bin
        if (path.Length >= 2 && path[0] == '/' && char.IsLetter(path[1]) && (path.Length == 2 || path[2] == '/'))
            return $@"{char.ToUpperInvariant(path[1])}:\{path[Math.Min(3, path.Length)..].Replace('/', '\\')}";
        var gitRoot = Path.GetDirectoryName(Path.GetDirectoryName(Exe)) ?? "";
        return Path.Combine(gitRoot, path.TrimStart('/').Replace('/', '\\'));
    }

    /// Shells available on this machine, in order of preference (the first is the default).
    public static List<ShellProfile> Detect()
    {
        var list = new List<ShellProfile>();
        var system32 = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var psArgs = "-NoLogo -NoExit -EncodedCommand " + Convert.ToBase64String(Encoding.Unicode.GetBytes(PowerShellIntegration));

        void Add(ShellProfile p) { if (File.Exists(p.Exe)) list.Add(p); }

        Add(new ShellProfile
        {
            Id = "pwsh", Name = "PowerShell 7", Kind = "powershell", Home = home, Args = psArgs,
            Exe = FindOnPath("pwsh.exe") ?? Path.Combine(programFiles, "PowerShell", "7", "pwsh.exe"),
        });
        Add(new ShellProfile
        {
            Id = "powershell", Name = "Windows PowerShell", Kind = "powershell", Home = home, Args = psArgs,
            Exe = Path.Combine(system32, "WindowsPowerShell", "v1.0", "powershell.exe"),
        });
        var userPrompt = Environment.GetEnvironmentVariable("PROMPT");
        Add(new ShellProfile
        {
            Id = "cmd", Name = "Prompt de Comando", Kind = "cmd", Home = home,
            Exe = Path.Combine(system32, "cmd.exe"),
            Env = { ["PROMPT"] = $@"$e]133;A$e\$e]9;9;$P$e\{(string.IsNullOrEmpty(userPrompt) ? "$P$G" : userPrompt)}$e]133;B$e\" },
        });
        Add(new ShellProfile
        {
            Id = "wsl", Name = "WSL (Linux)", Kind = "posix", Flavor = "wsl",
            Exe = Path.Combine(system32, "wsl.exe"),
            Env =
            {
                ["PROMPT_COMMAND"] = @"printf '\033]7;file://%s%s\033\\' ""$WSL_DISTRO_NAME"" ""$PWD""",
                ["WSLENV"] = AppendWslEnv(Environment.GetEnvironmentVariable("WSLENV"), "PROMPT_COMMAND/u"),
            },
        });
        var gitBash = Path.Combine(programFiles, "Git", "bin", "bash.exe");
        Add(new ShellProfile
        {
            Id = "gitbash", Name = "Git Bash", Kind = "posix", Flavor = "gitbash", Args = "--login -i",
            Exe = gitBash,
            Home = "/" + char.ToLowerInvariant(home[0]) + home[2..].Replace('\\', '/'),
            Env = { ["PROMPT_COMMAND"] = @"printf '\033]7;file://%s\033\\' ""$PWD""" },
        });

        if (list.Count == 0)
            list.Add(new ShellProfile { Id = "cmd", Name = "Prompt de Comando", Kind = "cmd", Exe = "cmd.exe", Home = home });
        return list;
    }

    /// Wraps the current PowerShell prompt (including oh-my-posh/starship from the user's profile):
    /// before it, the current directory (OSC 9;9) and the prompt start (OSC 133;A); after it, the end (133;B).
    private const string PowerShellIntegration = """
        $global:__jtPrompt = $function:prompt
        function global:prompt {
            $e = [char]27; $b = [char]7
            $loc = $executionContext.SessionState.Path.CurrentLocation
            $cwd = if ($loc.Provider.Name -eq 'FileSystem') { "$e]9;9;`"$($loc.ProviderPath)`"$b" } else { '' }
            "$e]133;A$b$cwd" + (& $global:__jtPrompt) + "$e]133;B$b"
        }
        """;

    private static string AppendWslEnv(string? current, string entry)
    {
        var parts = (current ?? "").Split(':', StringSplitOptions.RemoveEmptyEntries).ToList();
        var name = entry.Split('/')[0];
        if (!parts.Any(p => p.Split('/')[0].Equals(name, StringComparison.OrdinalIgnoreCase))) parts.Add(entry);
        return string.Join(':', parts);
    }

    private static string? _wslDistro;
    private static string DefaultWslDistro()
    {
        if (_wslDistro is not null) return _wslDistro;
        try
        {
            using var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Lxss");
            var guid = key?.GetValue("DefaultDistribution") as string;
            using var distro = guid is null ? null : key!.OpenSubKey(guid);
            _wslDistro = distro?.GetValue("DistributionName") as string ?? "Ubuntu";
        }
        catch (Exception) { _wslDistro = "Ubuntu"; }
        return _wslDistro;
    }

    private static string Quote(string path) => path.Contains(' ') ? $"\"{path}\"" : path;

    private static string? FindOnPath(string exe)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(';', StringSplitOptions.RemoveEmptyEntries))
        {
            try
            {
                var full = Path.Combine(dir.Trim(), exe);
                if (File.Exists(full)) return full;
            }
            catch (ArgumentException) { /* invalid PATH entry */ }
        }
        return null;
    }
}
