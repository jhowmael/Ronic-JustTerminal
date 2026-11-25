using System.Collections;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static RonicJustTerminal.Native;

namespace RonicJustTerminal;

/// Uma sessão de terminal: um shell (PowerShell, cmd, WSL…) rodando num pseudo-console (ConPTY).
///
/// Camada de PTY do Windows. Não sabe nada de abas nem de interface: recebe bytes para escrever,
/// entrega bytes lidos e avisa quando o processo termina. Equivalente a PTYSession.swift no macOS.
///
/// Desempenho:
/// - leitura numa thread dedicada (ReadFile bloqueante, sem polling);
/// - controle de fluxo: se a interface ainda não desenhou HighWater bytes, a leitura pausa até
///   chegar o "ack" (um `dir /s` gigante não congela a janela).
internal sealed class ConPtySession
{
    private const int HighWater = 512 * 1024;
    private const int LowWater = 128 * 1024;

    public int Id { get; }

    /// Chamado na thread de leitura com cada bloco lido.
    public Action<byte[]>? Data;
    /// Chamado (em outra thread) quando o processo termina, depois de toda a saída ter sido lida.
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

        // O ConPTY duplicou estas pontas; as nossas cópias podem fechar.
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
            // Sem herdar os handles padrão do app: toda a E/S do shell passa pelo pseudo-console.
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
                if (_killed) continue;   // aba fechada: só drena até o fim
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

    /// A interface confirmou que desenhou `bytes` bytes desta sessão.
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
        // Fechar o pseudo-console faz a leitura receber EOF depois de entregar o que sobrou.
        ClosePseudoConsoleOnce();
        _readerDone.Wait(TimeSpan.FromSeconds(5));
        _writes.CompleteAdding();
        _input?.Dispose();
        _output?.Dispose();
        CloseHandle(_pi.hThread);
        CloseHandle(_pi.hProcess);
        if (!_killed) Exited?.Invoke((int)code);
    }

    /// Fecha a aba: encerra o pseudo-console (os processos recebem CTRL_CLOSE) e, se algum
    /// ignorar, força o fim depois de 3 s.
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

    /// Ambiente do shell: o do app + variáveis de terminal. Bloco Unicode ordenado ("k=v\0…\0\0").
    private static IntPtr BuildEnvironmentBlock(IReadOnlyDictionary<string, string> extraEnv)
    {
        var vars = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (DictionaryEntry e in Environment.GetEnvironmentVariables())
            vars[(string)e.Key] = (string?)e.Value ?? "";
        foreach (var (k, v) in extraEnv) vars[k] = v;   // integração do perfil (PROMPT, PROMPT_COMMAND…)
        vars["COLORTERM"] = "truecolor";
        vars["TERM_PROGRAM"] = "RonicJustTerminal";
        vars["TERM_PROGRAM_VERSION"] = Application.ProductVersion.Split('+')[0];
        // WSL repassa estas variáveis para o Linux (WSLENV), então o shell de lá também as vê.
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
