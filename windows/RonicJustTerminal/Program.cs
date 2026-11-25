namespace RonicJustTerminal;

internal static class Program
{
    private const string MutexName = @"Local\RonicJustTerminal.SingleInstance";
    private const string ShowEventName = @"Local\RonicJustTerminal.Show";

    [STAThread]
    private static void Main()
    {
        // Instância única: abrir o app de novo só traz a janela existente (as sessões continuam).
        using var mutex = new Mutex(true, MutexName, out bool first);
        if (!first)
        {
            try { EventWaitHandle.OpenExisting(ShowEventName).Set(); } catch (WaitHandleCannotBeOpenedException) { }
            return;
        }

        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        var form = new MainForm();
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, ShowEventName);
        var listener = new Thread(() =>
        {
            while (showEvent.WaitOne())
            {
                if (form.IsHandleCreated) form.BeginInvoke(form.ShowFromTray);
            }
        }) { IsBackground = true, Name = "single-instance" };
        listener.Start();

        Application.Run(form);
    }
}
