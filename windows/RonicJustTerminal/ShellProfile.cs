using System.Text;

namespace RonicJustTerminal;

/// Um shell que pode ser aberto numa aba nova.
///
/// Kind (dialeto do "cd" e formato dos caminhos): "powershell", "cmd" ou "posix" (WSL, Git Bash).
/// Cada perfil injeta uma integração leve no prompt para informar a pasta atual à barra lateral
/// (OSC 9;9 / OSC 7) e marcar onde o prompt termina (OSC 133), sem alterar arquivos do usuário.
internal sealed class ShellProfile
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Exe { get; init; }
    public string Args { get; init; } = "";
    public required string Kind { get; init; }
    public string Flavor { get; init; } = "";
    /// Pasta inicial da árvore, no formato do shell.
    public string Home { get; init; } = "";
    /// Variáveis de ambiente extras só desta sessão.
    public Dictionary<string, string> Env { get; init; } = new();

    public object Json => new { id = Id, name = Name, kind = Kind, flavor = Flavor, home = Home };

    /// Linha de comando completa. `cwd` (formato do shell) só importa para o WSL (--cd).
    public string CommandLine(string? cwd)
    {
        var args = Args;
        if (Flavor == "wsl") args = !string.IsNullOrEmpty(cwd) && cwd.StartsWith('/') ? $"--cd \"{cwd}\"" : "~";
        return Quote(Exe) + (args.Length > 0 ? " " + args : "");
    }

    /// Converte um caminho no formato do shell para um caminho que o Windows consegue abrir.
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

    /// Shells disponíveis nesta máquina, na ordem de preferência (o primeiro é o padrão).
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

    /// Embrulha o prompt atual do PowerShell (inclusive oh-my-posh/starship do perfil do usuário):
    /// antes dele, a pasta atual (OSC 9;9) e o início do prompt (OSC 133;A); depois, o fim (133;B).
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
            catch (ArgumentException) { /* entrada inválida no PATH */ }
        }
        return null;
    }
}
