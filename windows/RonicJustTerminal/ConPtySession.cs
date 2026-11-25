using System.Collections;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static RonicJustTerminal.Native;

namespace RonicJustTerminal;

/// One terminal session: a shell (PowerShell, cmd, WSL…) running in a pseudo console (ConPTY).
///
/// Windows PTY layer. Knows nothing about tabs or UI: it takes bytes to write, delivers the
/// bytes it reads and reports when the process exits. Counterpart of PTYSession.swift on macOS.
///
/// Performance:
/// - reading on a dedicated thread (blocking ReadFile, no polling);
/// - flow control: if the UI has not drawn HighWater bytes yet, reading pauses until the
///   "ack" arrives (a huge `dir /s` never freezes the window).
internal sealed class ConPtySession
{
    private const int HighWater = 512 * 1024;
    private const int LowWater = 128 * 1024;

    public int Id { get; }

    /// Called on the reader thread with every chunk read.
    public Action<byte[]>? Data;
    /// Called (on another thread) when the process exits, after all output has been read.
    public Action<int>? Exited;

    private IntPtr _hPC;
    private PROCESS_INFORMATION _pi;
    private FileStream? _input;
    private FileStream? _output;
    private readonly ManualResetEventSlim _resume = new(true);
    private readonly BlockingCollection<byte[]> _writes = new();
    private readonly object _closeLock = new();
    private long _inFlight;
    private volatile bool _killed;
    private bool _pcClosed;

    public ConPtySession(int id) => Id = id;

    public void Start(string commandLine, IReadOnlyDictionary<string, string> extraEnv, int cols, int rows, string cwd)
    {
        if (!CreatePipe(out var inputRead, out var inputWrite, IntPtr.Zero, 0) ||
            !CreatePipe(out var outputRead, out var outputWrite, IntPtr.Zero, 0))
            throw new Win32Exception(Marshal.GetLastWin32Error());

        int hr = CreatePseudoConsole(new COORD(cols, rows), inputRead, outputWrite, 0, out _hPC);
        if (hr != 0) throw new Win32Exception(hr, "CreatePseudoConsole falhou (requer Windows 10 1809 ou mais recente)");

        // ConPTY duplicated these pipe ends; our copies can be closed.
        inputRead.Dispose();
        outputWrite.Dispose();

        var attrSize = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attrSize);
        var attrList = Marshal.AllocHGlobal(attrSize);
        var env = BuildEnvironmentBlock(extraEnv);
        try
        {
            if (!InitializeProcThreadAttributeList(attrList, 1, 0, ref attrSize))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            if (!UpdateProcThreadAttribute(attrList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, _hPC, IntPtr.Size, IntPtr.Zero, IntPtr.Zero))
                throw new Win32Exception(Marshal.GetLastWin32Error());

            var si = new STARTUPINFOEX { lpAttributeList = attrList };
            si.StartupInfo.cb = Marshal.SizeOf<STARTUPINFOEX>();
            // Don't inherit the app's standard handles: all shell I/O goes through the pseudo console.
            si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;

            var cmdLine = (commandLine + "\0").ToCharArray();
            if (!CreateProcessW(null, cmdLine, IntPtr.Zero, IntPtr.Zero, false,
                    EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT, env, cwd, ref si, out _pi))
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Não foi possível iniciar \"{commandLine}\"");
        }
        catch
        {
            ClosePseudoConsoleOnce();
            inputWrite.Dispose();
            outputRead.Dispose();
            throw;
        }
        finally
        {
            DeleteProcThreadAttributeList(attrList);
            Marshal.FreeHGlobal(attrList);
            Marshal.FreeHGlobal(env);
        }

        _input = new FileStream(inputWrite, FileAccess.Write, 1, false);
        _output = new FileStream(outputRead, FileAccess.Read, 1, false);

        new Thread(ReadLoop) { IsBackground = true, Name = $"pty-read-{Id}", Priority = ThreadPriority.AboveNormal }.Start();
        new Thread(WriteLoop) { IsBackground = true, Name = $"pty-write-{Id}" }.Start();
        new Thread(WaitLoop) { IsBackground = true, Name = $"pty-wait-{Id}" }.Start();
    }

    // ------------------------------------------------------------------ leitura

    private readonly ManualResetEventSlim _readerDone = new(false);

    private void ReadLoop()
    {
        var buffer = new byte[64 * 1024];
        try
        {
            while (true)
            {
                if (!_killed) _resume.Wait();
                int n = _output!.Read(buffer, 0, buffer.Length);
                if (n <= 0) break;
                if (_killed) continue;   // tab closed: just drain until the end
                var chunk = buffer.AsSpan(0, n).ToArray();
                if (Interlocked.Add(ref _inFlight, n) > HighWater)
                {
                    _resume.Reset();
                    if (Interlocked.Read(ref _inFlight) < LowWater) _resume.Set();
                }
                Data?.Invoke(chunk);
            }
        }
        catch (IOException) { /* pipe fechado */ }
        catch (ObjectDisposedException) { }
        finally { _readerDone.Set(); }
    }

    /// The UI confirmed it has drawn `bytes` bytes of this session.
    public void Ack(int bytes)
    {
        if (Interlocked.Add(ref _inFlight, -bytes) < LowWater) _resume.Set();
    }

    // ------------------------------------------------------------------ escrita

    public void Write(byte[] data)
    {
        if (!_killed && !_writes.IsAddingCompleted) _writes.Add(data);
    }

    private void WriteLoop()
    {
        try
        {
            foreach (var data in _writes.GetConsumingEnumerable())
            {
                _input!.Write(data, 0, data.Length);
                _input.Flush();
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
    }

    // ------------------------------------------------------------------ tamanho

    public void Resize(int cols, int rows)
    {
        lock (_closeLock)
        {
            if (!_pcClosed) ResizePseudoConsole(_hPC, new COORD(cols, rows));
        }
    }

    // --------------------------------------------------------------------- fim

    private void WaitLoop()
    {
        WaitForSingleObject(_pi.hProcess, INFINITE);
        GetExitCodeProcess(_pi.hProcess, out uint code);
        // Closing the pseudo console makes the reader hit EOF after delivering what is left.
        ClosePseudoConsoleOnce();
        _readerDone.Wait(TimeSpan.FromSeconds(5));
        _writes.CompleteAdding();
        _input?.Dispose();
        _output?.Dispose();
        CloseHandle(_pi.hThread);
        CloseHandle(_pi.hProcess);
        if (!_killed) Exited?.Invoke((int)code);
    }

    /// Closing the tab: closes the pseudo console (processes get CTRL_CLOSE) and, if any of them
    /// ignores it, forces the end after 3 s.
    public void Kill()
    {
        if (_killed) return;
        _killed = true;
        Data = null;
        _resume.Set();
        var hProcess = _pi.hProcess;
        Task.Run(async () =>
        {
            ClosePseudoConsoleOnce();
            await Task.Delay(3000);
            if (WaitForSingleObject(hProcess, 0) != 0) TerminateProcess(hProcess, 1);
        });
    }

    private void ClosePseudoConsoleOnce()
    {
        lock (_closeLock)
        {
            if (_pcClosed || _hPC == IntPtr.Zero) return;
            _pcClosed = true;
        }
        ClosePseudoConsole(_hPC);
    }

    /// Shell environment: the app's own plus terminal variables. Sorted Unicode block ("k=v\0…\0\0").
    private static IntPtr BuildEnvironmentBlock(IReadOnlyDictionary<string, string> extraEnv)
    {
        var vars = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
            vars[(string)e.Key] = (string?)e.Value ?? "";
        foreach (var (k, v) in extraEnv) vars[k] = v;   // profile integration (PROMPT, PROMPT_COMMAND…)
        vars["COLORTERM"] = "truecolor";
        vars["TERM_PROGRAM"] = "RonicJustTerminal";
        vars["TERM_PROGRAM_VERSION"] = Application.ProductVersion.Split('+')[0];
        // WSL forwards these variables to Linux (WSLENV), so the shell there sees them too.
        vars["WSLENV"] = AppendWslEnv(vars.GetValueOrDefault("WSLENV"), "COLORTERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION");

        var sb = new StringBuilder();
        foreach (var (k, v) in vars)
        {
            if (k.Length == 0 || k.Contains('=') && !k.StartsWith('=')) continue;
            sb.Append(k).Append('=').Append(v).Append('\0');
        }
        sb.Append('\0');
        return Marshal.StringToHGlobalUni(sb.ToString());
    }

    private static string AppendWslEnv(string? current, params string[] names)
    {
        var parts = (current ?? "").Split(':', StringSplitOptions.RemoveEmptyEntries).ToList();
        foreach (var n in names)
            if (!parts.Any(p => p.Split('/')[0].Equals(n, StringComparison.OrdinalIgnoreCase))) parts.Add(n);
        return string.Join(':', parts);
    }
}
