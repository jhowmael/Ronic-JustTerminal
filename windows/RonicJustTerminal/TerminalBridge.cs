using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Web.WebView2.Core;

namespace RonicJustTerminal;

/// Bridge between the UI (shared-web, inside the WebView2) and the ConPTY sessions.
/// Same contract as macOS: docs/BRIDGE.md. Counterpart of TerminalBridge.swift.
internal sealed class TerminalBridge
{
    private readonly Control _ui;
    private CoreWebView2? _web;
    private readonly Dictionary<int, ConPtySession> _sessions = new();
    private readonly Dictionary<int, ShellProfile> _tabProfiles = new();   // each tab's profile (even after it exits)
    private readonly List<ShellProfile> _profiles = ShellProfile.Detect();

    // PTY output is batched: several chunks read between two UI cycles become a few messages.
    private readonly object _pendingLock = new();
    private readonly Dictionary<int, MemoryStream> _pending = new();
    private readonly List<int> _pendingOrder = new();
    private bool _flushScheduled;

    public event Action<int, string>? TabsChanged;
    public event Action? LastTabClosed;
    public event Action<double>? OpacityChanged;

    public int TabCount { get; private set; }
    public int SessionCount => _sessions.Count;
    public IReadOnlyList<ShellProfile> Profiles => _profiles;

    public TerminalBridge(Control ui) => _ui = ui;

    public void Attach(CoreWebView2 web)
    {
        _web = web;
        web.WebMessageReceived += OnMessage;
    }

    // ------------------------------------------------------- messages from the page

    private void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        string json;
        try { json = e.TryGetWebMessageAsString(); }
        catch (ArgumentException) { return; }

        using var doc = JsonDocument.Parse(json);
        var msg = doc.RootElement;
        int id = Int(msg, "id");

        switch (Str(msg, "t"))
        {
            case "ready":
                Send(new
                {
                    t = "init",
                    platform = "win",
                    version = Application.ProductVersion.Split('+')[0],
                    windowsBuild = Environment.OSVersion.Version.Build,
                    settings = SettingsStore.Values,
                    profiles = _profiles.Select(p => p.Json),
                    home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    places = Places(),
                    history = SettingsStore.History,
                });
                break;

            case "spawn":
                Spawn(id, Str(msg, "profile"), Str(msg, "cwd"), Int(msg, "cols", 80), Int(msg, "rows", 24));
                break;

            case "input":
                if (_sessions.TryGetValue(id, out var s))
                {
                    var text = Str(msg, "data");
                    var bytes = msg.TryGetProperty("binary", out var b) && b.ValueKind == JsonValueKind.True
                        ? text.Select(c => (byte)c).ToArray()
                        : Encoding.UTF8.GetBytes(text);
                    s.Write(bytes);
                }
                break;

            case "resize":
                if (_sessions.TryGetValue(id, out var rs)) rs.Resize(Int(msg, "cols", 80), Int(msg, "rows", 24));
                break;

            case "ack":
                if (_sessions.TryGetValue(id, out var acked)) acked.Ack(Int(msg, "bytes"));
                break;

            case "run":
                // Folder click in the sidebar: the text already comes in the shell's dialect (cd / Set-Location).
                if (_sessions.TryGetValue(id, out var runner)) runner.Write(Encoding.UTF8.GetBytes(Str(msg, "text")));
                break;

            case "listDir":
                ListDirectory(Int(msg, "reqId"), id, Str(msg, "path"), Str(msg, "host"));
                break;

            case "reveal":
                if (_tabProfiles.TryGetValue(id, out var rp))
                {
                    var target = rp.ToWindowsPath(Str(msg, "path"), Str(msg, "host"));
                    System.Diagnostics.Process.Start("explorer.exe", Directory.Exists(target) ? $"\"{target}\"" : $"/select,\"{target}\"");
                }
                break;

            case "saveHistory":
                if (msg.TryGetProperty("items", out var items) && JsonNode.Parse(items.GetRawText()) is JsonArray arr)
                    SettingsStore.ReplaceHistory(arr);
                break;

            case "kill":
                if (_sessions.Remove(id, out var killed)) killed.Kill();
                break;

            case "saveSettings":
                if (msg.TryGetProperty("settings", out var settings) && JsonNode.Parse(settings.GetRawText()) is JsonObject obj)
                {
                    SettingsStore.Replace(obj);
                    OpacityChanged?.Invoke(SettingsStore.Opacity);
                }
                break;

            case "opacity":
                OpacityChanged?.Invoke(msg.TryGetProperty("value", out var v) && v.TryGetDouble(out var d) ? d : 1);
                break;

            case "copy":
                var copy = Str(msg, "text");
                if (copy.Length > 0) TrySetClipboard(copy);
                break;

            case "paste":
                Send(new { t = "pasteText", text = Clipboard.ContainsText() ? Clipboard.GetText() : "" });
                break;

            case "openUrl":
                if (Uri.TryCreate(Str(msg, "url"), UriKind.Absolute, out var uri) && (uri.Scheme is "http" or "https" or "mailto"))
                    System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true });
                break;

            case "tabs":
                TabCount = Int(msg, "count");
                TabsChanged?.Invoke(TabCount, Str(msg, "title"));
                break;

            case "lastTabClosed":
                TabCount = 0;
                LastTabClosed?.Invoke();
                break;
        }
    }

    private static string Str(JsonElement e, string key) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    private static int Int(JsonElement e, string key, int fallback = 0) =>
        e.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number && v.TryGetInt32(out var i) ? i : fallback;

    private static void TrySetClipboard(string text)
    {
        // The clipboard may be held by another app for a few ms.
        for (int i = 0; i < 5; i++)
        {
            try { Clipboard.SetText(text); return; }
            catch (System.Runtime.InteropServices.ExternalException) { Thread.Sleep(20); }
        }
    }

    // ----------------------------------------------------------------- sessions

    private void Spawn(int id, string profileId, string cwd, int cols, int rows)
    {
        var profile = _profiles.FirstOrDefault(p => p.Id == profileId) ?? _profiles[0];
        _tabProfiles[id] = profile;
        var session = new ConPtySession(id);
        session.Data = data => EnqueueOutput(id, data);
        session.Exited = code => _ui.BeginInvoke(() =>
        {
            FlushOutput();
            _sessions.Remove(id);
            Send(new { t = "exit", id, code });
        });
        try
        {
            var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            var dir = string.IsNullOrEmpty(cwd) || profile.Flavor == "wsl" ? home : profile.ToWindowsPath(cwd, "");
            if (!Directory.Exists(dir)) dir = home;
            session.Start(profile.CommandLine(cwd), profile.Env, cols, rows, dir);
            _sessions[id] = session;
        }
        catch (Exception ex)
        {
            Send(new { t = "spawnError", id, message = ex.Message });
        }
    }

    // ---------------------------------------------------------- pastas (barra lateral)

    private static List<object> Places()
    {
        var list = new List<object>();
        void Add(string name, string path, string icon = "dir") { if (Directory.Exists(path)) list.Add(new { name, path, icon }); }
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        Add(Environment.UserName, home, "home");
        Add("Área de Trabalho", Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        Add("Documentos", Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments));
        Add("Downloads", Path.Combine(home, "Downloads"));
        foreach (var d in DriveInfo.GetDrives())
        {
            if (d.DriveType is not (DriveType.Fixed or DriveType.Removable or DriveType.Network) || !d.IsReady) continue;
            var label = d.Name.TrimEnd('\\');
            try { if (!string.IsNullOrEmpty(d.VolumeLabel)) label = $"{d.VolumeLabel} ({label})"; }
            catch (Exception) { /* network drive without access to its label */ }
            list.Add(new { name = label, path = d.RootDirectory.FullName, icon = "disk" });
        }
        return list;
    }

    /// Folder contents: folders first, then files, in natural order (like File Explorer).
    private void ListDirectory(int reqId, int tabId, string path, string host)
    {
        var profile = _tabProfiles.GetValueOrDefault(tabId) ?? _profiles[0];
        Task.Run(() =>
        {
            object result;
            try
            {
                var dir = new DirectoryInfo(profile.ToWindowsPath(path, host));
                var entries = dir.EnumerateFileSystemInfos("*", new EnumerationOptions { IgnoreInaccessible = true, AttributesToSkip = 0 })
                    .Take(5000)
                    .Select(i => new
                    {
                        n = i.Name,
                        d = (i.Attributes & FileAttributes.Directory) != 0,
                        h = (i.Attributes & (FileAttributes.Hidden | FileAttributes.System)) != 0 || i.Name.StartsWith('.'),
                    })
                    .OrderByDescending(e => e.d)
                    .ThenBy(e => e.n, NaturalComparer.Instance)
                    .ToList();
                result = new { t = "dirList", reqId, path, entries, error = "" };
            }
            catch (UnauthorizedAccessException)
            {
                result = new { t = "dirList", reqId, path, entries = Array.Empty<object>(), error = "sem permissão para ler esta pasta" };
            }
            catch (Exception)
            {
                result = new { t = "dirList", reqId, path, entries = Array.Empty<object>(), error = "não foi possível ler esta pasta" };
            }
            _ui.BeginInvoke(() => Send(result));
        });
    }

    /// "file2" before "file10", case-insensitive (StrCmpLogicalW, the same as File Explorer).
    private sealed class NaturalComparer : IComparer<string>
    {
        public static readonly NaturalComparer Instance = new();
        [System.Runtime.InteropServices.DllImport("shlwapi.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        private static extern int StrCmpLogicalW(string a, string b);
        public int Compare(string? x, string? y) => StrCmpLogicalW(x ?? "", y ?? "");
    }

    public void TerminateAll()
    {
        foreach (var s in _sessions.Values) s.Kill();
        _sessions.Clear();
    }

    // ------------------------------------------------------- output to the page

    private void EnqueueOutput(int id, byte[] data)
    {
        bool schedule;
        lock (_pendingLock)
        {
            if (!_pending.TryGetValue(id, out var ms))
            {
                ms = new MemoryStream();
                _pending[id] = ms;
                _pendingOrder.Add(id);
            }
            ms.Write(data, 0, data.Length);
            schedule = !_flushScheduled;
            _flushScheduled = true;
        }
        if (schedule && _ui.IsHandleCreated) _ui.BeginInvoke(FlushOutput);
    }

    private void FlushOutput()
    {
        List<(int id, byte[] data)> batch;
        lock (_pendingLock)
        {
            batch = _pendingOrder.Select(id => (id, _pending[id].ToArray())).ToList();
            _pending.Clear();
            _pendingOrder.Clear();
            _flushScheduled = false;
        }
        foreach (var (id, data) in batch)
            _web?.PostWebMessageAsJson($"{{\"t\":\"data\",\"id\":{id},\"b64\":\"{Convert.ToBase64String(data)}\"}}");
    }

    /// Sends a JSON message to the page (JT.recv).
    public void Send(object message) => _web?.PostWebMessageAsJson(JsonSerializer.Serialize(message));

    /// Runs a UI command (from the system tray).
    public void Command(string name, object? arg = null) => Send(new { t = "cmd", name, arg });
}
