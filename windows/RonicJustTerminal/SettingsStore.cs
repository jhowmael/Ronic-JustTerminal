using System.Text.Json;
using System.Text.Json.Nodes;

namespace RonicJustTerminal;

/// Settings persisted in %APPDATA%\RonicJustTerminal\settings.json (format owned by the web
/// UI; the native side only stores it and reads the opacity) and the window position in window.json.
/// Counterpart of SettingsStore.swift on macOS.
internal static class SettingsStore
{
    private static readonly string Dir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "RonicJustTerminal");
    private static readonly string SettingsPath = Path.Combine(Dir, "settings.json");
    private static readonly string WindowPath = Path.Combine(Dir, "window.json");
    private static readonly string HistoryPath = Path.Combine(Dir, "history.json");
    private static readonly JsonSerializerOptions Pretty = new() { WriteIndented = true };
    private static readonly object WriteLock = new();

    public static JsonObject Values { get; private set; } = Load(SettingsPath);

    /// Opacity of the dark layer over the glass (1 = fully dark, the default).
    public static double Opacity => Values["opacity"] is JsonValue v && v.TryGetValue(out double d) ? d : 1;

    public static void Replace(JsonObject values)
    {
        Values = values;
        Save(SettingsPath, values);
    }

    /// Sidebar command history.
    public static JsonArray History
    {
        get
        {
            try
            {
                if (File.Exists(HistoryPath) && JsonNode.Parse(File.ReadAllText(HistoryPath)) is JsonArray a) return a;
            }
            catch (Exception) { }
            return new JsonArray();
        }
    }

    public static void ReplaceHistory(JsonArray items)
    {
        var json = items.ToJsonString();
        Task.Run(() =>
        {
            lock (WriteLock)
            try
            {
                Directory.CreateDirectory(Dir);
                File.WriteAllText(HistoryPath + ".tmp", json);
                File.Move(HistoryPath + ".tmp", HistoryPath, overwrite: true);
            }
            catch (Exception) { }
        });
    }

    public static Rectangle? WindowBounds
    {
        get
        {
            var o = Load(WindowPath);
            int? Get(string k) => o[k] is JsonValue v && v.TryGetValue(out int i) ? i : null;
            if (Get("x") is int x && Get("y") is int y && Get("w") is int w && Get("h") is int h) return new Rectangle(x, y, w, h);
            return null;
        }
        set
        {
            if (value is Rectangle r) Save(WindowPath, new JsonObject { ["x"] = r.X, ["y"] = r.Y, ["w"] = r.Width, ["h"] = r.Height });
        }
    }

    public static bool WindowMaximized
    {
        get => Load(WindowPath)["maximized"] is JsonValue v && v.TryGetValue(out bool b) && b;
        set
        {
            var o = Load(WindowPath);
            o["maximized"] = value;
            Save(WindowPath, o);
        }
    }

    private static JsonObject Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonNode.Parse(File.ReadAllText(path)) is JsonObject o) return o;
        }
        catch (Exception) { /* corrupted file: fall back to defaults */ }
        return new JsonObject();
    }

    private static void Save(string path, JsonObject values)
    {
        var json = values.ToJsonString(Pretty);
        Task.Run(() =>
        {
            lock (WriteLock)
            try
            {
                Directory.CreateDirectory(Dir);
                var tmp = path + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, path, overwrite: true);
            }
            catch (Exception) { /* no write permission: ignore */ }
        });
    }
}
