using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace RonicJustTerminal;

/// P/Invoke: ConPTY (kernel32 / conpty.dll) and window effects (dwmapi).
internal static class Native
{
    // ---------------------------------------------------------------- ConPTY

    [StructLayout(LayoutKind.Sequential)]
    public struct COORD
    {
        public short X;
        public short Y;
        public COORD(int x, int y) { X = (short)Math.Clamp(x, 1, short.MaxValue); Y = (short)Math.Clamp(y, 1, short.MaxValue); }
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved, lpDesktop, lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2;
        public IntPtr lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public IntPtr hProcess, hThread;
        public int dwProcessId, dwThreadId;
    }

    public const int STARTF_USESTDHANDLES = 0x00000100;
    public const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    public const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
    public static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = (IntPtr)0x00020016;
    public const uint INFINITE = 0xFFFFFFFF;

    // The pseudo console comes from the bundled conpty.dll (Microsoft.Windows.Console.ConPTY, with
    // OpenConsole.exe in x64\ or arm64\) when present; otherwise from Windows' kernel32.
    public static readonly bool BundledConPty = DetectBundledConPty();

    private static bool DetectBundledConPty()
    {
        var dir = AppContext.BaseDirectory;
        var arch = RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "arm64" : "x64";
        return File.Exists(Path.Combine(dir, "conpty.dll"))
            && File.Exists(Path.Combine(dir, arch, "OpenConsole.exe"))
            && NativeLibrary.TryLoad(Path.Combine(dir, "conpty.dll"), out _);
    }

    public static int CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC)
    {
        if (BundledConPty)
        {
            try { return ConptyCreatePseudoConsole(size, hInput, hOutput, dwFlags, out phPC); }
            catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException) { }
        }
        return Kernel32CreatePseudoConsole(size, hInput, hOutput, dwFlags, out phPC);
    }

    public static int ResizePseudoConsole(IntPtr hPC, COORD size) =>
        BundledConPty ? ConptyResizePseudoConsole(hPC, size) : Kernel32ResizePseudoConsole(hPC, size);

    public static void ClosePseudoConsole(IntPtr hPC)
    {
        if (BundledConPty) ConptyClosePseudoConsole(hPC); else Kernel32ClosePseudoConsole(hPC);
    }

    [DllImport("conpty.dll", EntryPoint = "ConptyCreatePseudoConsole")]
    private static extern int ConptyCreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("conpty.dll", EntryPoint = "ConptyResizePseudoConsole")]
    private static extern int ConptyResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("conpty.dll", EntryPoint = "ConptyClosePseudoConsole")]
    private static extern void ConptyClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "CreatePseudoConsole")]
    private static extern int Kernel32CreatePseudoConsole(COORD size, SafeFileHandle hInput, SafeFileHandle hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ResizePseudoConsole")]
    private static extern int Kernel32ResizePseudoConsole(IntPtr hPC, COORD size);

    [DllImport("kernel32.dll", SetLastError = true, EntryPoint = "ClosePseudoConsole")]
    private static extern void Kernel32ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CreatePipe(out SafeFileHandle hReadPipe, out SafeFileHandle hWritePipe, IntPtr lpPipeAttributes, int nSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool InitializeProcThreadAttributeList(IntPtr lpAttributeList, int dwAttributeCount, int dwFlags, ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool UpdateProcThreadAttribute(IntPtr lpAttributeList, uint dwFlags, IntPtr attribute, IntPtr lpValue,
        IntPtr cbSize, IntPtr lpPreviousValue, IntPtr lpReturnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern bool CreateProcessW(string? lpApplicationName, char[] lpCommandLine, IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes, bool bInheritHandles, uint dwCreationFlags, IntPtr lpEnvironment, string? lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    // ------------------------------------------------------------- Janela (DWM)

    [StructLayout(LayoutKind.Sequential)]
    public struct MARGINS { public int Left, Right, Top, Bottom; }

    public const int DWMWA_USE_IMMERSIVE_DARK_MODE_OLD = 19;
    public const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
    public const int DWMWA_CAPTION_COLOR = 35;
    public const int DWMWA_SYSTEMBACKDROP_TYPE = 38;
    public const int DWMSBT_NONE = 1;
    public const int DWMSBT_TRANSIENTWINDOW = 3;   // Acrylic
    public const int DWMWA_COLOR_DEFAULT = unchecked((int)0xFFFFFFFF);

    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);

    [DllImport("dwmapi.dll")]
    public static extern int DwmExtendFrameIntoClientArea(IntPtr hwnd, ref MARGINS margins);
}
