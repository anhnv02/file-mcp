using System.Text;
using System.Text.Json;

namespace FileMCP.Core;

internal sealed record RipgrepOutput(
    string Stdout, bool TimedOut, bool OutputLimited, int SearchErrors,
    IReadOnlyList<string> IgnoredPaths, bool DiagnosticsLimited);

internal sealed record RipgrepLine(string Path, int LineNumber, string Text, bool IsMatch);

/// <summary>Runs the bundled ripgrep with a fixed argument set. Callers still validate every returned path.</summary>
internal sealed class Ripgrep
{
    public const string EnvironmentOverrideKey = "FILEMCP_RG";
    public const int MaxFileBytes = 1_000_000;
    public const int OutputLimitBytes = 8_000_000;
    public const int TimeoutSeconds = 30;
    public static readonly string[] ExcludedDirectoryNames = [".git", ".venv", "__pycache__", "build", "dist", "node_modules"];

    private readonly SemaphoreSlim _slots = new(2, 2);

    public Ripgrep() : this(LocateExecutable())
    {
    }

    public Ripgrep(string? executable) => Executable = executable;

    public string? Executable { get; }

    public static string? LocateExecutable()
    {
        var overridePath = Environment.GetEnvironmentVariable(EnvironmentOverrideKey);
        if (!string.IsNullOrEmpty(overridePath))
        {
            return File.Exists(overridePath) ? overridePath : null;
        }
        var sibling = Path.Combine(AppContext.BaseDirectory, "rg.exe");
        return File.Exists(sibling) ? sibling : null;
    }

    /// <summary><paramref name="arguments"/> must not contain positional values; <paramref name="target"/> is passed after <c>--</c>.</summary>
    /// <remarks><paramref name="limitFileSize"/> skips files over <see cref="MaxFileBytes"/>; file listings pass false so large files are still reported.</remarks>
    public async Task<RipgrepOutput> RunAsync(
        IReadOnlyList<string> arguments, bool includeIgnored, string cwd, string target, CancellationToken cancellationToken,
        bool limitFileSize = true)
    {
        if (Executable is null)
        {
            throw new FileMcpException("ripgrep (rg.exe) was not found beside FileMCP; search tools are unavailable");
        }

        await _slots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var debugEnabled = arguments.Contains("--debug", StringComparer.Ordinal);
            var fullArguments = new List<string>
            {
                "--no-config", "--hidden", "--no-follow", "--no-ignore-global", "--no-require-git",
                "--engine=default", "--color=never",
            };
            if (limitFileSize) fullArguments.Add($"--max-filesize={MaxFileBytes}");
            fullArguments.AddRange(arguments);
            // Exclusions come after caller globs so a caller glob cannot re-include them.
            if (includeIgnored)
            {
                fullArguments.AddRange(["--no-ignore", "--iglob=!.git/"]);
            }
            else
            {
                fullArguments.AddRange(ExcludedDirectoryNames.Select(name => $"--iglob=!{name}/"));
            }
            fullArguments.AddRange(["--", target]);

            var result = await ProcessRunner.RunAsync(
                Executable, fullArguments, cwd, MinimalEnvironment(), TimeoutSeconds, OutputLimitBytes,
                cancellationToken, utf8Output: true).ConfigureAwait(false);

            var stdout = result.Stdout;
            if (result.StdoutTruncated)
            {
                var marker = stdout.LastIndexOf("\n\n[...truncated ", StringComparison.Ordinal);
                if (marker >= 0) stdout = stdout[..marker];
            }
            var stderrLines = result.Stderr.Split('\n')
                .Select(line => line.TrimEnd('\r'))
                .ToList();
            var errorLines = stderrLines
                .Where(line => line.StartsWith("rg: ", StringComparison.Ordinal) &&
                    (!debugEnabled || (!line.StartsWith("rg: DEBUG|", StringComparison.Ordinal) &&
                        !line.StartsWith("rg: TRACE|", StringComparison.Ordinal))))
                .ToList();
            // Per-path I/O failures ("(os error N)") still produce a usable, partial result.
            // Anything else with exit code 2 (bad regex, unknown type, invalid glob) is a request error.
            var hasOnlyPathErrors = errorLines.Count > 0 &&
                errorLines.All(line => line.Contains("(os error ", StringComparison.Ordinal));
            if (result.ExitCode == 2 && !result.TimedOut && stdout.Length == 0 && !hasOnlyPathErrors)
            {
                var message = result.Stderr.Trim();
                throw new FileMcpException(message.Length == 0 ? "ripgrep failed" : message);
            }
            return new RipgrepOutput(
                stdout, result.TimedOut, result.StdoutTruncated, errorLines.Count,
                debugEnabled ? IgnoredPaths(result.Stderr) : [], debugEnabled && result.StderrTruncated);
        }
        finally
        {
            _slots.Release();
        }
    }

    private static List<string> IgnoredPaths(string stderr)
    {
        var paths = new List<string>();
        foreach (var rawLine in stderr.Split('\n'))
        {
            var line = rawLine.TrimEnd('\r');
            var start = line.IndexOf(": ignoring ", StringComparison.Ordinal);
            var end = line.LastIndexOf(": Ignore(", StringComparison.Ordinal);
            if (start < 0 || end <= start) continue;
            start += ": ignoring ".Length;
            var path = NormalizedPath(line[start..end]);
            if (path.Length > 0) paths.Add(path);
        }
        return paths;
    }

    public static string NormalizedPath(string value)
    {
        var normalized = value.Replace('\\', '/');
        return normalized.StartsWith("./", StringComparison.Ordinal) ? normalized[2..] : normalized;
    }

    /// <summary>Parses <c>--null</c> separated paths (from <c>--files</c> or <c>--files-with-matches</c>).</summary>
    public static List<string> NulSeparatedPaths(RipgrepOutput output)
    {
        var parts = output.Stdout.Split('\0', StringSplitOptions.RemoveEmptyEntries).ToList();
        if (output.OutputLimited && parts.Count > 0) parts.RemoveAt(parts.Count - 1);
        return parts.Select(NormalizedPath).ToList();
    }

    /// <summary>Parses <c>--count --null</c> output: <c>path\0count\n</c> records.</summary>
    public static List<(string Path, int Count)> NulSeparatedCounts(RipgrepOutput output)
    {
        var results = new List<(string Path, int Count)>();
        var text = output.Stdout;
        var position = 0;
        while (position < text.Length)
        {
            var separator = text.IndexOf('\0', position);
            if (separator < 0) break;
            var newline = text.IndexOf('\n', separator + 1);
            if (newline < 0) break;
            if (int.TryParse(text.AsSpan(separator + 1, newline - separator - 1).TrimEnd('\r'), out var count))
            {
                results.Add((NormalizedPath(text[position..separator]), count));
            }
            position = newline + 1;
        }
        return results;
    }

    /// <summary>Parses <c>--json</c> match and context events. Multi-line matches are split into one entry per line.</summary>
    public static List<RipgrepLine> JsonLines(RipgrepOutput output)
    {
        var lines = new List<RipgrepLine>();
        foreach (var record in output.Stdout.Split('\n'))
        {
            if (record.Length == 0) continue;
            JsonDocument document;
            try
            {
                document = JsonDocument.Parse(record);
            }
            catch (JsonException)
            {
                continue;
            }

            using (document)
            {
                var root = document.RootElement;
                if (root.ValueKind != JsonValueKind.Object ||
                    !root.TryGetProperty("type", out var typeElement) ||
                    typeElement.GetString() is not ("match" or "context") ||
                    !root.TryGetProperty("data", out var data) ||
                    !data.TryGetProperty("path", out var pathElement) || JsonText(pathElement) is not { } path ||
                    !data.TryGetProperty("lines", out var linesElement) || JsonText(linesElement) is not { } text ||
                    !data.TryGetProperty("line_number", out var numberElement) || !numberElement.TryGetInt32(out var lineNumber))
                {
                    continue;
                }

                var isMatch = typeElement.GetString() == "match";
                var parts = text.Split('\n').ToList();
                if (parts.Count > 1 && parts[^1].Length == 0) parts.RemoveAt(parts.Count - 1);
                for (var offset = 0; offset < parts.Count; offset++)
                {
                    var part = parts[offset].EndsWith('\r') ? parts[offset][..^1] : parts[offset];
                    lines.Add(new RipgrepLine(NormalizedPath(path), lineNumber + offset, part, isMatch));
                }
            }
        }
        return lines;
    }

    private static string? JsonText(JsonElement element)
    {
        if (element.ValueKind != JsonValueKind.Object) return null;
        if (element.TryGetProperty("text", out var text) && text.ValueKind == JsonValueKind.String) return text.GetString();
        if (element.TryGetProperty("bytes", out var bytes) && bytes.ValueKind == JsonValueKind.String)
        {
            try
            {
                return Encoding.UTF8.GetString(Convert.FromBase64String(bytes.GetString()!));
            }
            catch (FormatException)
            {
                return null;
            }
        }
        return null;
    }

    private static Dictionary<string, string> MinimalEnvironment()
    {
        var environment = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var name in new[] { "SystemRoot", "WINDIR" })
        {
            var value = Environment.GetEnvironmentVariable(name);
            if (!string.IsNullOrEmpty(value)) environment[name] = value;
        }
        return environment;
    }
}
