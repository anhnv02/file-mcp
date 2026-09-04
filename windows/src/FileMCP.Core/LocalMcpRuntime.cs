using System.Collections;
using System.Security.Cryptography;
using System.Text;

namespace FileMCP.Core;

internal sealed class ProfileLock : IDisposable
{
    private readonly Mutex _mutex;
    private bool _held;

    public ProfileLock(string profile)
    {
        var hash = Fnv1A64(Encoding.UTF8.GetBytes(profile));
        _mutex = new Mutex(false, $@"Local\FileMCP-profile-{hash:x16}");
    }

    public void Acquire()
    {
        if (_held) return;
        try { _held = _mutex.WaitOne(0); }
        catch (AbandonedMutexException) { _held = true; }
        if (!_held) throw new FileMcpException("This tunnel profile is already in use by another FileMCP instance.");
    }

    public void Dispose()
    {
        if (_held) { try { _mutex.ReleaseMutex(); } catch { } _held = false; }
        _mutex.Dispose();
    }

    private static ulong Fnv1A64(IEnumerable<byte> bytes)
    {
        ulong hash = 1469598103934665603UL;
        foreach (var value in bytes) hash = (hash ^ value) * 1099511628211UL;
        return hash;
    }
}

public sealed class LocalMcpRuntime : IAsyncDisposable
{
    private readonly SemaphoreSlim _serial = new(1, 1);
    private readonly object _stateGate = new();
    private readonly string? _profileDirectoryOverride;
    private LocalMcpRuntimeState _state = LocalMcpRuntimeState.Stopped;
    private CancellationTokenSource? _startupCts;
    private LocalMcpServer? _server;
    private ManagedProcess? _tunnelProcess;
    private ProfileLock? _profileLock;
    private bool _requestedStop;

    public LocalMcpRuntime(string? profileDirectory = null) => _profileDirectoryOverride = profileDirectory;

    public event Action<LocalMcpRuntimeState>? StateChanged;
    public event Action<string>? Log;

    public LocalMcpRuntimeState State { get { lock (_stateGate) return _state; } }

    public async Task StartAsync(LocalMcpConfiguration configuration)
    {
        await _serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (State.Status is not (LocalMcpRuntimeStatus.Stopped or LocalMcpRuntimeStatus.Failed)) return;
            if (_requestedStop) { _requestedStop = false; SetState(LocalMcpRuntimeState.Stopped); return; }
            SetState(LocalMcpRuntimeState.Starting);
            EmitLog("[Runtime] Starting FileMCP...\n");
            _startupCts?.Dispose(); _startupCts = new CancellationTokenSource();
            var cancellationToken = _startupCts.Token;
            try
            {
                var healthAddress = ValidateConfiguration(configuration);
                _profileLock = new ProfileLock(configuration.Profile); _profileLock.Acquire();
                var localAuthToken = MakeLocalAuthToken();
                _server = new LocalMcpServer(configuration.Port, configuration.AllowedDirectory, configuration.GitUserName, configuration.GitUserEmail, configuration.EnableCommands, localAuthToken, EmitLog);
                await _server.StartAsync(cancellationToken).ConfigureAwait(false);

                var tunnelClient = TunnelClientPath(); var profileDirectory = TunnelProfileDirectory();
                var environment = TunnelClientEnvironment(configuration.ApiKey, localAuthToken);
                var localAuthHeader = $"{FileMcpConstants.LocalAuthHeaderName}: env:FILEMCP_LOCAL_AUTH_TOKEN";
                environment["MCP_EXTRA_HEADERS"] = localAuthHeader; environment["MCP_DISCOVERY_EXTRA_HEADERS"] = localAuthHeader;
                string[] sensitive = [configuration.ApiKey, localAuthToken];

                EmitLog("[Tunnel] Configuring Secure MCP Tunnel…\n");
                var initResult = await ProcessRunner.RunAsync(tunnelClient,
                    ["init", "--sample", "sample_mcp_remote_no_auth", "--profile", configuration.Profile, "--profile-dir", profileDirectory, "--force", "--tunnel-id", configuration.TunnelId, "--mcp-server-url", $"http://127.0.0.1:{configuration.Port}/mcp", "--health-listen-addr", healthAddress],
                    environment: environment, timeoutSeconds: 30, outputLimitBytes: 250_000, cancellationToken: cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested(); RequireSuccess(initResult, "tunnel-client init", sensitive);

                EmitLog("[Tunnel] Checking tunnel configuration…\n");
                var doctorResult = await ProcessRunner.RunAsync(tunnelClient,
                    ["doctor", "--profile", configuration.Profile, "--profile-dir", profileDirectory, "--health-listen-addr", healthAddress, "--explain"],
                    environment: environment, timeoutSeconds: 30, outputLimitBytes: 250_000, cancellationToken: cancellationToken).ConfigureAwait(false);
                cancellationToken.ThrowIfCancellationRequested(); RequireSuccess(doctorResult, "tunnel-client doctor", sensitive);

                _tunnelProcess = ProcessRunner.StartManaged(tunnelClient,
                    ["run", "--profile", configuration.Profile, "--profile-dir", profileDirectory, "--health-listen-addr", healthAddress],
                    null, environment,
                    text => EmitLog("[Tunnel] " + Redact(text, sensitive)),
                    exitCode => _ = Task.Run(() => TunnelDidExitAsync(exitCode)));
                SetState(LocalMcpRuntimeState.Running);
                EmitLog($"[Runtime] OpenAI Secure MCP Tunnel started. Command execution: {(configuration.EnableCommands ? "enabled" : "disabled")}.\n");
            }
            catch (OperationCanceledException) when (_requestedStop || _startupCts?.IsCancellationRequested == true)
            {
                FinishStop();
            }
            catch (Exception ex)
            {
                CleanupRuntime();
                SetState(LocalMcpRuntimeState.Failed(ex.Message));
                EmitLog("[Runtime] ERROR: " + ex.Message + "\n");
            }
        }
        finally { _serial.Release(); }
    }

    public async Task StopAsync()
    {
        _requestedStop = true; _startupCts?.Cancel();
        await _serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (State.Status == LocalMcpRuntimeStatus.Stopped) { _requestedStop = false; return; }
            if (State.Status != LocalMcpRuntimeStatus.Stopping) SetState(LocalMcpRuntimeState.Stopping);
            EmitLog("[Runtime] Disconnecting...\n");
            if (_tunnelProcess is not null) await _tunnelProcess.StopAsync().ConfigureAwait(false);
            FinishStop();
        }
        finally { _serial.Release(); }
    }

    public async Task ShutdownAsync()
    {
        _requestedStop = true; _startupCts?.Cancel();
        await _serial.WaitAsync().ConfigureAwait(false);
        try { _tunnelProcess?.StopSynchronously(); FinishStop(); }
        finally { _serial.Release(); }
    }

    private async Task TunnelDidExitAsync(int exitCode)
    {
        await _serial.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_tunnelProcess is null && State.Status == LocalMcpRuntimeStatus.Stopped) return;
            _tunnelProcess?.Dispose(); _tunnelProcess = null; _server?.Stop(); _server = null; _profileLock?.Dispose(); _profileLock = null;
            if (_requestedStop) { _requestedStop = false; SetState(LocalMcpRuntimeState.Stopped); EmitLog("[Runtime] Tunnel stopped.\n"); }
            else if (exitCode == 0) { SetState(LocalMcpRuntimeState.Stopped); EmitLog("[Runtime] Tunnel stopped.\n"); }
            else { var message = $"Tunnel stopped unexpectedly (exit status {exitCode})."; SetState(LocalMcpRuntimeState.Failed(message)); EmitLog("[Runtime] " + message + "\n"); }
        }
        finally { _serial.Release(); }
    }

    private void FinishStop()
    {
        CleanupRuntime(); _requestedStop = false; SetState(LocalMcpRuntimeState.Stopped); EmitLog("[Runtime] Tunnel stopped.\n");
    }

    private void CleanupRuntime()
    {
        _server?.Stop(); _server = null; _tunnelProcess?.Dispose(); _tunnelProcess = null; _profileLock?.Dispose(); _profileLock = null;
    }

    public static string ValidateConfiguration(LocalMcpConfiguration configuration)
    {
        foreach (var (label, value) in new[] { ("Tunnel ID", configuration.TunnelId), ("Runtime API key", configuration.ApiKey), ("Profile", configuration.Profile), ("Shared directory", configuration.AllowedDirectory) })
            if (string.IsNullOrWhiteSpace(value)) throw new FileMcpException($"{label} cannot be empty.");
        if (!IsValidTunnelId(configuration.TunnelId)) throw new FileMcpException("Tunnel ID must match tunnel_<32 lowercase letters or digits>.");
        if (!IsValidProfileName(configuration.Profile)) throw new FileMcpException("Profile must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 128 characters).");
        if (configuration.Port == 0) throw new FileMcpException("MCP port must be between 1 and 65535.");
        return NormalizeHealthAddress(configuration.HealthAddress) ?? throw new FileMcpException("Health listener must use localhost, 127.0.0.1, or [::1] with a port from 0 to 65535.");
    }

    public static bool IsValidTunnelId(string value) => value.Length == 39 && value.StartsWith("tunnel_", StringComparison.Ordinal) && value[7..].All(ch => (ch >= 'a' && ch <= 'z') || char.IsAsciiDigit(ch));
    public static bool IsValidProfileName(string value) => value.Length is >= 1 and <= 128 && char.IsAsciiLetterOrDigit(value[0]) && value.Skip(1).All(ch => char.IsAsciiLetterOrDigit(ch) || ch is '.' or '_' or '-');

    public static string? NormalizeHealthAddress(string value)
    {
        var trimmed = value.Trim(); if (trimmed.Length == 0) return "127.0.0.1:0";
        if (trimmed.StartsWith('[')) { var close = trimmed.IndexOf(']'); if (close < 0 || trimmed[1..close].ToLowerInvariant() != "::1") return null; var rest = trimmed[(close + 1)..]; if (!rest.StartsWith(':') || !ValidHealthPort(rest[1..])) return null; return "[::1]:" + rest[1..]; }
        var parts = trimmed.Split(':', 2); if (parts.Length != 2 || (parts[0].ToLowerInvariant() is not ("127.0.0.1" or "localhost")) || !ValidHealthPort(parts[1])) return null;
        return parts[0].ToLowerInvariant() + ":" + parts[1];
    }

    private static bool ValidHealthPort(string value) => value.Length > 0 && value.All(char.IsAsciiDigit) && uint.TryParse(value, out var port) && port <= 65535;

    private Dictionary<string, string> TunnelClientEnvironment(string apiKey, string localAuthToken)
    {
        var inherited = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>().ToDictionary(e => (string)e.Key, e => (string?)e.Value ?? "", StringComparer.OrdinalIgnoreCase);
        string[] pass = ["PATH","USERPROFILE","HOMEDRIVE","HOMEPATH","APPDATA","LOCALAPPDATA","TEMP","TMP","SystemRoot","WINDIR","LANG","LC_ALL","LC_CTYPE","HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","http_proxy","https_proxy","all_proxy"];
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var key in pass) if (inherited.TryGetValue(key, out var value) && value.Length > 0) result[key] = value;
        foreach (var pair in inherited.Where(pair => pair.Key.StartsWith("MCP_TEST_", StringComparison.OrdinalIgnoreCase))) result[pair.Key] = pair.Value;
        var noProxy = (inherited.GetValueOrDefault("NO_PROXY") ?? inherited.GetValueOrDefault("no_proxy") ?? "").Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();
        foreach (var loopback in new[] { "127.0.0.1", "localhost", "::1" }) if (!noProxy.Contains(loopback, StringComparer.OrdinalIgnoreCase)) noProxy.Add(loopback);
        result["NO_PROXY"] = result["no_proxy"] = string.Join(',', noProxy); result["CONTROL_PLANE_API_KEY"] = apiKey; result["FILEMCP_LOCAL_AUTH_TOKEN"] = localAuthToken;
        return result;
    }

    private string TunnelProfileDirectory()
    {
        var directory = _profileDirectoryOverride ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "FileMCP", "tunnel-profiles");
        Directory.CreateDirectory(directory); return directory;
    }

    private static string TunnelClientPath()
    {
        var sibling = Path.Combine(AppContext.BaseDirectory, "tunnel-client.exe"); if (File.Exists(sibling)) return sibling;
        var overridePath = Environment.GetEnvironmentVariable("MCP_TUNNEL_CLIENT"); if (!string.IsNullOrWhiteSpace(overridePath) && File.Exists(overridePath)) return overridePath;
        throw new FileMcpException("tunnel-client.exe was not found beside FileMCP.exe.");
    }

    private static string MakeLocalAuthToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32)).ToLowerInvariant();

    private void RequireSuccess(ProcessResult result, string operation, IReadOnlyList<string> sensitive)
    {
        if (result.TimedOut) throw new FileMcpException(operation + " timed out.");
        if (result.ExitCode != 0) throw new FileMcpException(operation + " failed: " + Redact(string.IsNullOrEmpty(result.Stderr) ? result.Stdout : result.Stderr, sensitive));
        if (result.Stdout.Length > 0) EmitLog("[Tunnel] " + Redact(result.Stdout, sensitive) + (result.Stdout.EndsWith('\n') ? "" : "\n"));
        if (result.Stderr.Length > 0) EmitLog("[Tunnel] " + Redact(result.Stderr, sensitive) + (result.Stderr.EndsWith('\n') ? "" : "\n"));
    }

    private static string Redact(string text, IReadOnlyList<string> sensitive) { foreach (var secret in sensitive.Where(s => s.Length > 0)) text = text.Replace(secret, "[REDACTED]", StringComparison.Ordinal); return text; }
    private void EmitLog(string text) => Log?.Invoke(text);
    private void SetState(LocalMcpRuntimeState state) { lock (_stateGate) _state = state; StateChanged?.Invoke(state); }

    public async ValueTask DisposeAsync() { await ShutdownAsync().ConfigureAwait(false); _serial.Dispose(); _startupCts?.Dispose(); }
}
