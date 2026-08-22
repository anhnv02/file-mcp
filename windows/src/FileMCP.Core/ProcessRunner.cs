using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace FileMCP.Core;

public sealed record ProcessResult(int ExitCode, string Stdout, string Stderr, bool TimedOut);

internal sealed class BoundedTextBuffer
{
    private readonly int _limitBytes;
    private readonly object _gate = new();
    private readonly StringBuilder _text = new();
    private int _keptBytes;
    private long _omittedBytes;

    public BoundedTextBuffer(int limitBytes) => _limitBytes = Math.Max(1, limitBytes);

    public void Append(ReadOnlySpan<char> chars)
    {
        if (chars.IsEmpty)
        {
            return;
        }

        lock (_gate)
        {
            var raw = chars.ToString();
            var bytes = Encoding.UTF8.GetByteCount(raw);
            var remaining = Math.Max(0, _limitBytes - _keptBytes);
            if (remaining > 0)
            {
                var kept = ClipToUtf8Bytes(raw, remaining);
                _text.Append(kept);
                _keptBytes += Encoding.UTF8.GetByteCount(kept);
                _omittedBytes += bytes - Encoding.UTF8.GetByteCount(kept);
            }
            else
            {
                _omittedBytes += bytes;
            }
        }
    }

    public override string ToString()
    {
        lock (_gate)
        {
            return _omittedBytes > 0
                ? _text + $"\n\n[...truncated {_omittedBytes} bytes...]"
                : _text.ToString();
        }
    }

    private static string ClipToUtf8Bytes(string value, int limit)
    {
        if (Encoding.UTF8.GetByteCount(value) <= limit)
        {
            return value;
        }

        var builder = new StringBuilder(value.Length);
        var bytes = 0;
        foreach (var rune in value.EnumerateRunes())
        {
            var runeBytes = rune.Utf8SequenceLength;
            if (bytes + runeBytes > limit)
            {
                break;
            }
            builder.Append(rune.ToString());
            bytes += runeBytes;
        }
        return builder.ToString();
    }
}

public static class ProcessRunner
{
    public const int MaxCommandTimeoutSeconds = 120;
    public const int DefaultCommandTimeoutSeconds = 30;
    public const int DefaultOutputLimitBytes = 1_000_000;

    public static async Task<ProcessResult> RunAsync(
        string executable,
        IReadOnlyList<string> arguments,
        string? cwd = null,
        IReadOnlyDictionary<string, string>? environment = null,
        int timeoutSeconds = DefaultCommandTimeoutSeconds,
        int outputLimitBytes = DefaultOutputLimitBytes,
        CancellationToken cancellationToken = default)
    {
        ValidateProcessStrings(executable, arguments, cwd, environment);
        var process = StartProcess(executable, arguments, cwd, environment);
        using var job = WindowsJob.CreateAndAssign(process);
        var stdout = new BoundedTextBuffer(outputLimitBytes);
        var stderr = new BoundedTextBuffer(outputLimitBytes);
        var stdoutTask = DrainAsync(process.StandardOutput, stdout);
        var stderrTask = DrainAsync(process.StandardError, stderr);

        var timeout = Math.Max(1, Math.Min(timeoutSeconds, MaxCommandTimeoutSeconds));
        var timedOut = false;
        try
        {
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeoutCts.CancelAfter(TimeSpan.FromSeconds(timeout));
            try
            {
                await process.WaitForExitAsync(timeoutCts.Token).ConfigureAwait(false);
                job?.Terminate(1);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                timedOut = true;
                job?.Terminate(1);
                KillProcessTree(process);
            }
            catch (OperationCanceledException)
            {
                job?.Terminate(1);
                KillProcessTree(process);
            }

            if (!process.HasExited)
            {
                job?.Terminate(1);
                KillProcessTree(process);
            }
            if (!process.HasExited)
            {
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
        }
        finally
        {
            await Task.WhenAll(stdoutTask, stderrTask).ConfigureAwait(false);
        }

        return new ProcessResult(
            process.HasExited ? process.ExitCode : -1,
            stdout.ToString(),
            stderr.ToString(),
            timedOut);
    }

    public static ManagedProcess StartManaged(
        string executable,
        IReadOnlyList<string> arguments,
        string? cwd,
        IReadOnlyDictionary<string, string>? environment,
        Action<string> onOutput,
        Action<int> onExit)
    {
        ValidateProcessStrings(executable, arguments, cwd, environment);
        var process = StartProcess(executable, arguments, cwd, environment);
        return new ManagedProcess(process, WindowsJob.CreateAndAssign(process), onOutput, onExit);
    }

    internal static void KillProcessTree(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill(entireProcessTree: true);
            }
        }
        catch (InvalidOperationException)
        {
        }
        catch (Win32Exception)
        {
        }
    }

    private static Process StartProcess(
        string executable,
        IReadOnlyList<string> arguments,
        string? cwd,
        IReadOnlyDictionary<string, string>? environment)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
            WorkingDirectory = string.IsNullOrWhiteSpace(cwd) ? Environment.CurrentDirectory : cwd,
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }
        if (environment is not null)
        {
            startInfo.Environment.Clear();
            foreach (var pair in environment)
            {
                startInfo.Environment[pair.Key] = pair.Value;
            }
        }

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!process.Start())
            {
                throw new FileMcpException($"Could not launch {executable}.");
            }
            process.StandardInput.Close();
            return process;
        }
        catch (Win32Exception ex)
        {
            process.Dispose();
            throw new FileMcpException($"Could not launch {executable}: {ex.Message}");
        }
    }

    private static async Task DrainAsync(StreamReader reader, BoundedTextBuffer buffer)
    {
        var chars = new char[8192];
        while (true)
        {
            var read = await reader.ReadAsync(chars.AsMemory(0, chars.Length)).ConfigureAwait(false);
            if (read <= 0)
            {
                return;
            }
            buffer.Append(chars.AsSpan(0, read));
        }
    }

    private static void ValidateProcessStrings(
        string executable,
        IReadOnlyList<string> arguments,
        string? cwd,
        IReadOnlyDictionary<string, string>? environment)
    {
        if (executable.Contains('\0'))
        {
            throw new FileMcpException("Executable path contains a NUL byte.");
        }
        if (arguments.Any(value => value.Contains('\0')))
        {
            throw new FileMcpException("Process argument contains a NUL byte.");
        }
        if (cwd?.Contains('\0') == true)
        {
            throw new FileMcpException("Working directory contains a NUL byte.");
        }
        if (environment is null)
        {
            return;
        }
        foreach (var pair in environment)
        {
            if (string.IsNullOrEmpty(pair.Key) || pair.Key.Contains('=') || pair.Key.Contains('\0'))
            {
                throw new FileMcpException("Environment variable name is not valid for Windows process execution.");
            }
            if (pair.Value.Contains('\0'))
            {
                throw new FileMcpException("Environment variable value contains a NUL byte.");
            }
        }
    }
}

public sealed class ManagedProcess : IDisposable
{
    private readonly Process _process;
    private readonly WindowsJob? _job;
    private readonly Action<string> _onOutput;
    private readonly Action<int> _onExit;
    private readonly CancellationTokenSource _disposeCts = new();
    private int _exitReported;

    internal ManagedProcess(Process process, WindowsJob? job, Action<string> onOutput, Action<int> onExit)
    {
        _process = process;
        _job = job;
        _onOutput = onOutput;
        _onExit = onExit;
        _ = PumpAsync();
    }

    public bool IsRunning
    {
        get
        {
            try { return !_process.HasExited; }
            catch { return false; }
        }
    }

    public void Stop() => _ = StopAsync();

    public async Task StopAsync()
    {
        _job?.Terminate(1);
        ProcessRunner.KillProcessTree(_process);
        try
        {
            if (!_process.HasExited)
            {
                await _process.WaitForExitAsync().ConfigureAwait(false);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    public void StopSynchronously()
    {
        _job?.Terminate(1);
        ProcessRunner.KillProcessTree(_process);
        try
        {
            if (!_process.HasExited)
            {
                _process.WaitForExit(3000);
            }
        }
        catch (InvalidOperationException)
        {
        }
    }

    private async Task PumpAsync()
    {
        var stdout = PumpReaderAsync(_process.StandardOutput);
        var stderr = PumpReaderAsync(_process.StandardError);
        int exitCode;
        try
        {
            await _process.WaitForExitAsync(_disposeCts.Token).ConfigureAwait(false);
            exitCode = _process.ExitCode;
            _job?.Terminate(1);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        finally
        {
            try { await Task.WhenAll(stdout, stderr).ConfigureAwait(false); } catch { }
        }

        if (Interlocked.Exchange(ref _exitReported, 1) == 0)
        {
            _onExit(exitCode);
        }
    }

    private async Task PumpReaderAsync(StreamReader reader)
    {
        var chars = new char[4096];
        while (!_disposeCts.IsCancellationRequested)
        {
            int read;
            try
            {
                read = await reader.ReadAsync(chars.AsMemory(0, chars.Length), _disposeCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                return;
            }
            if (read <= 0)
            {
                return;
            }
            _onOutput(new string(chars, 0, read));
        }
    }

    public void Dispose()
    {
        _disposeCts.Cancel();
        StopSynchronously();
        _job?.Dispose();
        _process.Dispose();
        _disposeCts.Dispose();
    }
}

internal sealed class WindowsJob : IDisposable
{
    private readonly SafeFileHandle _handle;

    private WindowsJob(SafeFileHandle handle) => _handle = handle;

    public static WindowsJob? CreateAndAssign(Process process)
    {
        if (!OperatingSystem.IsWindows())
        {
            return null;
        }
        var handle = NativeMethods.CreateJobObjectW(IntPtr.Zero, null);
        if (handle.IsInvalid)
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            throw new FileMcpException($"Could not create a Windows Job Object: {new Win32Exception(error).Message}");
        }

        var limits = new NativeMethods.JobObjectExtendedLimitInformation
        {
            BasicLimitInformation = new NativeMethods.JobObjectBasicLimitInformation
            {
                LimitFlags = NativeMethods.JobObjectLimitKillOnJobClose,
            },
        };
        var size = Marshal.SizeOf<NativeMethods.JobObjectExtendedLimitInformation>();
        var pointer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, pointer, false);
            if (!NativeMethods.SetInformationJobObject(
                    handle,
                    NativeMethods.JobObjectInfoClass.ExtendedLimitInformation,
                    pointer,
                    (uint)size))
            {
                var error = Marshal.GetLastWin32Error();
                handle.Dispose();
                throw new FileMcpException($"Could not configure the Windows Job Object: {new Win32Exception(error).Message}");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }

        if (!NativeMethods.AssignProcessToJobObject(handle, process.Handle))
        {
            var error = Marshal.GetLastWin32Error();
            handle.Dispose();
            ProcessRunner.KillProcessTree(process);
            throw new FileMcpException($"Could not assign the process to a Windows Job Object: {new Win32Exception(error).Message}");
        }
        return new WindowsJob(handle);
    }

    public void Terminate(uint exitCode)
    {
        if (_handle.IsInvalid || _handle.IsClosed) return;
        _ = NativeMethods.TerminateJobObject(_handle, exitCode);
    }

    public void Dispose() => _handle.Dispose();

    private static class NativeMethods
    {
        internal const uint JobObjectLimitKillOnJobClose = 0x00002000;

        internal enum JobObjectInfoClass
        {
            ExtendedLimitInformation = 9,
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct IoCounters
        {
            public ulong ReadOperationCount;
            public ulong WriteOperationCount;
            public ulong OtherOperationCount;
            public ulong ReadTransferCount;
            public ulong WriteTransferCount;
            public ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectBasicLimitInformation
        {
            public long PerProcessUserTimeLimit;
            public long PerJobUserTimeLimit;
            public uint LimitFlags;
            public UIntPtr MinimumWorkingSetSize;
            public UIntPtr MaximumWorkingSetSize;
            public uint ActiveProcessLimit;
            public UIntPtr Affinity;
            public uint PriorityClass;
            public uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        internal struct JobObjectExtendedLimitInformation
        {
            public JobObjectBasicLimitInformation BasicLimitInformation;
            public IoCounters IoInfo;
            public UIntPtr ProcessMemoryLimit;
            public UIntPtr JobMemoryLimit;
            public UIntPtr PeakProcessMemoryUsed;
            public UIntPtr PeakJobMemoryUsed;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateJobObjectW(IntPtr jobAttributes, string? name);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetInformationJobObject(
            SafeFileHandle job,
            JobObjectInfoClass jobObjectInfoClass,
            IntPtr jobObjectInfo,
            uint jobObjectInfoLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool TerminateJobObject(SafeFileHandle job, uint exitCode);
    }
}
