using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace FileMCP.Core;

internal sealed partial class LocalTools
{
    private sealed record CodeSearchCandidate(string Path, int Line, string LineText, int Score, string[] Signals);

    private sealed class CodeSearchQueryState(string query)
    {
        public string Query { get; } = query;
        public int ObservedMatches { get; set; }
        public List<CodeSearchCandidate> Candidates { get; } = [];
    }

    private sealed class CodeSearchLexicalState(
        bool supportsNestedBlockComments, bool supportsMultilineBackticks, bool supportsHashLineComments,
        bool supportsPowerShellBlockComments)
    {
        public bool SupportsNestedBlockComments { get; } = supportsNestedBlockComments;
        public bool SupportsMultilineBackticks { get; } = supportsMultilineBackticks;
        public bool SupportsHashLineComments { get; } = supportsHashLineComments;
        public bool SupportsPowerShellBlockComments { get; } = supportsPowerShellBlockComments;
        public int BlockCommentDepth { get; set; }
        public bool InPowerShellBlockComment { get; set; }
        public char? MultilineQuote { get; set; }
        public bool MultilineEscaping { get; set; }
        public bool IsActive => BlockCommentDepth > 0 || InPowerShellBlockComment || MultilineQuote.HasValue;
    }

    private sealed record RipgrepTarget(string Cwd, string Argument, string Base);

    private readonly SafePathResolver _resolver;
    private readonly string _gitUserName;
    private readonly string _gitUserEmail;
    private readonly bool _enableCommands;
    private readonly string? _safeGitEmptyFile;
    private readonly string? _safeGitHooksDirectory;
    private readonly SemaphoreSlim _toolSlots = new(8, 8);
    private readonly SemaphoreSlim _serializedSlot = new(1, 1);
    private readonly SemaphoreSlim _commandSlots = new(2, 2);
    private readonly SemaphoreSlim _gitSlots = new(3, 3);
    private readonly SemaphoreSlim _codexHistorySlot = new(1, 1);
    private static readonly HashSet<string> SerializedToolNames = new(StringComparer.Ordinal)
    {
        "write_file", "delete_file", "delete_directory", "run_command", "edit_file", "apply_patch", "workspace_context", "start_command",
        "git_init", "git_status", "git_log", "git_diff", "git_add", "git_commit", "git_push",
    };
    private static readonly HashSet<string> BatchReadToolNames = new(StringComparer.Ordinal)
    {
        "list_files", "read_file", "read_file_range", "grep", "search_code", "glob", "repo_overview",
        "git_status", "git_log", "git_diff",
    };
    private readonly Ripgrep _ripgrep;
    private static readonly HashSet<string> CodeDeclarationKeywords = new(StringComparer.Ordinal)
    {
        "actor", "class", "def", "enum", "fn", "fun", "func", "function",
        "associatedtype", "interface", "let", "macro", "mod", "module", "namespace", "object",
        "protocol", "record", "struct", "trait", "type", "typealias", "union", "var",
    };
    private static readonly HashSet<string> CodeNonDeclarationPrefixKeywords = new(StringComparer.OrdinalIgnoreCase)
    {
        "await", "case", "catch", "default", "do", "else", "for", "foreach", "if", "lock",
        "new", "return", "switch", "throw", "using", "while", "yield",
    };
    private static readonly HashSet<string> RepoManifestNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "build.gradle", "build.gradle.kts", "bun.lock", "bun.lockb", "cargo.lock", "cargo.toml",
        "cmakelists.txt", "composer.json", "compose.yaml", "compose.yml", "dockerfile", "gemfile",
        "go.mod", "go.sum", "gradlew", "makefile", "mix.exs", "package-lock.json", "package.json",
        "package.swift", "pipfile", "pnpm-lock.yaml", "pnpm-workspace.yaml", "podfile", "poetry.lock",
        "pom.xml", "pubspec.yaml", "pyproject.toml", "requirements.txt", "settings.gradle",
        "settings.gradle.kts", "yarn.lock",
    };
    private static readonly string[] RepoManifestSuffixes =
    [
        ".csproj", ".fsproj", ".sln", ".vbproj", ".xcodeproj", ".xcworkspace",
    ];

    public LocalTools(string allowedDirectory, string gitUserName, string gitUserEmail, bool enableCommands, Ripgrep? ripgrep = null)
    {
        _resolver = new SafePathResolver(allowedDirectory);
        _ripgrep = ripgrep ?? new Ripgrep();
        _gitUserName = gitUserName;
        _gitUserEmail = gitUserEmail;
        _enableCommands = enableCommands;
        if (!enableCommands)
        {
            (_safeGitEmptyFile, _safeGitHooksDirectory) = PrepareSafeGitResources();
        }
    }

    public JsonArray ToolDefinitions
    {
        get
        {
            var tools = new JsonArray
            {
                Tool("list_files", "List files and folders inside the shared directory (optionally a subfolder).",
                    Props(("subpath", StringProperty("Subpath inside the shared root."))), [], true, output: StringArrayOutputSchema()),
                Tool("read_file", "Read the text content of a file inside the shared directory.",
                    Props(("relative_path", StringProperty("Relative path to a text file."))), ["relative_path"], true),
                Tool("read_file_range", "Read a targeted line range from a text file. Use this after search_code or grep to inspect surrounding implementation. Expand the range or use read_file before drawing conclusions when callers, state, imports, or other surrounding code may matter.",
                    Props(
                        ("relative_path", StringProperty("Relative path to a text file.")),
                        ("start_line", IntegerProperty(1, null, null, "1-based first line to return.")),
                        ("end_line", IntegerProperty(1, null, null, "1-based last line to return (inclusive)."))),
                    ["relative_path", "start_line", "end_line"], true, output: ReadFileRangeOutputSchema()),
                Tool("grep", "Fast ripgrep-backed content search inside the shared directory. Supports Rust regex syntax (set fixed_strings for literal text), glob and file-type filters, and output modes files_with_matches (default; newest-modified first), content (matching lines with optional context), or count. Respects .gitignore/.ignore and skips .git plus default dependency/build directories unless include_ignored is true. Paginate with head_limit/offset and check truncated/truncation_reasons. Read important hits with read_file_range.",
                    Props(
                        ("pattern", StringProperty("Regular expression (Rust regex syntax), or literal text when fixed_strings is true.")),
                        ("fixed_strings", DescribedBooleanProperty(false, "Treat pattern as literal text.")),
                        ("path", StringProperty("Optional file or subdirectory inside the shared root.")),
                        ("glob", StringProperty("Optional case-insensitive glob filter relative to path, for example \"*.ts\" or \"src/**/*.{ts,tsx}\".")),
                        ("type", StringProperty("Optional ripgrep file type such as swift, js, py, rust, or csharp.")),
                        ("output_mode", new JsonObject
                        {
                            ["type"] = "string",
                            ["enum"] = new JsonArray("files_with_matches", "content", "count"),
                            ["default"] = "files_with_matches",
                        }),
                        ("case_insensitive", BooleanProperty(false)),
                        ("context", IntegerProperty(0, FileMcpConstants.MaxSearchContextLines, 0, "Context lines before and after each match in content mode.")),
                        ("context_before", IntegerProperty(0, FileMcpConstants.MaxSearchContextLines, null, "Overrides context for lines before each match.")),
                        ("context_after", IntegerProperty(0, FileMcpConstants.MaxSearchContextLines, null, "Overrides context for lines after each match.")),
                        ("multiline", DescribedBooleanProperty(false, "Allow matches to span lines; . also matches newlines.")),
                        ("head_limit", IntegerProperty(1, FileMcpConstants.MaxSearchHeadLimit, FileMcpConstants.DefaultSearchHeadLimit)),
                        ("offset", IntegerProperty(0, FileMcpConstants.MaxSearchOffset, 0)),
                        ("include_ignored", IncludeIgnoredProperty())),
                    ["pattern"], true, output: GrepOutputSchema()),
                Tool("search_code", "Search code symbols/usages with one to six literal queries in one pass. ripgrep finds candidate files (respecting .gitignore and default exclusions unless include_ignored is true), then every matching line is ranked so declarations and whole identifiers come first regardless of filesystem order. Scores are deterministic ordering heuristics, not confidence. Inspect important hits with read_file_range or read_file.",
                    Props(
                        ("queries", SearchCodeQueriesProperty()),
                        ("path", StringProperty("Optional subdirectory to search inside the shared root.")),
                        ("case_sensitive", BooleanProperty(false)),
                        ("max_results_per_query", IntegerProperty(1, FileMcpConstants.MaxSearchCodeResultsPerQuery, 6)),
                        ("include_ignored", IncludeIgnoredProperty())),
                    ["queries"], true, output: SearchCodeOutputSchema()),
                Tool("repo_overview", "Return a factual repository snapshot for early codebase orientation: top-level entries, detected manifests, file-extension counts, exclusions, and coverage metadata. File and directory coverage respect .gitignore/.ignore plus default exclusions unless include_ignored is true; .git is always skipped. It does not infer architecture or replace targeted reads/searches.",
                    Props(
                        ("path", StringProperty("Optional repository or subdirectory inside the shared root.")),
                        ("include_ignored", IncludeIgnoredProperty())),
                    [], true, output: RepoOverviewOutputSchema()),
                Tool("glob", "Fast ripgrep-backed file path search using case-insensitive gitignore-style globs such as \"**/*.swift\", \"*readme*\", or \"src/**/Local*\" (a pattern without a slash matches file names at any depth). Returns files newest-modified first, including files too large for grep. Respects .gitignore/.ignore and default exclusions unless include_ignored is true. Paginate with head_limit/offset.",
                    Props(
                        ("pattern", StringProperty("Glob pattern relative to path.")),
                        ("path", StringProperty("Optional subdirectory inside the shared root.")),
                        ("head_limit", IntegerProperty(1, FileMcpConstants.MaxSearchHeadLimit, FileMcpConstants.DefaultSearchHeadLimit)),
                        ("offset", IntegerProperty(0, FileMcpConstants.MaxSearchOffset, 0)),
                        ("include_ignored", IncludeIgnoredProperty())),
                    ["pattern"], true, output: GlobOutputSchema()),
                Tool("write_file", "Create a file, overwrite it, or append to it inside the shared directory.",
                    Props(
                        ("relative_path", StringProperty("Relative file path.")),
                        ("content", StringProperty("UTF-8 text content.")),
                        ("append", BooleanProperty(false))),
                    ["relative_path", "content"], false, destructive: true),
                Tool("delete_file", "Delete a file inside the shared directory (files only, not directories).",
                    Props(("relative_path", StringProperty("Relative file path."))), ["relative_path"], false, destructive: true),
                Tool("delete_directory", "Recursively delete a folder and everything inside it.",
                    Props(("relative_path", StringProperty("Relative directory path."))), ["relative_path"], false, destructive: true),
                Tool("git_init", "Create a new git repository inside the shared directory.",
                    Props(("repo_path", StringProperty("Repository path relative to the shared root."))), [], false),
                Tool("git_status", "Show the working-tree status of a git repo whose worktree and Git metadata stay inside the shared directory.",
                    Props(("repo_path", StringProperty("Repository path relative to the shared root."))), [], true),
                Tool("git_log", "Show recent commit history of a Git repo fully contained inside the shared directory.",
                    Props(
                        ("repo_path", StringProperty("Repository path relative to the shared root.")),
                        ("count", IntegerProperty(1, 50, 10))), [], true),
                Tool("git_diff", "Show uncommitted changes (working tree vs index). Repository paths are containment-checked; external diff/textconv are suppressed when command execution is disabled.",
                    Props(
                        ("repo_path", StringProperty("Repository path relative to the shared root.")),
                        ("paths", StringProperty("Optional path or whitespace-separated pathspecs. Quote pathspecs that contain spaces."))), [], true),
                Tool("git_add", "Stage files for the next commit. When command execution is disabled, paths using Git content filters are refused.",
                    Props(
                        ("repo_path", StringProperty("Repository path relative to the shared root.")),
                        ("paths", StringProperty("Path or whitespace-separated pathspecs. Quote pathspecs that contain spaces.", "."))), [], false),
                Tool("git_commit", "Create a commit from staged changes. Repository hooks and GPG signing are suppressed when command execution is disabled.",
                    Props(
                        ("repo_path", StringProperty("Repository path relative to the shared root.")),
                        ("message", StringProperty(null, "update"))), [], false),
                Tool("git_push", "Push the current branch to its upstream remote. In safe mode, repository hooks, signing, local file transport, and repository-local credential helpers are restricted.",
                    Props(("repo_path", StringProperty("Repository path relative to the shared root."))), [], false, openWorld: true),
                Tool("save_conversation_to_codex", "Create a durable Codex thread from supplied user/assistant messages. The new thread is grouped under Projects by repo_path and is written to the current user's Codex local history outside the FileMCP workspace.",
                    Props(
                        ("title", StringProperty("User-facing Codex thread title.")),
                        ("repo_path", StringProperty("Working directory relative to the shared root. Defaults to the shared root.")),
                        ("messages", new JsonObject
                        {
                            ["type"] = "array",
                            ["minItems"] = 1,
                            ["maxItems"] = 500,
                            ["description"] = "Ordered conversation messages to persist verbatim.",
                            ["items"] = new JsonObject
                            {
                                ["type"] = "object",
                                ["properties"] = new JsonObject
                                {
                                    ["role"] = new JsonObject { ["type"] = "string", ["enum"] = new JsonArray("user", "assistant") },
                                    ["content"] = new JsonObject { ["type"] = "string" },
                                },
                                ["required"] = new JsonArray("role", "content"),
                                ["additionalProperties"] = false,
                            },
                        })),
                    ["title", "messages"], false, output: CodexConversationOutputSchema()),
            };
            if (_enableCommands)
            {
                tools.Add(Tool("run_command", "Run a PowerShell command on the local machine. The command inherits the current user's environment and is not OS-sandboxed. cwd must stay inside the shared directory.",
                    Props(
                        ("command", StringProperty("PowerShell command to execute.")),
                        ("cwd", StringProperty("Working directory relative to the shared root.")),
                        ("timeout_seconds", IntegerProperty(1, ProcessRunner.MaxCommandTimeoutSeconds, ProcessRunner.DefaultCommandTimeoutSeconds))),
                    ["command"], false, destructive: true, openWorld: true));
            }
            tools.Add(Tool("batch_read",
                "Batch up to 16 independent read-only filesystem, search, and Git operations into one MCP round trip. Use only operations known up front, prefer targeted paths/ranges, and keep potentially large full-file or Git diff reads separate.",
                Props(
                    ("operations", BatchReadOperationsProperty()),
                    ("stop_on_error", BooleanProperty(false))),
                ["operations"], true, output: BatchReadOutputSchema()));
            foreach (var definition in AgentToolDefinitions()) tools.Add(definition);
            return tools;
        }
    }

    public bool HasTool(string name) => ToolDefinitions.OfType<JsonObject>().Any(tool => tool["name"]?.GetValue<string>() == name);

    public async Task<ToolCallOutput> CallAsync(string name, JsonObject arguments, CancellationToken cancellationToken = default)
    {
        await _toolSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        var serialize = SerializedToolNames.Contains(name) ||
            (name == "batch_read" && BatchReadNeedsSerialization(arguments));
        if (serialize)
        {
            await _serializedSlot.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        try
        {
            ValidateArguments(name, arguments);
            if (serialize && name != "start_command") EnsureNoActiveCommand();
            return name switch
            {
                "list_files" or "read_file" or "read_file_range" or "grep" or "search_code" or
                "glob" or "repo_overview" or "git_status" or "git_log" or "git_diff" =>
                    await CallReadOnlyAsync(name, arguments, cancellationToken).ConfigureAwait(false),
                "batch_read" => ObjectOutput(await BatchReadAsync(
                    arguments["operations"], GetBool(arguments, "stop_on_error", false), cancellationToken).ConfigureAwait(false)),
                "edit_file" => ObjectOutput(EditFile(arguments)),
                "apply_patch" => ObjectOutput(ApplyPatch(arguments)),
                "workspace_context" => ObjectOutput(await WorkspaceContextAsync(GetString(arguments, "path", ""), cancellationToken).ConfigureAwait(false)),
                "start_command" => ObjectOutput(StartCommand(arguments)),
                "read_command_output" => ObjectOutput(FindSession(GetRequiredString(arguments, "session_id")).Snapshot(GetInt(arguments, "cursor", 0))),
                "cancel_command" => ObjectOutput(CancelCommand(GetRequiredString(arguments, "session_id"))),
                "write_file" => StringOutput(WriteFile(
                    GetRequiredString(arguments, "relative_path"),
                    GetRequiredString(arguments, "content"),
                    GetBool(arguments, "append", false))),
                "delete_file" => StringOutput(DeleteFile(GetRequiredString(arguments, "relative_path"))),
                "delete_directory" => StringOutput(DeleteDirectory(GetRequiredString(arguments, "relative_path"))),
                "run_command" when _enableCommands => StringOutput(await RunCommandAsync(
                    GetRequiredString(arguments, "command"), GetString(arguments, "cwd", ""),
                    GetInt(arguments, "timeout_seconds", ProcessRunner.DefaultCommandTimeoutSeconds), cancellationToken).ConfigureAwait(false)),
                "run_command" => throw new FileMcpException("Command execution is disabled"),
                "git_init" => StringOutput(await GitInitAsync(GetString(arguments, "repo_path", ""), cancellationToken).ConfigureAwait(false)),
                "git_add" => StringOutput(await GitAddAsync(GetString(arguments, "repo_path", ""), GetString(arguments, "paths", "."), cancellationToken).ConfigureAwait(false)),
                "git_commit" => StringOutput(await GitCommitAsync(GetString(arguments, "repo_path", ""), GetString(arguments, "message", "update"), cancellationToken).ConfigureAwait(false)),
                "git_push" => StringOutput(await GitPushAsync(GetString(arguments, "repo_path", ""), cancellationToken).ConfigureAwait(false)),
                "save_conversation_to_codex" => ObjectOutput(await SaveConversationToCodexAsync(
                    GetRequiredString(arguments, "title"), GetString(arguments, "repo_path", ""), arguments["messages"], cancellationToken).ConfigureAwait(false)),
                _ => throw new FileMcpException($"Unknown tool: {name}"),
            };
        }
        finally
        {
            if (serialize) _serializedSlot.Release();
            _toolSlots.Release();
        }
    }

    private bool BatchReadNeedsSerialization(JsonObject arguments)
    {
        if (arguments["operations"] is not JsonArray operations) return false;
        foreach (var value in operations)
        {
            if (value is JsonObject operation &&
                operation["tool"] is JsonValue toolValue &&
                toolValue.TryGetValue<string>(out var toolName) &&
                SerializedToolNames.Contains(toolName))
            {
                return true;
            }
        }
        return false;
    }

    private async Task<ToolCallOutput> CallReadOnlyAsync(
        string name, JsonObject arguments, CancellationToken cancellationToken)
    {
        return name switch
        {
            "list_files" => StringArrayOutput(ListFiles(GetString(arguments, "subpath", ""))),
            "read_file" => StringOutput(ReadFile(GetRequiredString(arguments, "relative_path"))),
            "read_file_range" => ObjectOutput(ReadFileRange(
                GetRequiredString(arguments, "relative_path"),
                GetRequiredInt(arguments, "start_line"),
                GetRequiredInt(arguments, "end_line"))),
            "grep" => ObjectOutput(await GrepAsync(arguments, cancellationToken).ConfigureAwait(false)),
            "search_code" => ObjectOutput(await SearchCodeAsync(
                arguments["queries"],
                GetString(arguments, "path", ""),
                GetBool(arguments, "case_sensitive", false),
                GetInt(arguments, "max_results_per_query", 6),
                GetBool(arguments, "include_ignored", false),
                cancellationToken).ConfigureAwait(false)),
            "repo_overview" => ObjectOutput(await RepoOverviewAsync(
                GetString(arguments, "path", ""), GetBool(arguments, "include_ignored", false), cancellationToken).ConfigureAwait(false)),
            "glob" => ObjectOutput(await GlobAsync(arguments, cancellationToken).ConfigureAwait(false)),
            "git_status" => StringOutput(await GitStatusAsync(
                GetString(arguments, "repo_path", ""), cancellationToken).ConfigureAwait(false)),
            "git_log" => StringOutput(await GitLogAsync(
                GetString(arguments, "repo_path", ""), GetInt(arguments, "count", 10), cancellationToken).ConfigureAwait(false)),
            "git_diff" => StringOutput(await GitDiffAsync(
                GetString(arguments, "repo_path", ""), GetString(arguments, "paths", ""), cancellationToken).ConfigureAwait(false)),
            _ => throw new FileMcpException($"batch_read does not allow tool: {name}"),
        };
    }

    private async Task<JsonObject> BatchReadAsync(
        JsonNode? operationsNode, bool stopOnError, CancellationToken cancellationToken)
    {
        if (operationsNode is not JsonArray operations || operations.Count is < 1 or > FileMcpConstants.MaxBatchReadOperations)
            throw new FileMcpException($"operations must contain 1...{FileMcpConstants.MaxBatchReadOperations} read-only operation(s)");

        var results = new JsonArray();
        var succeeded = 0;
        var failed = 0;
        var stoppedOnError = false;
        for (var index = 0; index < operations.Count; index++)
        {
            var toolName = "";
            try
            {
                if (operations[index] is not JsonObject operation)
                    throw new FileMcpException($"operations[{index}] must be an object");
                var unexpected = operation.Select(pair => pair.Key)
                    .FirstOrDefault(key => key is not ("tool" or "arguments"));
                if (unexpected is not null)
                    throw new FileMcpException($"Unexpected argument in operations[{index}]: {unexpected}");
                if (operation["tool"] is not JsonValue toolValue || !toolValue.TryGetValue<string>(out var name))
                    throw new FileMcpException($"operations[{index}].tool must be a string");
                toolName = name;
                if (!BatchReadToolNames.Contains(name))
                    throw new FileMcpException($"batch_read does not allow tool: {name}");

                JsonObject operationArguments;
                if (operation["arguments"] is null) operationArguments = new JsonObject();
                else if (operation["arguments"] is JsonObject typedArguments) operationArguments = typedArguments;
                else throw new FileMcpException($"operations[{index}].arguments must be an object");

                ValidateArguments(name, operationArguments);
                var output = await CallReadOnlyAsync(name, operationArguments, cancellationToken).ConfigureAwait(false);
                results.Add(new JsonObject
                {
                    ["index"] = index,
                    ["tool"] = name,
                    ["ok"] = true,
                    ["structured_content"] = output.StructuredContent,
                });
                succeeded++;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                results.Add(new JsonObject
                {
                    ["index"] = index,
                    ["tool"] = toolName,
                    ["ok"] = false,
                    ["error"] = ex.Message,
                });
                failed++;
                if (stopOnError)
                {
                    stoppedOnError = true;
                    break;
                }
            }
        }

        return new JsonObject
        {
            ["requested"] = operations.Count,
            ["completed"] = results.Count,
            ["succeeded"] = succeeded,
            ["failed"] = failed,
            ["stopped_on_error"] = stoppedOnError,
            ["results"] = results,
        };
    }

    private (IReadOnlyList<string> Values, bool Truncated) ListFiles(string subpath)
    {
        var directory = _resolver.Resolve(subpath);
        if (!Directory.Exists(directory)) return ([], false);
        var entries = new DirectoryInfo(directory).EnumerateFileSystemInfos()
            .OrderBy(entry => entry.Name, StringComparer.OrdinalIgnoreCase).ToList();
        return (entries.Take(FileMcpConstants.MaxListEntries)
            .Select(entry => entry.Name + ((entry.Attributes & FileAttributes.Directory) != 0 ? "/" : "")).ToList(),
            entries.Count > FileMcpConstants.MaxListEntries);
    }

    private string ReadFile(string relativePath)
    {
        var target = _resolver.Resolve(relativePath);
        var info = new FileInfo(target);
        if (!info.Exists || (info.Attributes & FileAttributes.Directory) != 0)
            throw new FileMcpException($"No such file: {relativePath}");
        if (info.Length > FileMcpConstants.MaxFileBytes)
            throw new FileMcpException("File is larger than the 5 MB limit for this tool");
        var data = File.ReadAllBytes(target);
        if (data.Length > FileMcpConstants.MaxFileBytes)
            throw new FileMcpException("File is larger than the 5 MB limit for this tool");
        var text = Encoding.UTF8.GetString(data);
        return text.Length > FileMcpConstants.MaxCharsReturned
            ? text[..FileMcpConstants.MaxCharsReturned] + "\n\n[...truncated...]" : text;
    }

    private JsonObject ReadFileRange(string relativePath, int startLine, int endLine)
    {
        if (startLine < 1 || endLine < startLine)
            throw new FileMcpException("start_line and end_line must define a valid 1-based inclusive range");
        var target = _resolver.Resolve(relativePath);
        var info = new FileInfo(target);
        if (!info.Exists || (info.Attributes & FileAttributes.Directory) != 0)
            throw new FileMcpException($"No such file: {relativePath}");
        if (info.Length > FileMcpConstants.MaxFileBytes)
            throw new FileMcpException("File is larger than the 5 MB limit for this tool");
        var data = File.ReadAllBytes(target);
        if (data.Length > FileMcpConstants.MaxFileBytes)
            throw new FileMcpException("File is larger than the 5 MB limit for this tool");
        var lines = SplitTextLines(Encoding.UTF8.GetString(data));
        var totalLines = Math.Max(1, lines.Count);
        if (startLine > totalLines)
            throw new FileMcpException($"start_line {startLine} is beyond the end of the file ({totalLines} lines)");
        var requestedEnd = Math.Min(endLine, totalLines);
        var lineLimitedEnd = Math.Min(requestedEnd, startLine + FileMcpConstants.MaxReadRangeLines - 1);
        var returned = new List<string>();
        var chars = 0;
        for (var lineNumber = startLine; lineNumber <= lineLimitedEnd; lineNumber++)
        {
            var line = lines[lineNumber - 1];
            var separator = returned.Count == 0 ? 0 : 1;
            if (chars + separator + line.Length > FileMcpConstants.MaxReadRangeChars) break;
            returned.Add(line);
            chars += separator + line.Length;
        }
        if (returned.Count == 0)
            throw new FileMcpException($"Line {startLine} is larger than the 80,000 character response limit for read_file_range");
        var actualEnd = startLine + returned.Count - 1;
        return new JsonObject
        {
            ["path"] = relativePath, ["start_line"] = startLine, ["end_line"] = actualEnd,
            ["requested_end_line"] = endLine, ["total_lines"] = totalLines,
            ["has_before"] = startLine > 1, ["has_after"] = actualEnd < totalLines,
            ["truncated"] = actualEnd < requestedEnd, ["content"] = string.Join("\n", returned),
        };
    }

    private RipgrepTarget ResolveRipgrepTarget(string path, bool allowFile)
    {
        var resolved = _resolver.Resolve(path);
        var canonicalRelative = _resolver.RelativePath(resolved);
        if (ContainsGitMetadataComponent(canonicalRelative))
            throw new FileMcpException(".git is always excluded from search");
        if (Directory.Exists(resolved))
        {
            return new RipgrepTarget(resolved, ".", canonicalRelative);
        }
        if (allowFile && File.Exists(resolved) && Path.GetDirectoryName(resolved) is { } parent)
        {
            return new RipgrepTarget(parent, Path.GetFileName(resolved), _resolver.RelativePath(parent));
        }
        throw new FileMcpException($"No such search directory: {(string.IsNullOrEmpty(path) ? "." : path)}");
    }

    private static bool ContainsGitMetadataComponent(string relativePath) =>
        relativePath.Split(['/', '\\'], StringSplitOptions.RemoveEmptyEntries)
            .Any(component => string.Equals(component, ".git", StringComparison.OrdinalIgnoreCase));

    private static string TrimDirectorySeparators(string path) =>
        path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private bool IsCanonicalWorkspacePath(string relative)
    {
        try
        {
            var expected = Path.GetFullPath(Path.Combine(_resolver.Root, relative.Replace('/', Path.DirectorySeparatorChar)));
            return string.Equals(
                TrimDirectorySeparators(_resolver.Resolve(relative)), TrimDirectorySeparators(expected), StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>
    /// Accepts a ripgrep output path only when it names a regular file whose parent directory canonicalizes to
    /// itself inside the shared root; reparse-point files must also canonicalize to themselves.
    /// </summary>
    private (string Path, DateTime Modified)? ValidatedSearchPath(
        string outputPath, string basePath, Dictionary<string, bool> directoryCache)
    {
        if (outputPath.Length == 0 || Path.IsPathRooted(outputPath)) return null;
        var relative = basePath.Length == 0 ? outputPath : basePath + "/" + outputPath;
        var components = relative.Split('/');
        if (components.Any(component => component.Length == 0 || component is "." or "..")) return null;

        var parentRelative = string.Join('/', components[..^1]);
        if (!directoryCache.TryGetValue(parentRelative, out var safeDirectory))
        {
            safeDirectory = IsCanonicalWorkspacePath(parentRelative);
            directoryCache[parentRelative] = safeDirectory;
        }
        if (!safeDirectory) return null;
        try
        {
            var info = new FileInfo(Path.Combine(_resolver.Root, relative.Replace('/', Path.DirectorySeparatorChar)));
            if (!info.Exists || (info.Attributes & FileAttributes.Directory) != 0) return null;
            if ((info.Attributes & FileAttributes.ReparsePoint) != 0 && !IsCanonicalWorkspacePath(relative)) return null;
            return (relative, info.LastWriteTimeUtc);
        }
        catch (Exception)
        {
            return null;
        }
    }

    private static string ValidatedSearchGlob(string value, string argument)
    {
        if (value.Length == 0 || value.Length > FileMcpConstants.MaxSearchGlobChars || value.Any(c => c is '\n' or '\r'))
            throw new FileMcpException($"{argument} must be 1...{FileMcpConstants.MaxSearchGlobChars} characters on one line");
        return value;
    }

    private static (List<T> Items, JsonNode? NextOffset) SearchPage<T>(
        List<T> items, int offset, int limit, HashSet<string> reasons)
    {
        var start = Math.Min(Math.Max(0, offset), items.Count);
        var end = Math.Min(start + limit, items.Count);
        if (end >= items.Count) return (items.GetRange(start, end - start), null);
        reasons.Add("head_limit");
        return (items.GetRange(start, end - start), JsonValue.Create(end));
    }

    private static HashSet<string> SearchTruncationReasons(RipgrepOutput output)
    {
        var reasons = new HashSet<string>(StringComparer.Ordinal);
        if (output.TimedOut) reasons.Add("timeout");
        if (output.OutputLimited) reasons.Add("output_limit");
        if (output.SearchErrors > 0) reasons.Add("search_error");
        return reasons;
    }

    private static List<string> SortedNewestFirst(IEnumerable<(string Path, DateTime Modified)> items) =>
        items.OrderByDescending(item => item.Modified).ThenBy(item => item.Path, StringComparer.Ordinal)
            .Select(item => item.Path).ToList();

    private static JsonArray SortedReasons(HashSet<string> reasons) =>
        JsonStringArray(reasons.OrderBy(value => value, StringComparer.Ordinal));

    private static JsonArray DefaultExcludedDirectoryNames() => JsonStringArray(Ripgrep.ExcludedDirectoryNames);

    private async Task<JsonObject> GrepAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        var pattern = GetRequiredString(arguments, "pattern");
        if (pattern.Length == 0 || pattern.Length > FileMcpConstants.MaxSearchPatternChars)
            throw new FileMcpException($"pattern must be 1...{FileMcpConstants.MaxSearchPatternChars} characters");
        var path = GetString(arguments, "path", "");
        var outputMode = GetString(arguments, "output_mode", "files_with_matches");
        var includeIgnored = GetBool(arguments, "include_ignored", false);
        var context = GetInt(arguments, "context", 0);
        var contextBefore = GetInt(arguments, "context_before", context);
        var contextAfter = GetInt(arguments, "context_after", context);
        var headLimit = GetInt(arguments, "head_limit", FileMcpConstants.DefaultSearchHeadLimit);
        var offset = GetInt(arguments, "offset", 0);

        var ripgrepArguments = new List<string> { GetBool(arguments, "case_insensitive", false) ? "--ignore-case" : "--case-sensitive" };
        if (GetBool(arguments, "fixed_strings", false)) ripgrepArguments.Add("--fixed-strings");
        if (GetBool(arguments, "multiline", false)) ripgrepArguments.AddRange(["--multiline", "--multiline-dotall"]);
        if (arguments["glob"] is JsonValue globValue && globValue.TryGetValue<string>(out var glob))
            ripgrepArguments.Add($"--iglob={ValidatedSearchGlob(glob, "glob")}");
        if (arguments["type"] is JsonValue typeValue && typeValue.TryGetValue<string>(out var fileType))
        {
            if (!System.Text.RegularExpressions.Regex.IsMatch(fileType, "^[A-Za-z0-9_+-]{1,32}$"))
                throw new FileMcpException("type must be a ripgrep file type name such as swift, js, or py");
            ripgrepArguments.Add($"--type={fileType}");
        }
        switch (outputMode)
        {
            case "content":
                ripgrepArguments.AddRange(["--json", $"--before-context={contextBefore}", $"--after-context={contextAfter}"]);
                break;
            case "count":
                ripgrepArguments.AddRange(["--count", "--null"]);
                break;
            default:
                ripgrepArguments.AddRange(["--files-with-matches", "--null"]);
                break;
        }
        ripgrepArguments.Add($"--regexp={pattern}");

        var target = ResolveRipgrepTarget(path, allowFile: true);
        var output = await _ripgrep.RunAsync(ripgrepArguments, includeIgnored, target.Cwd, target.Argument, cancellationToken)
            .ConfigureAwait(false);
        var reasons = SearchTruncationReasons(output);
        var directoryCache = new Dictionary<string, bool>(StringComparer.Ordinal);
        var unsafePathsSkipped = 0;
        var files = new JsonArray();
        var counts = new JsonArray();
        var matches = new JsonArray();
        var total = 0;
        JsonNode? nextOffset = null;

        switch (outputMode)
        {
            case "content":
            {
                var validatedPaths = new Dictionary<string, string?>(StringComparer.Ordinal);
                var linesByPath = new Dictionary<string, Dictionary<int, RipgrepLine>>(StringComparer.Ordinal);
                foreach (var line in Ripgrep.JsonLines(output))
                {
                    if (!validatedPaths.TryGetValue(line.Path, out var relative))
                    {
                        relative = ValidatedSearchPath(line.Path, target.Base, directoryCache)?.Path;
                        if (relative is null) unsafePathsSkipped++;
                        validatedPaths[line.Path] = relative;
                    }
                    if (relative is null) continue;
                    if (!linesByPath.TryGetValue(relative, out var fileLines))
                    {
                        fileLines = new Dictionary<int, RipgrepLine>();
                        linesByPath[relative] = fileLines;
                    }
                    if (line.IsMatch || !fileLines.ContainsKey(line.LineNumber)) fileLines[line.LineNumber] = line;
                }

                var entries = linesByPath
                    .SelectMany(pair => pair.Value.Where(line => line.Value.IsMatch).Select(line => (Path: pair.Key, Line: line.Key)))
                    .OrderBy(entry => entry.Path, StringComparer.Ordinal).ThenBy(entry => entry.Line)
                    .ToList();
                total = entries.Count;

                var index = Math.Min(offset, entries.Count);
                var previewChars = 0;
                while (index < entries.Count && matches.Count < headLimit)
                {
                    var entry = entries[index];
                    var fileLines = linesByPath[entry.Path];
                    JsonArray ContextLines(int first, int last)
                    {
                        var contextArray = new JsonArray();
                        for (var number = first; number <= last; number++)
                        {
                            if (fileLines.TryGetValue(number, out var contextLine))
                                contextArray.Add(new JsonObject { ["line"] = number, ["text"] = ClippedSearchLine(contextLine.Text) });
                        }
                        return contextArray;
                    }
                    var text = ClippedSearchLine(fileLines[entry.Line].Text);
                    var before = contextBefore > 0 ? ContextLines(Math.Max(1, entry.Line - contextBefore), entry.Line - 1) : new JsonArray();
                    var after = contextAfter > 0 ? ContextLines(entry.Line + 1, entry.Line + contextAfter) : new JsonArray();
                    var size = text.Length + before.Concat(after).Sum(node => node!["text"]!.GetValue<string>().Length);
                    if (matches.Count > 0 && previewChars + size > FileMcpConstants.MaxSearchPreviewChars)
                    {
                        reasons.Add("preview_limit");
                        break;
                    }
                    previewChars += size;
                    matches.Add(new JsonObject
                    {
                        ["path"] = entry.Path, ["line"] = entry.Line, ["text"] = text, ["before"] = before, ["after"] = after,
                    });
                    index++;
                }
                if (index < entries.Count)
                {
                    if (!reasons.Contains("preview_limit")) reasons.Add("head_limit");
                    nextOffset = JsonValue.Create(index);
                }
                break;
            }
            case "count":
            {
                var validatedCounts = new List<(string Path, int Count)>();
                foreach (var item in Ripgrep.NulSeparatedCounts(output))
                {
                    if (ValidatedSearchPath(item.Path, target.Base, directoryCache) is not { } validated)
                    {
                        unsafePathsSkipped++;
                        continue;
                    }
                    validatedCounts.Add((validated.Path, item.Count));
                }
                validatedCounts.Sort((left, right) => string.Compare(left.Path, right.Path, StringComparison.Ordinal));
                total = validatedCounts.Count;
                var page = SearchPage(validatedCounts, offset, headLimit, reasons);
                foreach (var item in page.Items) counts.Add(new JsonObject { ["path"] = item.Path, ["count"] = item.Count });
                nextOffset = page.NextOffset;
                break;
            }
            default:
            {
                var validatedFiles = new List<(string Path, DateTime Modified)>();
                foreach (var outputPath in Ripgrep.NulSeparatedPaths(output))
                {
                    if (ValidatedSearchPath(outputPath, target.Base, directoryCache) is not { } validated)
                    {
                        unsafePathsSkipped++;
                        continue;
                    }
                    validatedFiles.Add(validated);
                }
                total = validatedFiles.Count;
                var page = SearchPage(SortedNewestFirst(validatedFiles), offset, headLimit, reasons);
                foreach (var item in page.Items) files.Add(JsonValue.Create(item));
                nextOffset = page.NextOffset;
                break;
            }
        }

        return new JsonObject
        {
            ["pattern"] = pattern,
            ["path"] = path,
            ["output_mode"] = outputMode,
            ["include_ignored"] = includeIgnored,
            ["files"] = files,
            ["counts"] = counts,
            ["matches"] = matches,
            ["total"] = total,
            ["returned"] = files.Count + counts.Count + matches.Count,
            ["offset"] = offset,
            ["next_offset"] = nextOffset,
            ["truncated"] = reasons.Count > 0,
            ["truncation_reasons"] = SortedReasons(reasons),
            ["unsafe_paths_skipped"] = unsafePathsSkipped,
            ["search_errors"] = output.SearchErrors,
            ["default_excluded_directory_names"] = DefaultExcludedDirectoryNames(),
        };
    }

    private async Task<JsonObject> GlobAsync(JsonObject arguments, CancellationToken cancellationToken)
    {
        var pattern = ValidatedSearchGlob(GetRequiredString(arguments, "pattern"), "pattern");
        var path = GetString(arguments, "path", "");
        var includeIgnored = GetBool(arguments, "include_ignored", false);
        var offset = GetInt(arguments, "offset", 0);

        var target = ResolveRipgrepTarget(path, allowFile: false);
        var output = await _ripgrep.RunAsync(
            ["--files", "--null", $"--iglob={pattern}"], includeIgnored, target.Cwd, target.Argument, cancellationToken, limitFileSize: false).ConfigureAwait(false);
        var reasons = SearchTruncationReasons(output);
        var directoryCache = new Dictionary<string, bool>(StringComparer.Ordinal);
        var unsafePathsSkipped = 0;
        var validatedFiles = new List<(string Path, DateTime Modified)>();
        foreach (var outputPath in Ripgrep.NulSeparatedPaths(output))
        {
            if (ValidatedSearchPath(outputPath, target.Base, directoryCache) is not { } validated)
            {
                unsafePathsSkipped++;
                continue;
            }
            validatedFiles.Add(validated);
        }
        var page = SearchPage(
            SortedNewestFirst(validatedFiles), offset, GetInt(arguments, "head_limit", FileMcpConstants.DefaultSearchHeadLimit), reasons);

        return new JsonObject
        {
            ["pattern"] = pattern,
            ["path"] = path,
            ["include_ignored"] = includeIgnored,
            ["files"] = JsonStringArray(page.Items),
            ["total"] = validatedFiles.Count,
            ["returned"] = page.Items.Count,
            ["offset"] = offset,
            ["next_offset"] = page.NextOffset,
            ["truncated"] = reasons.Count > 0,
            ["truncation_reasons"] = SortedReasons(reasons),
            ["unsafe_paths_skipped"] = unsafePathsSkipped,
            ["search_errors"] = output.SearchErrors,
            ["default_excluded_directory_names"] = DefaultExcludedDirectoryNames(),
        };
    }

    private async Task<JsonObject> SearchCodeAsync(
        JsonNode? queriesNode, string path, bool caseSensitive, int maxResultsPerQuery, bool includeIgnored,
        CancellationToken cancellationToken)
    {
        if (queriesNode is not JsonArray rawQueries || rawQueries.Count is < 1 or > FileMcpConstants.MaxSearchCodeQueries)
            throw new FileMcpException($"queries must contain 1...{FileMcpConstants.MaxSearchCodeQueries} string(s)");

        var queries = new List<string>(rawQueries.Count);
        for (var index = 0; index < rawQueries.Count; index++)
        {
            if (rawQueries[index] is not JsonValue value || !value.TryGetValue<string>(out var query))
                throw new FileMcpException($"queries[{index}] must be a string");
            if (query.Length == 0) throw new FileMcpException($"queries[{index}] must not be empty");
            if (query.Length > FileMcpConstants.MaxSearchCodeQueryChars)
                throw new FileMcpException(
                    $"queries[{index}] is longer than {FileMcpConstants.MaxSearchCodeQueryChars} characters");
            if (query.Any(c => c is '\n' or '\r')) throw new FileMcpException($"queries[{index}] must be a single line");
            queries.Add(query);
        }

        var target = ResolveRipgrepTarget(path, allowFile: false);
        var ripgrepArguments = new List<string>
        {
            "--files-with-matches", "--null", "--fixed-strings", caseSensitive ? "--case-sensitive" : "--ignore-case",
        };
        ripgrepArguments.AddRange(queries.Select(query => $"--regexp={query}"));
        var output = await _ripgrep.RunAsync(ripgrepArguments, includeIgnored, target.Cwd, target.Argument, cancellationToken)
            .ConfigureAwait(false);
        var reasons = SearchTruncationReasons(output);
        var directoryCache = new Dictionary<string, bool>(StringComparer.Ordinal);
        var unsafePathsSkipped = 0;
        var candidateFiles = new List<string>();
        foreach (var outputPath in Ripgrep.NulSeparatedPaths(output))
        {
            if (ValidatedSearchPath(outputPath, target.Base, directoryCache) is not { } validated)
            {
                unsafePathsSkipped++;
                continue;
            }
            candidateFiles.Add(validated.Path);
        }
        candidateFiles.Sort(StringComparer.Ordinal);

        var max = Math.Clamp(maxResultsPerQuery, 1, FileMcpConstants.MaxSearchCodeResultsPerQuery);
        var states = queries.Select(query => new CodeSearchQueryState(query)).ToList();
        var filesRanked = 0;
        long bytesRead = 0;
        foreach (var relative in candidateFiles)
        {
            if (filesRanked >= FileMcpConstants.MaxSearchCodeFiles)
            {
                reasons.Add("file_limit");
                break;
            }
            byte[] data;
            try
            {
                data = File.ReadAllBytes(Path.Combine(_resolver.Root, relative.Replace('/', Path.DirectorySeparatorChar)));
            }
            catch (Exception)
            {
                continue;
            }
            if (data.Length > Ripgrep.MaxFileBytes || data.AsSpan(0, Math.Min(8192, data.Length)).Contains((byte)0)) continue;
            if (bytesRead + data.Length > FileMcpConstants.MaxSearchCodeBytes)
            {
                reasons.Add("byte_limit");
                break;
            }
            bytesRead += data.Length;
            filesRanked++;
            RankCodeSearchFile(relative, SplitTextLines(Encoding.UTF8.GetString(data)), states, caseSensitive, max);
        }

        var queryResults = new JsonArray();
        foreach (var state in states)
        {
            state.Candidates.Sort(CompareCodeSearchCandidates);
            var matches = new JsonArray();
            foreach (var candidate in state.Candidates)
            {
                matches.Add(new JsonObject
                {
                    ["path"] = candidate.Path,
                    ["line"] = candidate.Line,
                    ["line_text"] = candidate.LineText,
                    ["score"] = candidate.Score,
                    ["signals"] = JsonStringArray(candidate.Signals),
                });
            }
            queryResults.Add(new JsonObject
            {
                ["query"] = state.Query,
                ["observed_matching_lines"] = state.ObservedMatches,
                ["returned_matches"] = state.Candidates.Count,
                ["result_limit_reached"] = state.ObservedMatches > state.Candidates.Count,
                ["matches"] = matches,
            });
        }

        return new JsonObject
        {
            ["path"] = path,
            ["case_sensitive"] = caseSensitive,
            ["include_ignored"] = includeIgnored,
            ["query_results"] = queryResults,
            ["truncated"] = reasons.Count > 0,
            ["truncation_reasons"] = SortedReasons(reasons),
            ["files_matched"] = candidateFiles.Count,
            ["files_ranked"] = filesRanked,
            ["unsafe_paths_skipped"] = unsafePathsSkipped,
            ["search_errors"] = output.SearchErrors,
            ["default_excluded_directory_names"] = DefaultExcludedDirectoryNames(),
        };
    }

    private static void RankCodeSearchFile(
        string relative, List<string> lines, List<CodeSearchQueryState> states, bool caseSensitive, int limit)
    {
        var comparison = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var lexicalState = CodeSearchLexicalStateForPath(relative);
        for (var lineIndex = 0; lineIndex < lines.Count; lineIndex++)
        {
            var line = lines[lineIndex];
            List<CodeSearchQueryState>? matchingStates = null;
            foreach (var state in states)
            {
                if (!line.Contains(state.Query, comparison)) continue;
                state.ObservedMatches++;
                (matchingStates ??= []).Add(state);
            }

            var needsLexicalScan = matchingStates is not null || lexicalState.IsActive ||
                line.Contains("/*", StringComparison.Ordinal) ||
                line.Contains("\"\"\"", StringComparison.Ordinal) ||
                line.Contains("'''", StringComparison.Ordinal) ||
                (lexicalState.SupportsPowerShellBlockComments && line.Contains("<#", StringComparison.Ordinal)) ||
                (lexicalState.SupportsMultilineBackticks && line.Contains('`'));
            var codeLine = needsLexicalScan ? CodeOnlySearchLine(line, lexicalState) : line;
            if (matchingStates is null) continue;

            var tokens = CodeIdentifierTokens(codeLine);
            foreach (var state in matchingStates)
            {
                var ranking = CodeSearchRanking(state.Query, codeLine, tokens, relative, caseSensitive);
                RetainCodeSearchCandidate(
                    new CodeSearchCandidate(relative, lineIndex + 1, ClippedSearchLine(line), ranking.Score, ranking.Signals),
                    state.Candidates, limit);
            }
        }
    }

    private static List<string> CodeIdentifierTokens(string line)
    {
        var tokens = new List<string>();
        var start = -1;
        for (var index = 0; index < line.Length; index++)
        {
            if (IsCodeIdentifierCharacter(line[index]))
            {
                if (start < 0) start = index;
            }
            else if (start >= 0)
            {
                tokens.Add(line[start..index]);
                start = -1;
            }
        }
        if (start >= 0) tokens.Add(line[start..]);
        return tokens;
    }

    private static bool IsCodeIdentifierCharacter(char value) => char.IsLetterOrDigit(value) || value is '_' or '$';

    private static bool IsCodeIdentifier(string value) => value.Length > 0 && value.All(IsCodeIdentifierCharacter);

    private static bool CodeTokenEquals(string token, string query, bool caseSensitive) =>
        string.Equals(token, query, caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase);

    private static bool IsLikelyCodeDeclaration(string query, IReadOnlyList<string> tokens, bool caseSensitive)
    {
        if (!IsCodeIdentifier(query) || tokens.Count < 2) return false;
        for (var index = 1; index < tokens.Count; index++)
        {
            if (CodeTokenEquals(tokens[index], query, caseSensitive) && CodeDeclarationKeywords.Contains(tokens[index - 1].ToLowerInvariant()))
                return true;
        }
        return false;
    }

    private static CodeSearchLexicalState CodeSearchLexicalStateForPath(string relativePath)
    {
        var extension = Path.GetExtension(relativePath).ToLowerInvariant();
        var supportsNestedBlockComments = extension is ".swift" or ".rs" or ".kt" or ".kts" or ".scala";
        var supportsMultilineBackticks = extension is ".go" or ".js" or ".jsx" or ".mjs" or ".cjs" or ".ts" or ".tsx" or ".vue" or ".svelte";
        var supportsHashLineComments = extension is ".bash" or ".fish" or ".pl" or ".pm" or ".ps1" or
            ".py" or ".pyi" or ".r" or ".rb" or ".sh" or ".zsh";
        return new CodeSearchLexicalState(
            supportsNestedBlockComments, supportsMultilineBackticks, supportsHashLineComments, extension == ".ps1");
    }

    private static string CodeOnlySearchLine(string line, CodeSearchLexicalState state)
    {
        var chars = line.ToCharArray();
        char? quote = null;
        var escaping = false;

        static bool HasTripleQuote(char[] values, char quoteValue, int index) =>
            index + 2 < values.Length &&
            values[index] == quoteValue && values[index + 1] == quoteValue && values[index + 2] == quoteValue;

        for (var index = 0; index < chars.Length;)
        {
            var value = chars[index];

            if (state.InPowerShellBlockComment)
            {
                chars[index] = ' ';
                if (value == '#' && index + 1 < chars.Length && chars[index + 1] == '>')
                {
                    chars[index + 1] = ' ';
                    state.InPowerShellBlockComment = false;
                    index += 2;
                }
                else index++;
                continue;
            }

            if (state.BlockCommentDepth > 0)
            {
                chars[index] = ' ';
                if (state.SupportsNestedBlockComments && value == '/' && index + 1 < chars.Length && chars[index + 1] == '*')
                {
                    chars[index + 1] = ' ';
                    state.BlockCommentDepth++;
                    index += 2;
                }
                else if (value == '*' && index + 1 < chars.Length && chars[index + 1] == '/')
                {
                    chars[index + 1] = ' ';
                    state.BlockCommentDepth--;
                    index += 2;
                }
                else index++;
                continue;
            }

            if (state.MultilineQuote.HasValue)
            {
                var multilineQuote = state.MultilineQuote.Value;
                if (multilineQuote == '`')
                {
                    chars[index] = ' ';
                    if (state.MultilineEscaping) state.MultilineEscaping = false;
                    else if (value == '\\') state.MultilineEscaping = true;
                    else if (value == '`') state.MultilineQuote = null;
                    index++;
                    continue;
                }

                if (HasTripleQuote(chars, multilineQuote, index))
                {
                    chars[index] = chars[index + 1] = chars[index + 2] = ' ';
                    state.MultilineQuote = null;
                    index += 3;
                }
                else
                {
                    chars[index] = ' ';
                    index++;
                }
                continue;
            }

            if (quote.HasValue)
            {
                chars[index] = ' ';
                if (escaping) escaping = false;
                else if (value == '\\') escaping = true;
                else if (value == quote.Value) quote = null;
                index++;
                continue;
            }

            if (state.SupportsPowerShellBlockComments && value == '<' &&
                index + 1 < chars.Length && chars[index + 1] == '#')
            {
                chars[index] = chars[index + 1] = ' ';
                state.InPowerShellBlockComment = true;
                index += 2;
                continue;
            }
            if (value == '/' && index + 1 < chars.Length && chars[index + 1] == '*')
            {
                chars[index] = chars[index + 1] = ' ';
                state.BlockCommentDepth = 1;
                index += 2;
                continue;
            }
            if (HasTripleQuote(chars, '"', index) || HasTripleQuote(chars, '\'', index))
            {
                state.MultilineQuote = value;
                chars[index] = chars[index + 1] = chars[index + 2] = ' ';
                index += 3;
                continue;
            }
            if (value == '`' && state.SupportsMultilineBackticks)
            {
                state.MultilineQuote = value;
                state.MultilineEscaping = false;
                chars[index] = ' ';
                index++;
                continue;
            }
            if (value is '\'' or '"')
            {
                quote = value;
                chars[index] = ' ';
                index++;
                continue;
            }
            if (value == '/' && index + 1 < chars.Length && chars[index + 1] == '/')
            {
                Array.Fill(chars, ' ', index, chars.Length - index);
                break;
            }
            if (value == '#' && state.SupportsHashLineComments)
            {
                Array.Fill(chars, ' ', index, chars.Length - index);
                break;
            }
            index++;
        }
        return new string(chars);
    }

    private static bool IsPlausibleTypedDeclarationPrefix(string prefix)
    {
        var trimmed = prefix.TrimEnd();
        if (trimmed.Length == 0 ||
            trimmed.EndsWith(".", StringComparison.Ordinal) ||
            trimmed.EndsWith("::", StringComparison.Ordinal) ||
            trimmed.EndsWith("->", StringComparison.Ordinal) ||
            trimmed.Contains('=') ||
            trimmed.Contains('('))
            return false;
        var prefixTokens = CodeIdentifierTokens(trimmed);
        return prefixTokens.Count > 0 && !CodeNonDeclarationPrefixKeywords.Contains(prefixTokens[0]);
    }

    private static bool CodeSuffixStartsParameterList(string codeLine, int start)
    {
        var index = start;
        while (index < codeLine.Length && char.IsWhiteSpace(codeLine[index])) index++;
        if (index >= codeLine.Length) return false;
        if (codeLine[index] == '(') return true;
        if (codeLine[index] != '<') return false;

        var depth = 0;
        for (; index < codeLine.Length; index++)
        {
            if (codeLine[index] == '<') depth++;
            else if (codeLine[index] == '>')
            {
                depth--;
                if (depth == 0)
                {
                    index++;
                    while (index < codeLine.Length && char.IsWhiteSpace(codeLine[index])) index++;
                    return index < codeLine.Length && codeLine[index] == '(';
                }
            }
        }
        return false;
    }

    private static bool IsLikelyTypedFunctionDeclaration(string query, string codeLine, bool caseSensitive)
    {
        if (!IsCodeIdentifier(query)) return false;
        var comparison = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var searchIndex = 0;
        while (searchIndex <= codeLine.Length - query.Length)
        {
            var index = codeLine.IndexOf(query, searchIndex, comparison);
            if (index < 0) break;
            var end = index + query.Length;
            var wholeBefore = index == 0 || !IsCodeIdentifierCharacter(codeLine[index - 1]);
            var wholeAfter = end == codeLine.Length || !IsCodeIdentifierCharacter(codeLine[end]);
            if (wholeBefore && wholeAfter &&
                CodeSuffixStartsParameterList(codeLine, end) &&
                IsPlausibleTypedDeclarationPrefix(codeLine[..index]))
                return true;
            searchIndex = Math.Max(end, index + 1);
        }
        return false;
    }

    private static bool IsLikelyTypedValueDeclaration(string query, string codeLine, bool caseSensitive)
    {
        if (!IsCodeIdentifier(query)) return false;
        var comparison = caseSensitive ? StringComparison.Ordinal : StringComparison.OrdinalIgnoreCase;
        var searchIndex = 0;
        while (searchIndex <= codeLine.Length - query.Length)
        {
            var index = codeLine.IndexOf(query, searchIndex, comparison);
            if (index < 0) break;
            var end = index + query.Length;
            var wholeBefore = index == 0 || !IsCodeIdentifierCharacter(codeLine[index - 1]);
            var wholeAfter = end == codeLine.Length || !IsCodeIdentifierCharacter(codeLine[end]);
            if (wholeBefore && wholeAfter)
            {
                var suffix = end;
                while (suffix < codeLine.Length && char.IsWhiteSpace(codeLine[suffix])) suffix++;
                if (suffix < codeLine.Length && (codeLine[suffix] is '=' or ':' or '{' or ';' or ',' or '[') &&
                    IsPlausibleTypedDeclarationPrefix(codeLine[..index]))
                    return true;
            }
            searchIndex = Math.Max(end, index + 1);
        }
        return false;
    }

    private static (int Score, string[] Signals) CodeSearchRanking(
        string query, string codeLine, IReadOnlyList<string> tokens, string relativePath, bool caseSensitive)
    {
        var score = 0;
        var signals = new List<string>();
        if (!caseSensitive && codeLine.Contains(query, StringComparison.Ordinal))
        {
            score += 10;
            signals.Add("exact_case");
        }
        if (IsCodeIdentifier(query))
        {
            var wholeIdentifier = tokens.Any(token => CodeTokenEquals(token, query, caseSensitive));
            if (wholeIdentifier)
            {
                score += 30;
                signals.Add("whole_identifier");
            }
            if (wholeIdentifier && (
                IsLikelyCodeDeclaration(query, tokens, caseSensitive) ||
                IsLikelyTypedFunctionDeclaration(query, codeLine, caseSensitive) ||
                IsLikelyTypedValueDeclaration(query, codeLine, caseSensitive)))
            {
                score += 100;
                signals.Add("likely_declaration");
            }
            var stem = Path.GetFileNameWithoutExtension(relativePath);
            if (string.Equals(stem, query, StringComparison.OrdinalIgnoreCase))
            {
                score += 40;
                signals.Add("filename_exact");
            }
            else if (stem.Contains(query, StringComparison.OrdinalIgnoreCase))
            {
                score += 20;
                signals.Add("filename_match");
            }
        }
        return (score, signals.ToArray());
    }

    private static string ClippedSearchLine(string line) => line.Length > FileMcpConstants.MaxSearchPreviewLineChars
        ? line[..FileMcpConstants.MaxSearchPreviewLineChars] + "..." : line;

    private static int CompareCodeSearchCandidates(CodeSearchCandidate left, CodeSearchCandidate right)
    {
        var score = right.Score.CompareTo(left.Score);
        if (score != 0) return score;
        var path = string.Compare(left.Path, right.Path, StringComparison.Ordinal);
        return path != 0 ? path : left.Line.CompareTo(right.Line);
    }

    private static void RetainCodeSearchCandidate(CodeSearchCandidate candidate, List<CodeSearchCandidate> candidates, int limit)
    {
        candidates.Add(candidate);
        candidates.Sort(CompareCodeSearchCandidates);
        if (candidates.Count > limit) candidates.RemoveRange(limit, candidates.Count - limit);
    }

    private static bool IsRepoManifestName(string name) => RepoManifestNames.Contains(name) ||
        RepoManifestSuffixes.Any(suffix => name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase));

    private int CollectRepoDirectories(
        string searchRoot, bool includeIgnored, HashSet<string> ignoredDirectoryRoots,
        HashSet<string> directories, HashSet<string> manifests,
        HashSet<string> truncationReasons, CancellationToken cancellationToken)
    {
        var excludedNames = new HashSet<string>(Ripgrep.ExcludedDirectoryNames, StringComparer.OrdinalIgnoreCase);
        var visited = 0;
        var enumerationErrors = 0;
        var pending = new Stack<string>();
        pending.Push(searchRoot);

        while (pending.Count > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var directory = pending.Pop();
            IEnumerator<FileSystemInfo>? entries = null;
            try
            {
                entries = new DirectoryInfo(directory).EnumerateFileSystemInfos().GetEnumerator();
                while (true)
                {
                    cancellationToken.ThrowIfCancellationRequested();
                    FileSystemInfo entry;
                    try
                    {
                        if (!entries.MoveNext()) break;
                        entry = entries.Current;
                    }
                    catch
                    {
                        enumerationErrors++;
                        truncationReasons.Add("enumeration_error");
                        break;
                    }

                    visited++;
                    if (visited > FileMcpConstants.MaxRepoOverviewDirectoryScanEntries)
                    {
                        truncationReasons.Add("visited_limit");
                        pending.Clear();
                        break;
                    }

                    FileAttributes attributes;
                    try { attributes = entry.Attributes; }
                    catch
                    {
                        enumerationErrors++;
                        truncationReasons.Add("enumeration_error");
                        continue;
                    }
                    if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0) continue;
                    if (string.Equals(entry.Name, ".git", StringComparison.OrdinalIgnoreCase) ||
                        (!includeIgnored && excludedNames.Contains(entry.Name))) continue;
                    if (!_resolver.Contains(entry.FullName)) continue;

                    string relative;
                    try { relative = _resolver.RelativePath(entry.FullName); }
                    catch { continue; }
                    if (relative.Length == 0) continue;
                    if (ignoredDirectoryRoots.Contains(relative)) continue;
                    directories.Add(relative);
                    if (IsRepoManifestName(entry.Name)) manifests.Add(relative);
                    pending.Push(entry.FullName);
                }
            }
            catch
            {
                enumerationErrors++;
                truncationReasons.Add("enumeration_error");
            }
            finally
            {
                entries?.Dispose();
            }
        }
        return enumerationErrors;
    }

    private async Task<JsonObject> RepoOverviewAsync(string path, bool includeIgnored, CancellationToken cancellationToken)
    {
        var searchRoot = _resolver.Resolve(path);
        if (!Directory.Exists(searchRoot))
            throw new FileMcpException($"No such repository directory: {(string.IsNullOrEmpty(path) ? "." : path)}");

        var target = ResolveRipgrepTarget(path, allowFile: false);
        var topLevel = ListFiles(path);
        var repoArguments = new List<string> { "--files", "--null" };
        if (!includeIgnored) repoArguments.Add("--debug");
        var output = await _ripgrep.RunAsync(repoArguments, includeIgnored, target.Cwd, target.Argument, cancellationToken, limitFileSize: false)
            .ConfigureAwait(false);
        var truncationReasons = SearchTruncationReasons(output);
        var manifests = new HashSet<string>(StringComparer.Ordinal);
        var extensionCounts = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var ignoredDirectoryRoots = new HashSet<string>(
            output.IgnoredPaths.Select(ignoredPath => target.Base.Length == 0 ? ignoredPath : target.Base + "/" + ignoredPath),
            StringComparer.OrdinalIgnoreCase);
        var directoryEnumerationErrors = 0;
        var canEnumerateDirectories = includeIgnored ||
            (!output.TimedOut && !output.DiagnosticsLimited && output.SearchErrors == 0);
        if (canEnumerateDirectories)
        {
            directoryEnumerationErrors = CollectRepoDirectories(
                searchRoot, includeIgnored, ignoredDirectoryRoots, directories, manifests, truncationReasons, cancellationToken);
        }
        else if (output.DiagnosticsLimited)
        {
            truncationReasons.Add("ignore_diagnostics_limit");
        }
        var filesSeen = 0;
        var unsafePathsSkipped = 0;
        var directoryCache = new Dictionary<string, bool>(StringComparer.Ordinal);

        foreach (var outputPath in Ripgrep.NulSeparatedPaths(output))
        {
            if (ValidatedSearchPath(outputPath, target.Base, directoryCache) is not { } validated)
            {
                unsafePathsSkipped++;
                continue;
            }
            filesSeen++;
            var components = outputPath.Split('/', StringSplitOptions.RemoveEmptyEntries);
            var directory = target.Base;
            foreach (var component in components[..^1])
            {
                directory = directory.Length == 0 ? component : directory + "/" + component;
                if (directories.Add(directory) && IsRepoManifestName(component)) manifests.Add(directory);
            }
            var fileName = components.Length > 0 ? components[^1] : outputPath;
            if (IsRepoManifestName(fileName)) manifests.Add(validated.Path);
            var extension = Path.GetExtension(fileName);
            var key = string.IsNullOrEmpty(extension) ? "(none)" : extension.ToLowerInvariant();
            extensionCounts[key] = extensionCounts.GetValueOrDefault(key) + 1;
        }

        var sortedManifests = manifests.OrderBy(value => value, StringComparer.Ordinal).ToList();
        var manifestResults = sortedManifests.Take(FileMcpConstants.MaxRepoOverviewManifestResults).ToList();
        var sortedExtensions = extensionCounts.OrderByDescending(pair => pair.Value)
            .ThenBy(pair => pair.Key, StringComparer.Ordinal).ToList();
        var extensionResults = new JsonArray();
        foreach (var pair in sortedExtensions.Take(FileMcpConstants.MaxRepoOverviewExtensionResults))
            extensionResults.Add(new JsonObject { ["extension"] = pair.Key, ["count"] = pair.Value });

        return new JsonObject
        {
            ["path"] = path,
            ["include_ignored"] = includeIgnored,
            ["top_level_entries"] = JsonStringArray(topLevel.Values),
            ["top_level_truncated"] = topLevel.Truncated,
            ["manifests"] = JsonStringArray(manifestResults),
            ["manifest_results_limited"] = sortedManifests.Count > manifestResults.Count,
            ["file_extensions"] = extensionResults,
            ["extension_counts_limited"] = sortedExtensions.Count > extensionResults.Count,
            ["files_seen"] = filesSeen,
            ["directories_seen"] = directories.Count,
            ["truncated"] = truncationReasons.Count > 0,
            ["truncation_reasons"] = SortedReasons(truncationReasons),
            ["unsafe_paths_skipped"] = unsafePathsSkipped,
            ["search_errors"] = output.SearchErrors + directoryEnumerationErrors,
            ["default_excluded_directory_names"] = DefaultExcludedDirectoryNames(),
        };
    }

    private string WriteFile(string relativePath, string content, bool append)
    {
        var data = Encoding.UTF8.GetBytes(content);
        if (data.Length > FileMcpConstants.MaxWriteBytes) throw new FileMcpException("Content is larger than the 5 MB write limit");
        var target = _resolver.Resolve(relativePath);
        if (Directory.Exists(target)) throw new FileMcpException($"Not a file: {relativePath}");
        Directory.CreateDirectory(Path.GetDirectoryName(target)!);
        if (append && File.Exists(target))
        {
            using var stream = new FileStream(target, FileMode.Append, FileAccess.Write, FileShare.Read);
            stream.Write(data);
        }
        else
        {
            var temp = target + ".filemcp-" + Guid.NewGuid().ToString("N") + ".tmp";
            try { File.WriteAllBytes(temp, data); File.Move(temp, target, true); }
            finally { try { if (File.Exists(temp)) File.Delete(temp); } catch { } }
        }
        return $"{(append ? "Appended to" : "Wrote")} {relativePath} ({data.Length} bytes)";
    }

    private string DeleteFile(string relativePath)
    {
        var target = _resolver.ResolveForDeletion(relativePath);
        var attributes = _resolver.GetAttributesWithoutFollowingFinalTarget(target, $"No such file: {relativePath}");
        if ((attributes & FileAttributes.Directory) != 0 && (attributes & FileAttributes.ReparsePoint) == 0)
            throw new FileMcpException("delete_file only removes files or symlinks; use delete_directory for folders");
        if ((attributes & FileAttributes.Directory) != 0) Directory.Delete(target, false); else File.Delete(target);
        return $"Deleted {relativePath}";
    }

    private string DeleteDirectory(string relativePath)
    {
        var target = _resolver.ResolveForDeletion(relativePath);
        if (string.Equals(Path.GetFullPath(target).TrimEnd('\\'), Path.GetFullPath(_resolver.Root).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new FileMcpException("Refusing to delete the shared root directory");
        var attributes = _resolver.GetAttributesWithoutFollowingFinalTarget(target, $"No such directory: {relativePath}");
        if ((attributes & FileAttributes.ReparsePoint) != 0 || (attributes & FileAttributes.Directory) == 0)
            throw new FileMcpException($"Not a directory: {relativePath}. Use delete_file for symlinks.");
        Directory.Delete(target, true);
        return $"Deleted directory {relativePath}";
    }

    private async Task<JsonObject> SaveConversationToCodexAsync(
        string title,
        string repoPath,
        JsonNode? messagesNode,
        CancellationToken cancellationToken)
    {
        var trimmedTitle = title.Trim();
        if (string.IsNullOrWhiteSpace(trimmedTitle)) throw new FileMcpException("title must not be empty");
        if (Encoding.UTF8.GetByteCount(trimmedTitle) > 500)
            throw new FileMcpException("title is too long (maximum 500 UTF-8 bytes)");
        if (messagesNode is not JsonArray rawMessages || rawMessages.Count == 0)
            throw new FileMcpException("messages must be a non-empty array");
        if (rawMessages.Count > 500) throw new FileMcpException("messages may contain at most 500 entries");

        var messages = new List<CodexHistoryMessage>(rawMessages.Count);
        var totalBytes = 0;
        for (var index = 0; index < rawMessages.Count; index++)
        {
            if (rawMessages[index] is not JsonObject message)
                throw new FileMcpException($"messages[{index}] must be an object");
            var unexpected = message.Select(pair => pair.Key)
                .FirstOrDefault(key => key is not ("role" or "content"));
            if (unexpected is not null)
                throw new FileMcpException($"Unexpected argument in messages[{index}]: {unexpected}");
            var role = message["role"] is JsonValue roleValue && roleValue.TryGetValue<string>(out var parsedRole)
                ? parsedRole
                : throw new FileMcpException($"messages[{index}].role must be user or assistant");
            if (role is not ("user" or "assistant"))
                throw new FileMcpException($"messages[{index}].role must be user or assistant");
            var content = message["content"] is JsonValue contentValue && contentValue.TryGetValue<string>(out var parsedContent)
                ? parsedContent
                : throw new FileMcpException($"messages[{index}].content must be a string");
            if (string.IsNullOrEmpty(content))
                throw new FileMcpException($"messages[{index}].content must not be empty");
            totalBytes = checked(totalBytes + Encoding.UTF8.GetByteCount(content));
            if (totalBytes > 2_000_000)
                throw new FileMcpException("conversation content exceeds the 2 MB limit");
            messages.Add(new CodexHistoryMessage(role, content));
        }
        if (messages[0].Role != "user") throw new FileMcpException("messages must start with a user message");

        var cwd = _resolver.Resolve(repoPath);
        if (!Directory.Exists(cwd))
            throw new FileMcpException($"No such working directory: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}");

        await _codexHistorySlot.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var result = await CodexHistoryImporter.SaveAsync(trimmedTitle, cwd, messages, cancellationToken).ConfigureAwait(false);
            var normalizedRepoPath = _resolver.RelativePath(cwd);
            return new JsonObject
            {
                ["thread_id"] = result.ThreadId,
                ["title"] = result.Title,
                ["repo_path"] = string.IsNullOrEmpty(normalizedRepoPath) ? "." : normalizedRepoPath,
                ["message_count"] = result.MessageCount,
                ["turn_count"] = result.TurnCount,
            };
        }
        finally
        {
            _codexHistorySlot.Release();
        }
    }

    private async Task<string> RunCommandAsync(string command, string cwd, int timeoutSeconds, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(command)) throw new FileMcpException("command must not be empty");
        var workdir = _resolver.Resolve(cwd);
        if (!Directory.Exists(workdir)) throw new FileMcpException($"No such working directory: {(string.IsNullOrEmpty(cwd) ? "." : cwd)}");
        await _commandSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var result = await ProcessRunner.RunAsync(PowerShellPath(), ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command], workdir,
                Environment.GetEnvironmentVariables().Cast<System.Collections.DictionaryEntry>().ToDictionary(e => (string)e.Key, e => (string?)e.Value ?? "", StringComparer.OrdinalIgnoreCase),
                timeoutSeconds, FileMcpConstants.MaxToolProcessOutputBytes, cancellationToken).ConfigureAwait(false);
            if (result.TimedOut)
            {
                var partial = $"Command timed out after {Math.Clamp(timeoutSeconds, 1, ProcessRunner.MaxCommandTimeoutSeconds)} seconds.";
                if (!string.IsNullOrEmpty(result.Stdout)) partial += "\nstdout:\n" + result.Stdout;
                if (!string.IsNullOrEmpty(result.Stderr)) partial += "\nstderr:\n" + result.Stderr;
                throw new FileMcpException(partial);
            }
            return FormatProcessResult(result);
        }
        finally { _commandSlots.Release(); }
    }

    private static string PowerShellPath()
    {
        var system = Environment.GetFolderPath(Environment.SpecialFolder.System);
        var candidate = Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
        return File.Exists(candidate) ? candidate : "powershell.exe";
    }

    private static List<string> SplitTextLines(string text)
    {
        var normalized = text.Replace("\r\n", "\n").Replace('\r', '\n');
        var lines = normalized.Split('\n', StringSplitOptions.None).ToList();
        if (normalized.EndsWith('\n') && lines.Count > 1) lines.RemoveAt(lines.Count - 1);
        return lines.Count == 0 ? [""] : lines;
    }

    private static ToolCallOutput StringOutput(string value) => new(
        new JsonArray(new JsonObject { ["type"] = "text", ["text"] = value }), new JsonObject { ["result"] = value });

    private static ToolCallOutput StringArrayOutput((IReadOnlyList<string> Values, bool Truncated) value)
    {
        var content = new JsonArray(); var result = new JsonArray();
        foreach (var item in value.Values) { content.Add(new JsonObject { ["type"] = "text", ["text"] = item }); result.Add(item); }
        return new ToolCallOutput(content, new JsonObject { ["result"] = result, ["truncated"] = value.Truncated });
    }

    private static ToolCallOutput ObjectOutput(JsonObject value) => new(
        new JsonArray(new JsonObject { ["type"] = "text", ["text"] = value.ToJsonString(new JsonSerializerOptions { WriteIndented = true }) }), value);

    private static string GetRequiredString(JsonObject args, string key) => args[key] is JsonValue value && value.TryGetValue<string>(out var result) ? result : throw new FileMcpException($"Missing or invalid argument: {key}");
    private static int GetRequiredInt(JsonObject args, string key) => args[key] is JsonValue value && value.TryGetValue<int>(out var result) ? result : throw new FileMcpException($"Missing or invalid argument: {key}");
    private static string GetString(JsonObject args, string key, string fallback) => args[key] is JsonValue value && value.TryGetValue<string>(out var result) ? result : fallback;
    private static bool GetBool(JsonObject args, string key, bool fallback) => args[key] is JsonValue value && value.TryGetValue<bool>(out var result) ? result : fallback;
    private static int GetInt(JsonObject args, string key, int fallback) => args[key] is JsonValue value && value.TryGetValue<int>(out var result) ? result : fallback;

    private void ValidateArguments(string toolName, JsonObject arguments)
    {
        var definition = ToolDefinitions.OfType<JsonObject>().FirstOrDefault(tool => tool["name"]?.GetValue<string>() == toolName)
            ?? throw new FileMcpException($"Invalid tool definition: {toolName}");
        var schema = definition["inputSchema"]!.AsObject(); var properties = schema["properties"]!.AsObject();
        var required = schema["required"]!.AsArray().Select(node => node!.GetValue<string>()).ToHashSet(StringComparer.Ordinal);
        foreach (var pair in arguments)
        {
            if (!properties.ContainsKey(pair.Key)) throw new FileMcpException($"Unexpected argument: {pair.Key}");
        }
        foreach (var key in required)
        {
            if (!arguments.ContainsKey(key) || arguments[key] is null) throw new FileMcpException($"Missing or invalid argument: {key}");
        }
        foreach (var pair in arguments)
        {
            var property = properties[pair.Key]!.AsObject(); var type = property["type"]!.GetValue<string>();
            var valid = type switch
            {
                "string" => pair.Value is JsonValue stringValue && stringValue.TryGetValue<string>(out _),
                "boolean" => pair.Value is JsonValue boolValue && boolValue.TryGetValue<bool>(out _),
                "integer" => pair.Value is JsonValue intValue && intValue.TryGetValue<int>(out _),
                "array" => pair.Value is JsonArray,
                _ => true,
            };
            if (!valid) throw new FileMcpException($"Missing or invalid argument: {pair.Key}");
            if (type == "string" && property["enum"] is JsonArray allowed)
            {
                var text = pair.Value!.GetValue<string>();
                var allowedValues = allowed.Select(node => node!.GetValue<string>()).ToList();
                if (!allowedValues.Contains(text, StringComparer.Ordinal))
                    throw new FileMcpException($"Argument {pair.Key} must be one of: {string.Join(", ", allowedValues)}");
            }
            if (type == "integer")
            {
                var number = pair.Value!.GetValue<int>();
                if (property["minimum"] is JsonValue min && number < min.GetValue<int>()) throw new FileMcpException($"Argument {pair.Key} must be >= {min.GetValue<int>()}");
                if (property["maximum"] is JsonValue max && number > max.GetValue<int>()) throw new FileMcpException($"Argument {pair.Key} must be <= {max.GetValue<int>()}");
            }
            else if (type == "array" && pair.Value is JsonArray array)
            {
                if (property["minItems"] is JsonValue min && array.Count < min.GetValue<int>()) throw new FileMcpException($"Argument {pair.Key} must contain at least {min.GetValue<int>()} item(s)");
                if (property["maxItems"] is JsonValue max && array.Count > max.GetValue<int>()) throw new FileMcpException($"Argument {pair.Key} must contain at most {max.GetValue<int>()} item(s)");
            }
        }
    }

    private static JsonObject Props(params (string Key, JsonObject Value)[] values) { var result = new JsonObject(); foreach (var (key, value) in values) result[key] = value; return result; }
    private static JsonObject StringProperty(string? description = null, string? defaultValue = null) { var value = new JsonObject { ["type"] = "string" }; if (description is not null) value["description"] = description; if (defaultValue is not null) value["default"] = defaultValue; return value; }
    private static JsonObject BooleanProperty(bool defaultValue) => new() { ["type"] = "boolean", ["default"] = defaultValue };
    private static JsonObject DescribedBooleanProperty(bool defaultValue, string description) => new() { ["type"] = "boolean", ["default"] = defaultValue, ["description"] = description };
    private static JsonObject IncludeIgnoredProperty() => DescribedBooleanProperty(false, "Also include files excluded by .gitignore/.ignore and the default excluded directories; .git is always excluded.");
    private static JsonObject IntegerProperty(int? min, int? max, int? defaultValue, string? description = null) { var value = new JsonObject { ["type"] = "integer" }; if (min.HasValue) value["minimum"] = min.Value; if (max.HasValue) value["maximum"] = max.Value; if (defaultValue.HasValue) value["default"] = defaultValue.Value; if (description is not null) value["description"] = description; return value; }
    private static JsonObject Tool(string name, string description, JsonObject properties, string[] required, bool readOnly, bool destructive = false, bool openWorld = false, JsonObject? output = null) => new()
    {
        ["name"] = name, ["description"] = description,
        ["inputSchema"] = new JsonObject { ["type"] = "object", ["properties"] = properties, ["required"] = new JsonArray(required.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray()), ["additionalProperties"] = false },
        ["outputSchema"] = output ?? StringOutputSchema(),
        ["annotations"] = new JsonObject { ["readOnlyHint"] = readOnly, ["destructiveHint"] = destructive, ["openWorldHint"] = openWorld },
    };
    private static JsonArray JsonStringArray(IEnumerable<string> values) =>
        new(values.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());

    private static JsonObject SearchCodeQueriesProperty() => new()
    {
        ["type"] = "array",
        ["minItems"] = 1,
        ["maxItems"] = FileMcpConstants.MaxSearchCodeQueries,
        ["description"] = "One to six non-empty literal code queries to evaluate in one scan.",
        ["items"] = new JsonObject { ["type"] = "string" },
    };

    private static JsonObject BatchReadOperationsProperty()
    {
        var toolNames = new JsonArray(BatchReadToolNames.OrderBy(value => value, StringComparer.Ordinal)
            .Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
        return new JsonObject
        {
            ["type"] = "array",
            ["minItems"] = 1,
            ["maxItems"] = FileMcpConstants.MaxBatchReadOperations,
            ["description"] = "Ordered read-only operations to execute locally.",
            ["items"] = new JsonObject
            {
                ["type"] = "object",
                ["properties"] = new JsonObject
                {
                    ["tool"] = new JsonObject { ["type"] = "string", ["enum"] = toolNames },
                    ["arguments"] = new JsonObject { ["type"] = "object", ["additionalProperties"] = true },
                },
                ["required"] = new JsonArray("tool"),
                ["additionalProperties"] = false,
            },
        };
    }

    private static JsonObject BatchReadOutputSchema()
    {
        var result = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["index"] = new JsonObject { ["type"] = "integer" },
                ["tool"] = new JsonObject { ["type"] = "string" },
                ["ok"] = new JsonObject { ["type"] = "boolean" },
                ["structured_content"] = new JsonObject { ["type"] = "object", ["additionalProperties"] = true },
                ["error"] = new JsonObject { ["type"] = "string" },
            },
            ["required"] = new JsonArray("index", "tool", "ok"),
            ["additionalProperties"] = false,
        };
        return new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["requested"] = new JsonObject { ["type"] = "integer" },
                ["completed"] = new JsonObject { ["type"] = "integer" },
                ["succeeded"] = new JsonObject { ["type"] = "integer" },
                ["failed"] = new JsonObject { ["type"] = "integer" },
                ["stopped_on_error"] = new JsonObject { ["type"] = "boolean" },
                ["results"] = new JsonObject { ["type"] = "array", ["items"] = result },
            },
            ["required"] = new JsonArray("requested", "completed", "succeeded", "failed", "stopped_on_error", "results"),
            ["additionalProperties"] = false,
        };
    }

    private static JsonObject StringOutputSchema() => new() { ["type"] = "object", ["properties"] = new JsonObject { ["result"] = new JsonObject { ["type"] = "string" } }, ["required"] = new JsonArray("result"), ["additionalProperties"] = false };
    private static JsonObject StringArrayOutputSchema() => new() { ["type"] = "object", ["properties"] = new JsonObject { ["result"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } }, ["truncated"] = new JsonObject { ["type"] = "boolean" } }, ["required"] = new JsonArray("result", "truncated"), ["additionalProperties"] = false };
    private static JsonObject CodexConversationOutputSchema() => ObjectSchema(new[] { ("thread_id","string"),("title","string"),("repo_path","string"),("message_count","integer"),("turn_count","integer") });
    private static JsonObject ReadFileRangeOutputSchema() => ObjectSchema(new[] { ("path","string"),("start_line","integer"),("end_line","integer"),("requested_end_line","integer"),("total_lines","integer"),("has_before","boolean"),("has_after","boolean"),("truncated","boolean"),("content","string") });
    private static JsonObject SearchResultSchema(JsonObject specificProperties, params string[] specificRequired)
    {
        var props = specificProperties;
        props["include_ignored"] = new JsonObject { ["type"] = "boolean" };
        props["total"] = new JsonObject { ["type"] = "integer", ["description"] = "Results found before pagination; a lower bound when truncated by output_limit or timeout." };
        props["returned"] = new JsonObject { ["type"] = "integer" };
        props["offset"] = new JsonObject { ["type"] = "integer" };
        props["next_offset"] = new JsonObject { ["type"] = new JsonArray("integer", "null"), ["description"] = "Offset for the next page, or null when no results remain." };
        props["truncated"] = new JsonObject { ["type"] = "boolean" };
        props["truncation_reasons"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } };
        props["unsafe_paths_skipped"] = new JsonObject { ["type"] = "integer" };
        props["search_errors"] = new JsonObject { ["type"] = "integer" };
        props["default_excluded_directory_names"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } };
        var required = specificRequired.Concat([
            "include_ignored", "total", "returned", "offset", "next_offset", "truncated", "truncation_reasons",
            "unsafe_paths_skipped", "search_errors", "default_excluded_directory_names",
        ]);
        return new JsonObject { ["type"] = "object", ["properties"] = props, ["required"] = JsonStringArray(required), ["additionalProperties"] = false };
    }

    private static JsonObject GrepOutputSchema()
    {
        JsonObject ContextLineSchema() => ObjectSchema(new[] { ("line", "integer"), ("text", "string") });
        var match = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["path"] = new JsonObject { ["type"] = "string" },
                ["line"] = new JsonObject { ["type"] = "integer" },
                ["text"] = new JsonObject { ["type"] = "string" },
                ["before"] = new JsonObject { ["type"] = "array", ["items"] = ContextLineSchema() },
                ["after"] = new JsonObject { ["type"] = "array", ["items"] = ContextLineSchema() },
            },
            ["required"] = new JsonArray("path", "line", "text", "before", "after"),
            ["additionalProperties"] = false,
        };
        return SearchResultSchema(new JsonObject
        {
            ["pattern"] = new JsonObject { ["type"] = "string" },
            ["path"] = new JsonObject { ["type"] = "string" },
            ["output_mode"] = new JsonObject { ["type"] = "string" },
            ["files"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
            ["counts"] = new JsonObject { ["type"] = "array", ["items"] = ObjectSchema(new[] { ("path", "string"), ("count", "integer") }) },
            ["matches"] = new JsonObject { ["type"] = "array", ["items"] = match },
        }, "pattern", "path", "output_mode", "files", "counts", "matches");
    }

    private static JsonObject GlobOutputSchema() => SearchResultSchema(new JsonObject
    {
        ["pattern"] = new JsonObject { ["type"] = "string" },
        ["path"] = new JsonObject { ["type"] = "string" },
        ["files"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
    }, "pattern", "path", "files");

    private static JsonObject SearchCodeOutputSchema()
    {
        var match = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["path"] = new JsonObject { ["type"] = "string" },
                ["line"] = new JsonObject { ["type"] = "integer" },
                ["line_text"] = new JsonObject { ["type"] = "string" },
                ["score"] = new JsonObject { ["type"] = "integer", ["description"] = "Deterministic ranking score; not a confidence value." },
                ["signals"] = new JsonObject
                {
                    ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" },
                    ["description"] = "Transparent lexical signals that contributed to ordering.",
                },
            },
            ["required"] = new JsonArray("path", "line", "line_text", "score", "signals"),
            ["additionalProperties"] = false,
        };
        var queryResult = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["query"] = new JsonObject { ["type"] = "string" },
                ["observed_matching_lines"] = new JsonObject { ["type"] = "integer" },
                ["returned_matches"] = new JsonObject { ["type"] = "integer" },
                ["result_limit_reached"] = new JsonObject { ["type"] = "boolean" },
                ["matches"] = new JsonObject { ["type"] = "array", ["items"] = match },
            },
            ["required"] = new JsonArray("query", "observed_matching_lines", "returned_matches", "result_limit_reached", "matches"),
            ["additionalProperties"] = false,
        };
        var props = new JsonObject
        {
            ["path"] = new JsonObject { ["type"] = "string" },
            ["case_sensitive"] = new JsonObject { ["type"] = "boolean" },
            ["include_ignored"] = new JsonObject { ["type"] = "boolean" },
            ["query_results"] = new JsonObject { ["type"] = "array", ["items"] = queryResult },
            ["truncated"] = new JsonObject { ["type"] = "boolean" },
            ["truncation_reasons"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
            ["files_matched"] = new JsonObject { ["type"] = "integer" },
            ["files_ranked"] = new JsonObject { ["type"] = "integer" },
            ["unsafe_paths_skipped"] = new JsonObject { ["type"] = "integer" },
            ["search_errors"] = new JsonObject { ["type"] = "integer" },
            ["default_excluded_directory_names"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
        };
        return new JsonObject { ["type"] = "object", ["properties"] = props, ["required"] = new JsonArray(props.Select(p => JsonValue.Create(p.Key)).ToArray()), ["additionalProperties"] = false };
    }

    private static JsonObject RepoOverviewOutputSchema()
    {
        var extension = new JsonObject
        {
            ["type"] = "object",
            ["properties"] = new JsonObject
            {
                ["extension"] = new JsonObject { ["type"] = "string" },
                ["count"] = new JsonObject { ["type"] = "integer" },
            },
            ["required"] = new JsonArray("extension", "count"),
            ["additionalProperties"] = false,
        };
        var props = new JsonObject
        {
            ["path"] = new JsonObject { ["type"] = "string" },
            ["include_ignored"] = new JsonObject { ["type"] = "boolean" },
            ["top_level_entries"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
            ["top_level_truncated"] = new JsonObject { ["type"] = "boolean" },
            ["manifests"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
            ["manifest_results_limited"] = new JsonObject { ["type"] = "boolean" },
            ["file_extensions"] = new JsonObject { ["type"] = "array", ["items"] = extension },
            ["extension_counts_limited"] = new JsonObject { ["type"] = "boolean" },
            ["files_seen"] = new JsonObject { ["type"] = "integer" },
            ["directories_seen"] = new JsonObject { ["type"] = "integer" },
            ["truncated"] = new JsonObject { ["type"] = "boolean" },
            ["truncation_reasons"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
            ["unsafe_paths_skipped"] = new JsonObject { ["type"] = "integer" },
            ["search_errors"] = new JsonObject { ["type"] = "integer" },
            ["default_excluded_directory_names"] = new JsonObject { ["type"] = "array", ["items"] = new JsonObject { ["type"] = "string" } },
        };
        return new JsonObject { ["type"] = "object", ["properties"] = props, ["required"] = new JsonArray(props.Select(p => JsonValue.Create(p.Key)).ToArray()), ["additionalProperties"] = false };
    }
    private static JsonObject ObjectSchema(IEnumerable<(string Name, string Type)> fields) { var props = new JsonObject(); var required = new JsonArray(); foreach (var field in fields) { props[field.Name] = new JsonObject { ["type"] = field.Type }; required.Add(field.Name); } return new JsonObject { ["type"] = "object", ["properties"] = props, ["required"] = required, ["additionalProperties"] = false }; }

    private static string FormatProcessResult(ProcessResult result)
    {
        var sections = new List<string> { $"exit_code: {result.ExitCode}" };
        var stdout = result.Stdout.TrimEnd('\r', '\n'); var stderr = result.Stderr.TrimEnd('\r', '\n');
        if (stdout.Length > 0) sections.Add("stdout:\n" + stdout); if (stderr.Length > 0) sections.Add("stderr:\n" + stderr);
        if (stdout.Length == 0 && stderr.Length == 0) sections.Add("(no output)");
        return string.Join("\n\n", sections);
    }
}
