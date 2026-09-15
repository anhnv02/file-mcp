using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Win32.SafeHandles;

namespace FileMCP.Core;

internal sealed record CodexHistoryMessage(string Role, string Content);

internal sealed record CodexHistoryImportResult(
    string ThreadId,
    string Title,
    string Cwd,
    int MessageCount,
    int TurnCount);

internal static class CodexHistoryImporter
{
    private const int MaxMessages = 500;
    private const int MaxConversationBytes = 2_000_000;
    private const int MaxTitleBytes = 500;

    internal static async Task<CodexHistoryImportResult> SaveAsync(
        string title,
        string cwd,
        IReadOnlyList<CodexHistoryMessage> messages,
        CancellationToken cancellationToken = default)
    {
        ValidateInput(title, cwd, messages);
        var codexExecutable = LocateCodexExecutable();
        var turns = ConversationTurns(messages);
        await using var creator = new CodexAppServerClient(codexExecutable);

        var threadId = "";
        var rolloutPath = "";
        var codexHome = "";
        try
        {
            codexHome = await creator.InitializeAsync(cancellationToken).ConfigureAwait(false);
            var start = await creator.RequestAsync(
                "thread/start",
                new JsonObject
                {
                    ["cwd"] = cwd,
                    ["ephemeral"] = false,
                    ["historyMode"] = "legacy",
                },
                cancellationToken: cancellationToken).ConfigureAwait(false);

            var thread = start["thread"] as JsonObject
                ?? throw new FileMcpException("Codex thread/start did not return a thread object.");
            threadId = thread["id"]?.GetValue<string>() ?? "";
            rolloutPath = thread["path"]?.GetValue<string>() ?? "";
            if (string.IsNullOrWhiteSpace(threadId) || string.IsNullOrWhiteSpace(rolloutPath))
            {
                throw new FileMcpException("Codex thread/start did not return a durable thread id and rollout path.");
            }

            await creator.RequestAsync(
                "thread/name/set",
                new JsonObject { ["threadId"] = threadId, ["name"] = title },
                cancellationToken: cancellationToken).ConfigureAwait(false);
            await creator.CloseAsync().ConfigureAwait(false);

            var rollout = ValidateRolloutPath(rolloutPath, codexHome, threadId, requireSessionMetadata: true);
            await AppendConversationTurnsAsync(turns, rollout, cancellationToken).ConfigureAwait(false);
            await VerifyConversationAsync(
                codexExecutable,
                threadId,
                title,
                cwd,
                turns,
                cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            await creator.CloseAsync().ConfigureAwait(false);
            if (!string.IsNullOrWhiteSpace(threadId))
            {
                await BestEffortCleanupAsync(codexExecutable, threadId, rolloutPath, codexHome).ConfigureAwait(false);
            }
            throw;
        }

        return new CodexHistoryImportResult(threadId, title, cwd, messages.Count, turns.Count);
    }

    internal static bool TryLocateCodexExecutable(out string path)
    {
        try
        {
            path = LocateCodexExecutable();
            return true;
        }
        catch
        {
            path = "";
            return false;
        }
    }

    private static void ValidateInput(string title, string cwd, IReadOnlyList<CodexHistoryMessage> messages)
    {
        if (!OperatingSystem.IsWindows())
            throw new FileMcpException("Codex history import through the Windows implementation requires Windows.");
        if (string.IsNullOrWhiteSpace(title)) throw new FileMcpException("title must not be empty");
        if (Encoding.UTF8.GetByteCount(title.Trim()) > MaxTitleBytes)
            throw new FileMcpException("title is too long (maximum 500 UTF-8 bytes)");
        if (string.IsNullOrWhiteSpace(cwd) || !Directory.Exists(cwd))
            throw new FileMcpException("Codex working directory does not exist.");
        if (messages.Count is < 1 or > MaxMessages)
            throw new FileMcpException($"messages must contain between 1 and {MaxMessages} entries");
        if (!string.Equals(messages[0].Role, "user", StringComparison.Ordinal))
            throw new FileMcpException("messages must start with a user message");

        var bytes = 0;
        foreach (var message in messages)
        {
            if (message.Role is not ("user" or "assistant"))
                throw new FileMcpException("message role must be user or assistant");
            if (string.IsNullOrEmpty(message.Content))
                throw new FileMcpException("message content must not be empty");
            bytes = checked(bytes + Encoding.UTF8.GetByteCount(message.Content));
            if (bytes > MaxConversationBytes)
                throw new FileMcpException("conversation content exceeds the 2 MB limit");
        }
    }

    private static List<(string User, List<string> Assistants)> ConversationTurns(
        IReadOnlyList<CodexHistoryMessage> messages)
    {
        var turns = new List<(string User, List<string> Assistants)>();
        string? currentUser = null;
        var assistants = new List<string>();
        foreach (var message in messages)
        {
            if (message.Role == "user")
            {
                if (currentUser is not null)
                {
                    turns.Add((currentUser, assistants));
                }
                currentUser = message.Content;
                assistants = [];
            }
            else if (currentUser is not null)
            {
                assistants.Add(message.Content);
            }
        }
        if (currentUser is not null) turns.Add((currentUser, assistants));
        return turns;
    }

    private static async Task AppendConversationTurnsAsync(
        IReadOnlyList<(string User, List<string> Assistants)> turns,
        string rolloutPath,
        CancellationToken cancellationToken)
    {
        var baseTime = DateTimeOffset.UtcNow;
        await using var stream = new FileStream(
            rolloutPath,
            FileMode.Append,
            FileAccess.Write,
            FileShare.Read | FileShare.Delete,
            bufferSize: 16_384,
            useAsync: true);
        await using var writer = new StreamWriter(stream, new UTF8Encoding(false), 16_384, leaveOpen: false)
        {
            NewLine = "\n",
        };

        for (var offset = 0; offset < turns.Count; offset++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var turn = turns[offset];
            var turnId = Guid.NewGuid().ToString("D").ToLowerInvariant();
            var turnTime = baseTime.AddMilliseconds(offset * 10);
            var timestamp = turnTime.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", CultureInfo.InvariantCulture);
            var startedAt = turnTime.ToUnixTimeSeconds();
            var completedAt = startedAt + 1;
            var records = new List<JsonObject>
            {
                Record(timestamp, "event_msg", new JsonObject
                {
                    ["type"] = "task_started",
                    ["turn_id"] = turnId,
                    ["started_at"] = startedAt,
                }),
                Record(timestamp, "response_item", new JsonObject
                {
                    ["type"] = "message",
                    ["id"] = MessageId(),
                    ["role"] = "user",
                    ["content"] = new JsonArray(new JsonObject { ["type"] = "input_text", ["text"] = turn.User }),
                    ["internal_chat_message_metadata_passthrough"] = new JsonObject
                    {
                        ["turn_id"] = turnId,
                        ["create_time"] = turnTime.ToUnixTimeMilliseconds() / 1000.0,
                    },
                }),
                Record(timestamp, "event_msg", new JsonObject
                {
                    ["type"] = "user_message",
                    ["message"] = turn.User,
                    ["images"] = new JsonArray(),
                    ["local_images"] = new JsonArray(),
                    ["audio"] = new JsonArray(),
                    ["local_audio"] = new JsonArray(),
                    ["text_elements"] = new JsonArray(),
                }),
            };

            for (var assistantIndex = 0; assistantIndex < turn.Assistants.Count; assistantIndex++)
            {
                var assistant = turn.Assistants[assistantIndex];
                var phase = assistantIndex == turn.Assistants.Count - 1 ? "final_answer" : "commentary";
                records.Add(Record(timestamp, "response_item", new JsonObject
                {
                    ["type"] = "message",
                    ["id"] = MessageId(),
                    ["role"] = "assistant",
                    ["content"] = new JsonArray(new JsonObject { ["type"] = "output_text", ["text"] = assistant }),
                    ["phase"] = phase,
                    ["internal_chat_message_metadata_passthrough"] = new JsonObject { ["turn_id"] = turnId },
                }));
                records.Add(Record(timestamp, "event_msg", new JsonObject
                {
                    ["type"] = "agent_message",
                    ["message"] = assistant,
                }));
            }

            records.Add(Record(timestamp, "event_msg", new JsonObject
            {
                ["type"] = "task_complete",
                ["turn_id"] = turnId,
                ["last_agent_message"] = turn.Assistants.Count == 0 ? null : turn.Assistants[^1],
                ["error"] = null,
                ["started_at"] = startedAt,
                ["completed_at"] = completedAt,
                ["duration_ms"] = 1_000,
            }));

            foreach (var record in records)
            {
                await writer.WriteLineAsync(record.ToJsonString().AsMemory(), cancellationToken).ConfigureAwait(false);
            }
        }
        await writer.FlushAsync(cancellationToken).ConfigureAwait(false);
        await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
    }

    private static JsonObject Record(string timestamp, string type, JsonObject payload) => new()
    {
        ["timestamp"] = timestamp,
        ["type"] = type,
        ["payload"] = payload,
    };

    private static string MessageId() => "msg_" + Guid.NewGuid().ToString("N").ToLowerInvariant();

    private static async Task VerifyConversationAsync(
        string executable,
        string threadId,
        string title,
        string cwd,
        IReadOnlyList<(string User, List<string> Assistants)> expectedTurns,
        CancellationToken cancellationToken)
    {
        await using var verifier = new CodexAppServerClient(executable);
        _ = await verifier.InitializeAsync(cancellationToken).ConfigureAwait(false);
        var listed = await verifier.RequestAsync(
            "thread/list",
            new JsonObject
            {
                ["cwd"] = cwd,
                ["limit"] = 100,
                ["useStateDbOnly"] = false,
            },
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var threads = listed["data"] as JsonArray
            ?? throw new FileMcpException("Codex thread/list returned an invalid result.");
        var matchingThread = threads.OfType<JsonObject>().FirstOrDefault(item =>
            string.Equals(item["id"]?.GetValue<string>(), threadId, StringComparison.Ordinal));
        if (matchingThread is null)
            throw new FileMcpException("Codex did not index the imported conversation under the requested working directory.");
        if (matchingThread["name"] is JsonValue nameValue && nameValue.TryGetValue<string>(out var actualName)
            && !string.Equals(actualName, title, StringComparison.Ordinal))
            throw new FileMcpException("Codex changed the imported conversation title.");

        await verifier.RequestAsync(
            "thread/resume",
            new JsonObject { ["threadId"] = threadId },
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var result = await verifier.RequestAsync(
            "thread/turns/list",
            new JsonObject
            {
                ["threadId"] = threadId,
                ["limit"] = 500,
                ["itemsView"] = "full",
                ["sortDirection"] = "asc",
            },
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var actualTurns = result["data"] as JsonArray
            ?? throw new FileMcpException("Codex thread/turns/list returned an invalid result.");
        if (actualTurns.Count != expectedTurns.Count)
            throw new FileMcpException("Codex could not hydrate all imported conversation turns.");

        for (var turnIndex = 0; turnIndex < expectedTurns.Count; turnIndex++)
        {
            var actualTurn = actualTurns[turnIndex] as JsonObject
                ?? throw new FileMcpException($"Codex hydrated turn {turnIndex + 1} with an invalid shape.");
            if (!string.Equals(actualTurn["status"]?.GetValue<string>(), "completed", StringComparison.Ordinal))
                throw new FileMcpException($"Codex hydrated turn {turnIndex + 1} with an unexpected status.");
            var items = actualTurn["items"] as JsonArray
                ?? throw new FileMcpException($"Codex hydrated turn {turnIndex + 1} without items.");
            var actualMessages = new List<CodexHistoryMessage>();
            foreach (var item in items.OfType<JsonObject>())
            {
                switch (item["type"]?.GetValue<string>())
                {
                    case "userMessage":
                    {
                        var content = item["content"] as JsonArray;
                        var text = content?.OfType<JsonObject>()
                            .FirstOrDefault(node => node["type"]?.GetValue<string>() == "text")?["text"]?.GetValue<string>();
                        if (text is null) throw new FileMcpException($"Codex hydrated an invalid user message in turn {turnIndex + 1}.");
                        actualMessages.Add(new CodexHistoryMessage("user", text));
                        break;
                    }
                    case "agentMessage":
                    {
                        var text = item["text"]?.GetValue<string>()
                            ?? throw new FileMcpException($"Codex hydrated an invalid assistant message in turn {turnIndex + 1}.");
                        actualMessages.Add(new CodexHistoryMessage("assistant", text));
                        break;
                    }
                }
            }

            var expectedMessages = new List<CodexHistoryMessage>
            {
                new("user", expectedTurns[turnIndex].User),
            };
            expectedMessages.AddRange(expectedTurns[turnIndex].Assistants.Select(text => new CodexHistoryMessage("assistant", text)));
            if (actualMessages.Count != expectedMessages.Count)
                throw new FileMcpException($"Codex hydrated the wrong number of messages in turn {turnIndex + 1}.");
            for (var messageIndex = 0; messageIndex < expectedMessages.Count; messageIndex++)
            {
                if (actualMessages[messageIndex] != expectedMessages[messageIndex])
                    throw new FileMcpException($"Codex changed imported message content in turn {turnIndex + 1}.");
            }
        }
    }

    private static string ValidateRolloutPath(
        string rolloutPath,
        string codexHome,
        string threadId,
        bool requireSessionMetadata)
    {
        if (string.IsNullOrWhiteSpace(codexHome)) throw new FileMcpException("Codex did not report a home directory.");
        if (!File.Exists(rolloutPath)) throw new FileMcpException("Codex rollout path does not exist.");
        if ((File.GetAttributes(rolloutPath) & FileAttributes.Directory) != 0)
            throw new FileMcpException("Codex rollout path is not a regular file.");

        var sessionsPath = Path.Combine(Path.GetFullPath(codexHome), "sessions");
        if (!Directory.Exists(sessionsPath)) throw new FileMcpException("Codex sessions directory does not exist.");
        var canonicalSessions = CanonicalizeExistingPath(sessionsPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var canonicalRollout = CanonicalizeExistingPath(rolloutPath);
        if (!canonicalRollout.StartsWith(canonicalSessions + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            throw new FileMcpException("Codex returned a rollout path outside codexHome/sessions.");
        if (!Path.GetFileName(canonicalRollout).Contains(threadId, StringComparison.OrdinalIgnoreCase))
            throw new FileMcpException("Codex rollout filename does not match the created thread id.");

        if (requireSessionMetadata)
        {
            using var stream = new FileStream(canonicalRollout, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var firstLine = reader.ReadLine();
            JsonObject? firstRecord = null;
            try { firstRecord = firstLine is null ? null : JsonNode.Parse(firstLine) as JsonObject; } catch (JsonException) { }
            var payload = firstRecord?["payload"] as JsonObject;
            var metadataId = payload?["id"]?.GetValue<string>() ?? payload?["session_id"]?.GetValue<string>();
            if (firstRecord?["type"]?.GetValue<string>() != "session_meta" ||
                !string.Equals(metadataId, threadId, StringComparison.Ordinal))
                throw new FileMcpException("Codex rollout does not start with session metadata for the created thread.");
        }
        return canonicalRollout;
    }

    private static async Task BestEffortCleanupAsync(
        string executable,
        string threadId,
        string rolloutPath,
        string codexHome)
    {
        try
        {
            await using var client = new CodexAppServerClient(executable);
            _ = await client.InitializeAsync(CancellationToken.None).ConfigureAwait(false);
            _ = await client.RequestAsync(
                "thread/delete",
                new JsonObject { ["threadId"] = threadId },
                timeoutSeconds: 10,
                cancellationToken: CancellationToken.None).ConfigureAwait(false);
        }
        catch
        {
            // Fall through to path-validated file cleanup for a thread that failed before indexing.
        }

        if (string.IsNullOrWhiteSpace(rolloutPath) || string.IsNullOrWhiteSpace(codexHome)) return;
        try
        {
            var validated = ValidateRolloutPath(rolloutPath, codexHome, threadId, requireSessionMetadata: false);
            if (File.Exists(validated)) File.Delete(validated);
        }
        catch
        {
            // Best-effort cleanup must never mask the original import error.
        }
    }

    private static string LocateCodexExecutable()
    {
        if (!OperatingSystem.IsWindows()) throw new FileMcpException("Codex Windows executable lookup requires Windows.");
        var candidates = new List<string>();
        AddCandidate(candidates, Environment.GetEnvironmentVariable("CODEX_BIN"));
        AddCandidate(candidates, Environment.GetEnvironmentVariable("CODEX_CLI_PATH"));

        var installDir = Environment.GetEnvironmentVariable("CODEX_INSTALL_DIR");
        if (!string.IsNullOrWhiteSpace(installDir)) AddCandidate(candidates, Path.Combine(installDir, "codex.exe"));

        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (!string.IsNullOrWhiteSpace(localAppData))
        {
            AddCandidate(candidates, Path.Combine(localAppData, "Programs", "OpenAI", "Codex", "bin", "codex.exe"));
            AddCandidate(candidates, Path.Combine(localAppData, "Programs", "OpenAI", "Codex", "resources", "codex.exe"));
            AddCandidate(candidates, Path.Combine(localAppData, "OpenAI", "Codex", "app", "resources", "codex.exe"));
            var desktopCliDir = Path.Combine(localAppData, "OpenAI", "Codex", "bin");
            AddCandidate(candidates, Path.Combine(desktopCliDir, "codex.exe"));
            if (Directory.Exists(desktopCliDir))
            {
                try
                {
                    foreach (var directory in new DirectoryInfo(desktopCliDir).EnumerateDirectories()
                                 .OrderByDescending(directory => directory.LastWriteTimeUtc))
                    {
                        AddCandidate(candidates, Path.Combine(directory.FullName, "codex.exe"));
                    }
                }
                catch (UnauthorizedAccessException) { }
                catch (IOException) { }
            }
        }

        var codexHome = Environment.GetEnvironmentVariable("CODEX_HOME");
        if (string.IsNullOrWhiteSpace(codexHome))
        {
            var userProfile = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
            if (!string.IsNullOrWhiteSpace(userProfile)) codexHome = Path.Combine(userProfile, ".codex");
        }
        if (!string.IsNullOrWhiteSpace(codexHome))
            AddCandidate(candidates, Path.Combine(codexHome, "packages", "standalone", "current", "codex.exe"));

        var path = Environment.GetEnvironmentVariable("PATH") ?? "";
        foreach (var directory in path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (!Path.IsPathFullyQualified(directory)) continue;
            AddCandidate(candidates, Path.Combine(directory, "codex.exe"));
        }

        foreach (var candidate in candidates.Distinct(StringComparer.OrdinalIgnoreCase))
        {
            try
            {
                if (File.Exists(candidate)) return Path.GetFullPath(candidate);
            }
            catch
            {
                // Continue through the remaining candidates.
            }
        }
        throw new FileMcpException(
            "Codex executable was not found. Install Codex, place codex.exe on PATH, or set CODEX_BIN/CODEX_CLI_PATH.");
    }

    private static void AddCandidate(List<string> candidates, string? candidate)
    {
        if (!string.IsNullOrWhiteSpace(candidate)) candidates.Add(Environment.ExpandEnvironmentVariables(candidate.Trim().Trim('"')));
    }

    private static string CanonicalizeExistingPath(string path)
    {
        var fullPath = Path.GetFullPath(path);
        if (!OperatingSystem.IsWindows()) return fullPath;
        using var handle = NativeMethods.CreateFileW(
            fullPath,
            0,
            NativeMethods.FileShareRead | NativeMethods.FileShareWrite | NativeMethods.FileShareDelete,
            IntPtr.Zero,
            NativeMethods.OpenExisting,
            NativeMethods.FileFlagBackupSemantics,
            IntPtr.Zero);
        if (handle.IsInvalid)
            throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not resolve Codex path: {fullPath}");

        var capacity = 1024u;
        while (true)
        {
            var buffer = new char[capacity];
            var length = NativeMethods.GetFinalPathNameByHandleW(handle, buffer, capacity, 0);
            if (length == 0)
                throw new Win32Exception(Marshal.GetLastWin32Error(), $"Could not resolve Codex path: {fullPath}");
            if (length < capacity) return NormalizeFinalPath(new string(buffer, 0, (int)length));
            capacity = length + 1;
        }
    }

    private static string NormalizeFinalPath(string path)
    {
        const string uncPrefix = "\\\\?\\UNC\\";
        const string extendedPrefix = "\\\\?\\";
        if (path.StartsWith(uncPrefix, StringComparison.OrdinalIgnoreCase)) return "\\\\" + path[uncPrefix.Length..];
        return path.StartsWith(extendedPrefix, StringComparison.OrdinalIgnoreCase) ? path[extendedPrefix.Length..] : path;
    }

    private static class NativeMethods
    {
        internal const uint FileShareRead = 0x00000001;
        internal const uint FileShareWrite = 0x00000002;
        internal const uint FileShareDelete = 0x00000004;
        internal const uint OpenExisting = 3;
        internal const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        internal static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            [Out] char[] filePath,
            uint filePathSize,
            uint flags);
    }
}

internal sealed class CodexAppServerClient : IAsyncDisposable
{
    private readonly Process _process;
    private readonly WindowsJob? _job;
    private readonly StreamWriter _stdin;
    private readonly StreamReader _stdout;
    private readonly Task _stderrTask;
    private readonly StringBuilder _stderr = new();
    private readonly Dictionary<int, JsonObject> _pendingResponses = new();
    private int _nextRequestId = 1;
    private int _closed;

    internal CodexAppServerClient(string executable)
    {
        var startInfo = CreateStartInfo(executable);
        _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        try
        {
            if (!_process.Start()) throw new FileMcpException($"Could not start Codex app-server: {executable}");
        }
        catch (Win32Exception ex)
        {
            _process.Dispose();
            throw new FileMcpException($"Could not start Codex app-server: {ex.Message}");
        }
        try
        {
            _job = WindowsJob.CreateAndAssign(_process);
        }
        catch
        {
            try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { }
            _process.Dispose();
            throw;
        }
        _stdin = _process.StandardInput;
        _stdin.NewLine = "\n";
        _stdin.AutoFlush = true;
        _stdout = _process.StandardOutput;
        _stderrTask = DrainStderrAsync(_process.StandardError);
    }

    internal async Task<string> InitializeAsync(CancellationToken cancellationToken)
    {
        var result = await RequestAsync(
            "initialize",
            new JsonObject
            {
                ["clientInfo"] = new JsonObject
                {
                    ["name"] = FileMcpConstants.ServerName,
                    ["version"] = FileMcpConstants.ServerVersion,
                },
                ["capabilities"] = new JsonObject { ["experimentalApi"] = true },
            },
            timeoutSeconds: 15,
            cancellationToken: cancellationToken).ConfigureAwait(false);
        var codexHome = result["codexHome"]?.GetValue<string>();
        if (string.IsNullOrWhiteSpace(codexHome)) throw new FileMcpException("Codex initialize did not return codexHome.");
        await NotifyAsync("initialized", new JsonObject(), cancellationToken).ConfigureAwait(false);
        return codexHome;
    }

    internal async Task<JsonObject> RequestAsync(
        string method,
        JsonObject parameters,
        int timeoutSeconds = 20,
        CancellationToken cancellationToken = default)
    {
        if (Volatile.Read(ref _closed) != 0) throw new FileMcpException("Codex app-server client is closed.");
        var id = _nextRequestId++;
        var request = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["method"] = method,
            ["params"] = parameters,
        };
        await _stdin.WriteLineAsync(request.ToJsonString().AsMemory(), cancellationToken).ConfigureAwait(false);

        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(Math.Max(1, timeoutSeconds)));
        while (true)
        {
            if (_pendingResponses.Remove(id, out var pending)) return ParseResponse(method, pending);
            string? line;
            try
            {
                line = await _stdout.ReadLineAsync(timeoutCts.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
            {
                throw new FileMcpException($"Timed out waiting for Codex app-server method {method}.{StderrSuffix()}");
            }
            if (line is null)
                throw new FileMcpException($"Codex app-server exited before replying to {method}.{StderrSuffix()}");
            JsonObject? response;
            try { response = JsonNode.Parse(line) as JsonObject; }
            catch (JsonException ex) { throw new FileMcpException($"Could not parse Codex response: {ex.Message}"); }
            if (response is null || response["id"] is not JsonValue idNode || !idNode.TryGetValue<int>(out var responseId))
                continue;
            if (responseId == id) return ParseResponse(method, response);
            _pendingResponses[responseId] = response;
        }
    }

    private static JsonObject ParseResponse(string method, JsonObject response)
    {
        if (response["error"] is JsonObject error)
        {
            var message = error["message"]?.GetValue<string>() ?? "Unknown Codex app-server error";
            throw new FileMcpException($"Codex {method} failed: {message}");
        }
        return response["result"] as JsonObject
            ?? throw new FileMcpException($"Codex {method} returned an invalid result.");
    }

    private async Task NotifyAsync(string method, JsonObject parameters, CancellationToken cancellationToken)
    {
        var notification = new JsonObject
        {
            ["jsonrpc"] = "2.0",
            ["method"] = method,
            ["params"] = parameters,
        };
        await _stdin.WriteLineAsync(notification.ToJsonString().AsMemory(), cancellationToken).ConfigureAwait(false);
    }

    internal async Task CloseAsync()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0) return;
        try { _stdin.Close(); } catch { }
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await _process.WaitForExitAsync(cts.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            _job?.Terminate(1);
            try { if (!_process.HasExited) _process.Kill(entireProcessTree: true); } catch { }
            try { await _process.WaitForExitAsync().ConfigureAwait(false); } catch { }
        }
        catch (InvalidOperationException) { }
        try { await _stderrTask.ConfigureAwait(false); } catch { }
        _job?.Dispose();
        _process.Dispose();
    }

    public async ValueTask DisposeAsync() => await CloseAsync().ConfigureAwait(false);

    private async Task DrainStderrAsync(StreamReader reader)
    {
        var buffer = new char[4096];
        while (true)
        {
            var count = await reader.ReadAsync(buffer.AsMemory()).ConfigureAwait(false);
            if (count <= 0) return;
            lock (_stderr)
            {
                var remaining = Math.Max(0, 32_000 - _stderr.Length);
                if (remaining > 0) _stderr.Append(buffer, 0, Math.Min(remaining, count));
            }
        }
    }

    private string StderrSuffix()
    {
        lock (_stderr)
        {
            var text = _stderr.ToString().Trim();
            return string.IsNullOrEmpty(text) ? "" : " Codex stderr: " + text;
        }
    }

    private static ProcessStartInfo CreateStartInfo(string executable)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = executable,
            UseShellExecute = false,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        startInfo.ArgumentList.Add("app-server");
        startInfo.ArgumentList.Add("--listen");
        startInfo.ArgumentList.Add("stdio://");
        return startInfo;
    }
}
