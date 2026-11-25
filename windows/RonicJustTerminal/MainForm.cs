using System.Reflection;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using static RonicJustTerminal.Native;

namespace RonicJustTerminal;

/// Janela principal: barra de título escura, vidro Acrylic (Windows 11) e a interface web
/// (abas + xterm.js) num WebView2 transparente. Ícone na bandeja do sistema.
///
/// Fechar a janela NÃO encerra os shells: ela só é escondida e o app continua na bandeja.
/// Equivalente a TerminalWindowController.swift + StatusBarController.swift no macOS.
internal sealed class MainForm : Form
{
    private const string HostName = "app.ronicjustterminal.example";

    private readonly WebView2 _web = new() { Dock = DockStyle.Fill, DefaultBackgroundColor = Color.Transparent };
    private readonly NotifyIcon _tray;
    private readonly TerminalBridge _bridge;
    private bool _quitting;
    private bool _trayHintShown;
    private bool _webReady;

    public MainForm()
    {
        Text = "Ronic JustTerminal";
        Icon = LoadIcon();
        BackColor = Color.Black;          // com o frame estendido, preto = transparente (vidro aparece)
        MinimumSize = new Size(480, 280);
        StartPosition = FormStartPosition.Manual;
        var screen = Screen.PrimaryScreen!.WorkingArea;
        var bounds = SettingsStore.WindowBounds ?? new Rectangle(0, 0, 960, 600);
        if (!Screen.AllScreens.Any(s => s.WorkingArea.IntersectsWith(bounds)) || SettingsStore.WindowBounds is null)
            bounds = new Rectangle(screen.X + (screen.Width - bounds.Width) / 2, screen.Y + (screen.Height - bounds.Height) / 2, bounds.Width, bounds.Height);
        Bounds = bounds;
        if (SettingsStore.WindowMaximized) WindowState = FormWindowState.Maximized;

        Controls.Add(_web);

        _bridge = new TerminalBridge(this);
        _bridge.TabsChanged += (count, title) => Text = string.IsNullOrEmpty(title) ? "Ronic JustTerminal" : $"{title} — Ronic JustTerminal";
        _bridge.LastTabClosed += HideToTray;
        _bridge.OpacityChanged += ApplyBackdrop;

        _tray = new NotifyIcon
        {
            Icon = new Icon(LoadIcon(), SystemInformation.SmallIconSize),
            Text = "Ronic JustTerminal",
            Visible = true,
            ContextMenuStrip = BuildTrayMenu(),
        };
        _tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) ToggleFromTray(); };

        Load += async (_, _) => await InitWebViewAsync();
    }

    // ------------------------------------------------------------- WebView2

    private async Task InitWebViewAsync()
    {
        try
        {
            var dataDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "RonicJustTerminal", "WebView2");
            var env = await CoreWebView2Environment.CreateAsync(null, dataDir);
            await _web.EnsureCoreWebView2Async(env);
        }
        catch (WebView2RuntimeNotFoundException)
        {
            var r = MessageBox.Show(
                "O Ronic JustTerminal precisa do Microsoft Edge WebView2 Runtime (já vem no Windows 11).\n\nAbrir a página de download?",
                "Ronic JustTerminal", MessageBoxButtons.YesNo, MessageBoxIcon.Warning);
            if (r == DialogResult.Yes)
                System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(
                    "https://developer.microsoft.com/microsoft-edge/webview2/") { UseShellExecute = true });
            Quit(confirm: false);
            return;
        }

        var core = _web.CoreWebView2;
        var s = core.Settings;
        s.AreDefaultContextMenusEnabled = false;
        s.AreDevToolsEnabled = Environment.GetEnvironmentVariable("JT_DEVTOOLS") == "1";
        s.IsStatusBarEnabled = false;
        s.IsZoomControlEnabled = false;
        s.IsPinchZoomEnabled = false;
        s.IsSwipeNavigationEnabled = false;
        s.AreBrowserAcceleratorKeysEnabled = false;   // Ctrl+P, F5, Ctrl+F… ficam para o terminal
        s.IsGeneralAutofillEnabled = false;
        s.IsPasswordAutosaveEnabled = false;

        var webDir = FindWebDirectory();
        if (webDir is null)
        {
            core.NavigateToString("<body style='background:#111;color:#eee;font:14px Segoe UI;padding:40px'>Pasta <b>web</b> não encontrada ao lado do RonicJustTerminal.exe.</body>");
            return;
        }
        core.SetVirtualHostNameToFolderMapping(HostName, webDir, CoreWebView2HostResourceAccessKind.Allow);
        _bridge.Attach(core);

        // A página nunca navega para fora: links e janelas novas abrem no navegador padrão.
        core.NewWindowRequested += (_, e) => { e.Handled = true; OpenExternal(e.Uri); };
        core.NavigationStarting += (_, e) =>
        {
            if (!e.Uri.StartsWith($"https://{HostName}/", StringComparison.OrdinalIgnoreCase)) { e.Cancel = true; OpenExternal(e.Uri); }
        };
        core.ProcessFailed += (_, _) => { _bridge.TerminateAll(); core.Reload(); };

        core.Navigate($"https://{HostName}/index.html");
        _webReady = true;
        ApplyBackdrop(SettingsStore.Opacity);
    }

    /// Ao lado do .exe: web\ (pacote). Em desenvolvimento: shared-web\ do repositório.
    private static string? FindWebDirectory()
    {
        var env = Environment.GetEnvironmentVariable("JT_WEB_DIR");
        if (!string.IsNullOrEmpty(env) && File.Exists(Path.Combine(env, "index.html"))) return env;
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        if (File.Exists(Path.Combine(dir.FullName, "web", "index.html"))) return Path.Combine(dir.FullName, "web");
        for (; dir is not null; dir = dir.Parent)
        {
            var candidate = Path.Combine(dir.FullName, "shared-web");
            if (File.Exists(Path.Combine(candidate, "index.html"))) return candidate;
        }
        return null;
    }

    private static void OpenExternal(string uri)
    {
        if (Uri.TryCreate(uri, UriKind.Absolute, out var u) && (u.Scheme is "http" or "https" or "mailto"))
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(u.AbsoluteUri) { UseShellExecute = true });
    }

    // ------------------------------------------------------- vidro e barra de título

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        int on = 1;
        if (DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE, ref on, sizeof(int)) != 0)
            DwmSetWindowAttribute(Handle, DWMWA_USE_IMMERSIVE_DARK_MODE_OLD, ref on, sizeof(int));
        ApplyBackdrop(SettingsStore.Opacity);
    }

    /// Opacidade 100%: janela sólida, barra de título na cor do terminal (sem custo de composição).
    /// Abaixo de 100%: vidro Acrylic do Windows 11 atrás da página (no Windows 10 fica sólido).
    private void ApplyBackdrop(double opacity)
    {
        if (!IsHandleCreated) return;
        bool glass = opacity < 0.999 && Environment.OSVersion.Version.Build >= 22621;
        int backdrop = glass ? DWMSBT_TRANSIENTWINDOW : DWMSBT_NONE;
        DwmSetWindowAttribute(Handle, DWMWA_SYSTEMBACKDROP_TYPE, ref backdrop, sizeof(int));
        int caption = glass ? DWMWA_COLOR_DEFAULT : 0x000E0D0B;   // COLORREF 0x00BBGGRR = #0B0D0E
        DwmSetWindowAttribute(Handle, DWMWA_CAPTION_COLOR, ref caption, sizeof(int));
        var margins = glass ? new MARGINS { Left = -1, Right = -1, Top = -1, Bottom = -1 } : new MARGINS();
        DwmExtendFrameIntoClientArea(Handle, ref margins);
        BackColor = glass ? Color.Black : Color.FromArgb(11, 13, 14);
    }

    // ------------------------------------------------------- mostrar / esconder

    public void ShowFromTray()
    {
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        Activate();
        BringToFront();
        _web.Focus();
        if (_webReady) _bridge.Send(new { t = "shown" });
    }

    private void ToggleFromTray()
    {
        if (Visible && WindowState != FormWindowState.Minimized && ContainsFocus) HideToTray();
        else ShowFromTray();
    }

    private void HideToTray()
    {
        SaveBounds();
        Hide();
        if (!_trayHintShown)
        {
            _trayHintShown = true;
            _tray.ShowBalloonTip(3000, "Ronic JustTerminal continua rodando",
                "As sessões seguem abertas. Clique no ícone da bandeja para voltar ou em Sair para encerrar.", ToolTipIcon.Info);
        }
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!_quitting && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            HideToTray();
            return;
        }
        SaveBounds();
        _bridge.TerminateAll();
        _tray.Visible = false;
        base.OnFormClosing(e);
    }

    private void SaveBounds()
    {
        if (!IsHandleCreated) return;
        SettingsStore.WindowMaximized = WindowState == FormWindowState.Maximized;
        if (WindowState == FormWindowState.Normal) SettingsStore.WindowBounds = Bounds;
        else SettingsStore.WindowBounds = RestoreBounds;
    }

    /// Encerrar de verdade (Sair na bandeja). Pede confirmação se há shells abertos.
    public void Quit(bool confirm = true)
    {
        int count = _bridge.SessionCount;
        if (confirm && count > 0)
        {
            ShowFromTray();
            var text = count == 1 ? "Há 1 sessão aberta. Ela será finalizada." : $"Há {count} sessões abertas. Todas serão finalizadas.";
            if (MessageBox.Show(this, text, "Encerrar o Ronic JustTerminal?", MessageBoxButtons.OKCancel, MessageBoxIcon.Warning) != DialogResult.OK)
                return;
        }
        _quitting = true;
        Close();
        Application.Exit();
    }

    // ----------------------------------------------------------------- bandeja

    private ContextMenuStrip BuildTrayMenu()
    {
        var menu = new ContextMenuStrip();
        menu.Opening += (_, _) =>
        {
            menu.Items.Clear();
            menu.Items.Add(new ToolStripMenuItem("Ronic JustTerminal") { Enabled = false });
            int count = _bridge.SessionCount;
            menu.Items.Add(new ToolStripMenuItem(count == 0 ? "Nenhuma sessão aberta" : count == 1 ? "1 sessão rodando" : $"{count} sessões rodando") { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(Visible ? "Mostrar janela" : "Reabrir janela", null, (_, _) => ShowFromTray());
            menu.Items.Add("Nova aba", null, (_, _) => NewTab(null));
            if (_bridge.Profiles.Count > 1)
            {
                var sub = new ToolStripMenuItem("Nova aba com");
                foreach (var p in _bridge.Profiles) sub.DropDownItems.Add(p.Name, null, (_, _) => NewTab(p.Id));
                menu.Items.Add(sub);
            }
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("Sair", null, (_, _) => Quit());
        };
        menu.Items.Add("…");   // o menu precisa de um item para abrir; Opening monta o conteúdo real
        return menu;
    }

    private void NewTab(string? profile)
    {
        bool wasVisible = Visible;
        ShowFromTray();
        // Janela escondida sem abas já ganha uma ao aparecer ("shown").
        if (wasVisible || _bridge.TabCount > 0) _bridge.Command("newTab", profile);
    }

    private static Icon LoadIcon()
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("RonicJustTerminal.ronic.ico");
        return stream is null ? SystemIcons.Application : new Icon(stream);
    }
}
