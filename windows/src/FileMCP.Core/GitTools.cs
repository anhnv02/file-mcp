using System.Collections;
using System.Text;

namespace FileMCP.Core;

internal sealed partial class LocalTools
{
    private async Task<string> GitInitAsync(string repoPath, CancellationToken cancellationToken)
    {
        var repo = _resolver.Resolve(repoPath);
        if (Directory.Exists(repo))
        {
            var contents = Directory.EnumerateFileSystemEntries(repo).Take(1).Any();
            if (contents)
            {
                if (EntryExists(Path.Combine(repo, ".git")))
                    return $"Already a git repository: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}";
                throw new FileMcpException($"Directory not empty, cannot init here: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}");
            }
        }
        else
        {
            Directory.CreateDirectory(repo);
        }

        var arguments = new List<string> { "init", "-b", "main" };
        if (!_enableCommands) arguments.Add("--template=");
        _ = await RunGitAsync(repo, arguments, cancellationToken: cancellationToken).ConfigureAwait(false);
        _ = await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false);
        return $"Initialized Git repository: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}";
    }

    private async Task<string> GitRepoAsync(string repoPath, CancellationToken cancellationToken)
    {
        var repo = _resolver.Resolve(repoPath);
        if (!Directory.Exists(repo)) throw new FileMcpException($"No such path: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}");
        var gitEntry = Path.Combine(repo, ".git");
        if (!EntryExists(gitEntry)) throw new FileMcpException($"Not a git repository: {(string.IsNullOrEmpty(repoPath) ? "." : repoPath)}");
        ValidateGitMetadataEntry(gitEntry, repo);
        await EnsureNoRepositoryConfigIncludesAsync(repo, cancellationToken).ConfigureAwait(false);

        var layout = await RunGitAsync(repo,
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--absolute-git-dir", "--git-common-dir", "--git-path", "objects"],
            FileMcpConstants.MaxGitSafetyOutputBytes, trimOutput: false, cancellationToken).ConfigureAwait(false);
        var paths = layout.Split(['\r', '\n'], StringSplitOptions.RemoveEmptyEntries);
        if (paths.Length != 4) throw new FileMcpException("Could not validate Git repository layout safely");

        var worktree = CanonicalForComparison(paths[0]);
        if (!PathEquals(worktree, repo)) throw new FileMcpException("Refused: Git worktree is outside or different from the requested repository path");
        foreach (var (label, path) in new[] { ("Git directory", paths[1]), ("Git common directory", paths[2]), ("Git object directory", paths[3]) })
        {
            if (!_resolver.Contains(path)) throw new FileMcpException($"Refused: {label} is outside the shared directory");
        }
        ValidateGitAlternates(paths[3]);
        return repo;
    }

    private void ValidateGitMetadataEntry(string gitEntry, string repo)
    {
        var attributes = _resolver.GetAttributesWithoutFollowingFinalTarget(gitEntry, "Not a git repository");
        var isDirectory = (attributes & FileAttributes.Directory) != 0;
        var isReparse = (attributes & FileAttributes.ReparsePoint) != 0;
        if (isDirectory)
        {
            if (!_resolver.Contains(gitEntry)) throw new FileMcpException("Refused: Git directory is outside the shared directory");
            ValidateGitConfigMetadata(gitEntry);
            return;
        }
        if (isReparse) throw new FileMcpException("Refused: .git must be a directory or a regular gitdir metadata file");
        var info = new FileInfo(gitEntry);
        if (info.Length > 64_000) throw new FileMcpException("Refused: .git metadata file is too large to validate safely");
        var text = File.ReadAllText(gitEntry, Encoding.UTF8).Trim();
        if (!text.StartsWith("gitdir:", StringComparison.OrdinalIgnoreCase)) throw new FileMcpException("Refused: unsupported .git metadata file");
        var pathText = text["gitdir:".Length..].Trim();
        if (pathText.Length == 0) throw new FileMcpException("Refused: invalid .git metadata file");
        var target = Path.IsPathRooted(pathText) ? pathText : Path.Combine(repo, pathText);
        if (!_resolver.Contains(target)) throw new FileMcpException("Refused: Git directory is outside the shared directory");
        ValidateGitConfigMetadata(target);
    }

    private void ValidateGitConfigMetadata(string gitDirectory)
    {
        if (!_resolver.Contains(gitDirectory)) throw new FileMcpException("Refused: Git directory is outside the shared directory");
        var commonDirectory = gitDirectory;
        var commonDirFile = Path.Combine(gitDirectory, "commondir");
        if (EntryExists(commonDirFile))
        {
            if (!_resolver.Contains(commonDirFile)) throw new FileMcpException("Refused: Git commondir metadata is outside the shared directory");
            var attrs = _resolver.GetAttributesWithoutFollowingFinalTarget(commonDirFile, "Missing Git commondir metadata");
            if ((attrs & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new FileMcpException("Refused: Git commondir metadata must be a regular file");
            if (new FileInfo(commonDirFile).Length > 64_000) throw new FileMcpException("Refused: Git commondir metadata is too large to validate safely");
            var pathText = File.ReadAllText(commonDirFile, Encoding.UTF8).Trim();
            if (pathText.Length == 0) throw new FileMcpException("Refused: Git commondir metadata is empty");
            commonDirectory = Path.IsPathRooted(pathText) ? pathText : Path.Combine(gitDirectory, pathText);
            if (!_resolver.Contains(commonDirectory)) throw new FileMcpException("Refused: Git common directory is outside the shared directory");
        }

        foreach (var configFile in new[] { Path.Combine(commonDirectory, "config"), Path.Combine(gitDirectory, "config.worktree") })
        {
            if (!EntryExists(configFile)) continue;
            if (!_resolver.Contains(configFile)) throw new FileMcpException("Refused: Git config metadata is outside the shared directory");
            var attrs = _resolver.GetAttributesWithoutFollowingFinalTarget(configFile, "Missing Git config metadata");
            if ((attrs & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new FileMcpException("Refused: Git config metadata must be a regular file");
        }
    }

    private async Task EnsureNoRepositoryConfigIncludesAsync(string repo, CancellationToken cancellationToken)
    {
        if (_enableCommands) return;
        var localConfig = await RunGitAsync(repo, ["config", "--local", "--no-includes", "--list"], FileMcpConstants.MaxGitSafetyOutputBytes, cancellationToken: cancellationToken).ConfigureAwait(false);
        EnsureCompleteGitSafetyOutput(localConfig, "Git config include scan");
        foreach (var line in SplitLines(localConfig))
        {
            var key = line.Split('=', 2)[0].ToLowerInvariant();
            if (key == "include.path" || (key.StartsWith("includeif.", StringComparison.Ordinal) && key.EndsWith(".path", StringComparison.Ordinal)))
                throw new FileMcpException("Git repository config includes are not allowed while command execution is disabled");
        }
    }

    private void ValidateGitAlternates(string objectDirectory)
    {
        var alternates = Path.Combine(objectDirectory, "info", "alternates");
        if (!EntryExists(alternates)) return;
        if (!_resolver.Contains(alternates)) throw new FileMcpException("Refused: Git alternates metadata is outside the shared directory");
        var attrs = _resolver.GetAttributesWithoutFollowingFinalTarget(alternates, "Missing Git alternates metadata");
        if ((attrs & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0) throw new FileMcpException("Refused: Git alternates metadata must be a regular file");
        if (new FileInfo(alternates).Length > 1_000_000) throw new FileMcpException("Refused: Git alternates file is too large to validate safely");
        foreach (var raw in File.ReadLines(alternates, Encoding.UTF8))
        {
            var line = raw.Trim(); if (line.Length == 0) continue;
            if (line.StartsWith('"')) throw new FileMcpException("Refused: quoted Git alternate object paths are not supported safely");
            var target = Path.IsPathRooted(line) ? line : Path.Combine(objectDirectory, line);
            if (!_resolver.Contains(target)) throw new FileMcpException("Refused: Git alternate object directory is outside the shared directory");
        }
    }

    private async Task<string> GitStatusAsync(string repoPath, CancellationToken cancellationToken)
    {
        var repo = await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false);
        var args = new List<string> { "status", "--short" }; if (!_enableCommands) args.Add("--ignore-submodules=all");
        var output = await RunGitAsync(repo, args, cancellationToken: cancellationToken).ConfigureAwait(false);
        return output.Length == 0 ? "(working tree clean)" : output;
    }

    private async Task<string> GitLogAsync(string repoPath, int count, CancellationToken cancellationToken) =>
        await RunGitAsync(await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false), ["log", "--oneline", "-n", Math.Clamp(count, 1, 50).ToString()], cancellationToken: cancellationToken).ConfigureAwait(false);

    private async Task<string> GitDiffAsync(string repoPath, string paths, CancellationToken cancellationToken)
    {
        var repo = await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false); var args = new List<string> { "diff" };
        if (!_enableCommands) args.AddRange(["--no-ext-diff", "--no-textconv", "--ignore-submodules=all"]);
        if (paths.Length > 0) { args.Add("--"); args.AddRange(GitPathspecs(paths, repo)); }
        return await RunGitAsync(repo, args, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task<string> GitAddAsync(string repoPath, string paths, CancellationToken cancellationToken)
    {
        var repo = await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false); var requested = paths.Length == 0 ? "." : paths; var pathspecs = GitPathspecs(requested, repo);
        await EnsureGitAddDoesNotRunFiltersAsync(repo, pathspecs, cancellationToken).ConfigureAwait(false);
        await RunGitAsync(repo, ["add", "--", .. pathspecs], cancellationToken: cancellationToken).ConfigureAwait(false);
        return $"Staged: {requested}";
    }

    private async Task<string> GitCommitAsync(string repoPath, string message, CancellationToken cancellationToken)
    {
        var args = new List<string>(); if (_gitUserName.Length > 0) args.AddRange(["-c", "user.name=" + _gitUserName]); if (_gitUserEmail.Length > 0) args.AddRange(["-c", "user.email=" + _gitUserEmail]);
        args.Add("commit"); if (!_enableCommands) args.Add("--no-gpg-sign"); args.AddRange(["-m", message]);
        return await RunGitAsync(await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false), args, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task<string> GitPushAsync(string repoPath, CancellationToken cancellationToken)
    {
        var repo = await GitRepoAsync(repoPath, cancellationToken).ConfigureAwait(false); await EnsureSafeGitPushConfigurationAsync(repo, cancellationToken).ConfigureAwait(false);
        var args = new List<string> { "push" }; if (!_enableCommands) args.AddRange(["--no-verify", "--no-signed", "--no-recurse-submodules", "--receive-pack=git-receive-pack"]);
        return await RunGitAsync(repo, args, cancellationToken: cancellationToken).ConfigureAwait(false);
    }

    private async Task<string> RunGitAsync(string repo, IReadOnlyList<string> arguments, int outputLimitBytes = FileMcpConstants.MaxToolProcessOutputBytes, bool trimOutput = true, CancellationToken cancellationToken = default)
    {
        await _gitSlots.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            var environment = SanitizedGitEnvironment(); environment["GIT_TERMINAL_PROMPT"] = "0";
            if (!_enableCommands) { environment["GIT_ASKPASS"] = ""; environment["SSH_ASKPASS"] = ""; environment["GIT_SSH_COMMAND"] = "ssh.exe -F none -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none"; environment["GIT_PAGER"] = "cat"; }
            var allArgs = new List<string> { "-C", repo, "--no-pager" }; allArgs.AddRange(SafeGitConfigurationArguments()); allArgs.AddRange(arguments);
            var result = await ProcessRunner.RunAsync("git.exe", allArgs, environment: environment, timeoutSeconds: 120, outputLimitBytes: outputLimitBytes, cancellationToken: cancellationToken).ConfigureAwait(false);
            if (result.TimedOut) throw new FileMcpException("git command timed out after 120 seconds");
            if (result.ExitCode != 0) throw new FileMcpException(string.IsNullOrWhiteSpace(result.Stderr) ? (result.Stdout.Length == 0 ? "git command failed" : result.Stdout) : result.Stderr.Trim());
            return trimOutput ? result.Stdout.Trim() : result.Stdout;
        }
        finally { _gitSlots.Release(); }
    }

    private Dictionary<string, string> SanitizedGitEnvironment()
    {
        var environment = Environment.GetEnvironmentVariables().Cast<DictionaryEntry>().ToDictionary(e => (string)e.Key, e => (string?)e.Value ?? "", StringComparer.OrdinalIgnoreCase);
        string[] exact = ["GIT_DIR","GIT_WORK_TREE","GIT_COMMON_DIR","GIT_OBJECT_DIRECTORY","GIT_ALTERNATE_OBJECT_DIRECTORIES","GIT_INDEX_FILE","GIT_GRAFT_FILE","GIT_SHALLOW_FILE","GIT_NAMESPACE","GIT_PREFIX","GIT_EXEC_PATH","GIT_CONFIG_PARAMETERS","GIT_CONFIG_COUNT","GIT_CEILING_DIRECTORIES","GIT_DISCOVERY_ACROSS_FILESYSTEM","GIT_EXTERNAL_DIFF"];
        foreach (var key in exact) environment.Remove(key);
        foreach (var key in environment.Keys.Where(key => key.StartsWith("GIT_CONFIG_KEY_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("GIT_CONFIG_VALUE_", StringComparison.OrdinalIgnoreCase) || key.StartsWith("GIT_TRACE", StringComparison.OrdinalIgnoreCase)).ToList()) environment.Remove(key);
        return environment;
    }

    private IReadOnlyList<string> SafeGitConfigurationArguments()
    {
        if (_enableCommands) return [];
        if (_safeGitEmptyFile is null || _safeGitHooksDirectory is null)
            throw new FileMcpException("Could not initialize Git safe-mode resources.");
        return
        [
            "-c", "core.hooksPath=" + _safeGitHooksDirectory,
            "-c", "core.fsmonitor=false",
            "-c", "core.attributesFile=" + _safeGitEmptyFile,
            "-c", "core.excludesFile=" + _safeGitEmptyFile,
            "-c", "core.askPass=",
            "-c", "core.sshCommand=ssh.exe -F none -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none",
            "-c", "credential.helper=",
            "-c", "protocol.allow=never",
            "-c", "protocol.file.allow=never",
            "-c", "protocol.http.allow=always",
            "-c", "protocol.https.allow=always",
            "-c", "protocol.ssh.allow=always",
        ];
    }

    private static (string EmptyFile, string HooksDirectory) PrepareSafeGitResources()
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
            throw new FileMcpException("Could not locate the user Local Application Data directory for Git safe mode.");

        var root = Path.Combine(localAppData, "FileMCP", "git-safe");
        Directory.CreateDirectory(root);
        EnsureOrdinaryDirectory(root, "Git safe-mode directory");

        var hooks = Path.Combine(root, "hooks");
        Directory.CreateDirectory(hooks);
        EnsureOrdinaryDirectory(hooks, "Git safe-mode hooks directory");
        foreach (var entry in Directory.EnumerateFileSystemEntries(hooks))
            throw new FileMcpException($"Git safe-mode hooks directory must be empty: {entry}");

        var empty = Path.Combine(root, "empty");
        if (File.Exists(empty) || Directory.Exists(empty))
        {
            var attributes = File.GetAttributes(empty);
            if ((attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                throw new FileMcpException("Git safe-mode empty file is not a regular file.");
        }
        using (var stream = new FileStream(empty, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
        }
        return (empty, hooks);
    }

    private static void EnsureOrdinaryDirectory(string path, string label)
    {
        var attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.Directory) == 0 || (attributes & FileAttributes.ReparsePoint) != 0)
            throw new FileMcpException($"{label} is not a regular directory.");
    }

    private async Task EnsureGitAddDoesNotRunFiltersAsync(string repo, IReadOnlyList<string> pathspecs, CancellationToken cancellationToken)
    {
        if (_enableCommands) return;
        var listed = await RunGitAsync(repo, ["ls-files","--cached","--others","--exclude-standard","-z","--", .. pathspecs], FileMcpConstants.MaxGitSafetyOutputBytes, false, cancellationToken).ConfigureAwait(false);
        EnsureCompleteGitSafetyOutput(listed, "git_add path scan"); var paths = listed.Split('\0', StringSplitOptions.RemoveEmptyEntries);
        await ValidateEmbeddedGitRepositoriesAsync(paths, repo, cancellationToken).ConfigureAwait(false);
        for (var index = 0; index < paths.Length; index += 128)
        {
            var batch = paths.Skip(index).Take(128).ToArray();
            var attrs = await RunGitAsync(repo, ["check-attr","-z","filter","--", .. batch], FileMcpConstants.MaxGitSafetyOutputBytes, false, cancellationToken).ConfigureAwait(false);
            EnsureCompleteGitSafetyOutput(attrs, "git_add attribute scan"); var fields = attrs.Split('\0', StringSplitOptions.RemoveEmptyEntries);
            if (fields.Length % 3 != 0) throw new FileMcpException("Could not validate Git content filters safely");
            for (var offset = 0; offset < fields.Length; offset += 3) if (fields[offset + 2] is not "unspecified" and not "unset") throw new FileMcpException($"git_add refused because {fields[offset]} uses Git content filter '{fields[offset + 2]}' while command execution is disabled");
        }
    }

    private async Task ValidateEmbeddedGitRepositoriesAsync(IEnumerable<string> paths, string repo, CancellationToken cancellationToken)
    {
        foreach (var raw in paths)
        {
            var relative = raw.TrimEnd('/', '\\'); if (relative.Length == 0) continue; var candidate = Path.GetFullPath(Path.Combine(repo, relative));
            if (!Directory.Exists(candidate) || !EntryExists(Path.Combine(candidate, ".git"))) continue;
            var rootRelative = _resolver.RelativePath(candidate); if (rootRelative.Length == 0) throw new FileMcpException("Could not validate embedded Git repository path safely");
            _ = await GitRepoAsync(rootRelative, cancellationToken).ConfigureAwait(false);
        }
    }

    private async Task EnsureSafeGitPushConfigurationAsync(string repo, CancellationToken cancellationToken)
    {
        if (_enableCommands) return;
        var config = await RunGitAsync(repo, ["config","--local","--includes","--list"], FileMcpConstants.MaxGitSafetyOutputBytes, cancellationToken: cancellationToken).ConfigureAwait(false);
        EnsureCompleteGitSafetyOutput(config, "git_push config scan");
        string[] unsafeSuffixes = ["cookiefile","sslcert","sslkey","sslcainfo","sslcapath","pinnedpubkey","proxysslcert","proxysslkey","proxysslcainfo"];
        foreach (var line in SplitLines(config))
        {
            var key = line.Split('=', 2)[0].ToLowerInvariant();
            if (key.StartsWith("credential.") && key.EndsWith(".helper")) throw new FileMcpException("git_push refused a repository-local credential helper while command execution is disabled");
            if (key.StartsWith("http.") && unsafeSuffixes.Any(suffix => key == "http." + suffix || key.EndsWith("." + suffix))) throw new FileMcpException($"git_push refused repository-controlled HTTP file setting '{key}' while command execution is disabled");
        }
    }

    private static void EnsureCompleteGitSafetyOutput(string value, string operation)
    {
        if (value.Contains("[...truncated ", StringComparison.Ordinal) && value.EndsWith(" bytes...]", StringComparison.Ordinal)) throw new FileMcpException($"{operation} exceeded the safety scan limit");
    }

    private IReadOnlyList<string> GitPathspecs(string value, string repo)
    {
        var trimmed = value.Trim(); if (trimmed.Length == 0) return [];
        var exact = Path.GetFullPath(Path.Combine(repo, trimmed));
        if (exact.StartsWith(Path.GetFullPath(repo).TrimEnd('\\') + "\\", StringComparison.OrdinalIgnoreCase) && EntryExists(exact)) return [trimmed];
        return ShellWords(trimmed);
    }

    private static IReadOnlyList<string> ShellWords(string value)
    {
        var words = new List<string>(); var current = new StringBuilder(); char? quote = null; var escaping = false; var started = false;
        foreach (var ch in value)
        {
            if (escaping) { current.Append(ch); escaping = false; started = true; continue; }
            if (ch == '\\' && quote != '\'') { escaping = true; started = true; continue; }
            if (quote.HasValue) { if (ch == quote.Value) quote = null; else current.Append(ch); started = true; continue; }
            if (ch is '\'' or '"') { quote = ch; started = true; continue; }
            if (char.IsWhiteSpace(ch)) { if (started) { words.Add(current.ToString()); current.Clear(); started = false; } continue; }
            current.Append(ch); started = true;
        }
        if (escaping) current.Append('\\');
        if (quote.HasValue) throw new FileMcpException("Unterminated quote in Git paths");
        if (started) words.Add(current.ToString());
        return words;
    }

    private static bool EntryExists(string path) { try { _ = File.GetAttributes(path); return true; } catch (FileNotFoundException) { return false; } catch (DirectoryNotFoundException) { return false; } }
    private static string CanonicalForComparison(string path) => Path.GetFullPath(path).TrimEnd('\\', '/');
    private static bool PathEquals(string lhs, string rhs) => string.Equals(CanonicalForComparison(lhs), CanonicalForComparison(rhs), StringComparison.OrdinalIgnoreCase);
    private static IEnumerable<string> SplitLines(string value) => value.Split(['\r','\n'], StringSplitOptions.RemoveEmptyEntries);
}
