using System.Text.Json.Nodes;

namespace FileMCP.Core;

public static class FileMcpConstants
{
    public const string ProtocolFallback = "2025-03-26";
    public const string LatestLegacyProtocolVersion = "2025-11-25";
    public const string ModernProtocolVersion = "2026-07-28";
    public static readonly string[] LegacySupportedVersions = ["2025-03-26", "2025-06-18", "2025-11-25"];
    public static readonly string[] AllSupportedVersions = [ModernProtocolVersion, "2025-11-25", "2025-06-18", "2025-03-26"];
    public const string ServerName = "filemcp";
    public const string ServerVersion = "0.4.0-windows";
    public const string LocalAuthHeaderName = "X-FileMCP-Local-Token";

    public const int MaxFileBytes = 5_000_000;
    public const int MaxWriteBytes = 5_000_000;
    public const int MaxCharsReturned = 40_000;
    public const int MaxListEntries = 1_000;
    public const int MaxSearchResults = 200;
    public const int MaxSearchVisited = 50_000;
    public const int MaxSearchContentResults = 50;
    public const int MaxSearchContentFileBytes = 1_000_000;
    public const long MaxSearchContentBytesScanned = 50_000_000;
    public const int MaxSearchPreviewLineChars = 1_000;
    public const int MaxSearchPreviewChars = 60_000;
    public const int MaxReadRangeLines = 1_000;
    public const int MaxReadRangeChars = 80_000;
    public const int MaxToolProcessOutputBytes = 100_000;
    public const int MaxGitSafetyOutputBytes = 2_000_000;
    public const int MaxHttpRequestHeaderBytes = 64_000;
    public const int MaxHttpRequestBodyBytes = 8_000_000;
}

public sealed record LocalMcpConfiguration(
    string TunnelId,
    string ApiKey,
    string Profile,
    ushort Port,
    string AllowedDirectory,
    string HealthAddress,
    string GitUserName,
    string GitUserEmail,
    bool EnableCommands);

public enum LocalMcpRuntimeStatus
{
    Stopped,
    Starting,
    Running,
    Stopping,
    Failed,
}

public sealed record LocalMcpRuntimeState(LocalMcpRuntimeStatus Status, string? Error = null)
{
    public static LocalMcpRuntimeState Stopped { get; } = new(LocalMcpRuntimeStatus.Stopped);
    public static LocalMcpRuntimeState Starting { get; } = new(LocalMcpRuntimeStatus.Starting);
    public static LocalMcpRuntimeState Running { get; } = new(LocalMcpRuntimeStatus.Running);
    public static LocalMcpRuntimeState Stopping { get; } = new(LocalMcpRuntimeStatus.Stopping);
    public static LocalMcpRuntimeState Failed(string message) => new(LocalMcpRuntimeStatus.Failed, message);
}

public sealed class FileMcpException(string message) : Exception(message);

internal sealed record ToolCallOutput(JsonArray Content, JsonObject StructuredContent);

public sealed class FileMcpSettings
{
    public string TunnelId { get; set; } = "";
    public string Profile { get; set; } = "filemcp";
    public int Port { get; set; } = 8008;
    public string AllowedDirectory { get; set; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "FileMCP");
    public string HealthAddress { get; set; } = "127.0.0.1:0";
    public string GitUserName { get; set; } = "";
    public string GitUserEmail { get; set; } = "";
    public bool EnableCommands { get; set; }
}
