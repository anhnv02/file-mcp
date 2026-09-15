using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json.Nodes;
using FileMCP.Core;

namespace FileMCP.Core.Tests;

internal static partial class Program
{
    private static int _assertions;

    private sealed class FakeCodexTurn
    {
        public required string Id { get; init; }
        public JsonArray Items { get; } = new();
        public long StartedAt { get; set; }
        public long CompletedAt { get; set; }
        public bool Completed { get; set; }
    }

    public static async Task<int> Main(string[] args)
    {
        if (args.Length > 0 && args[0] is "init" or "doctor" or "run")
            return await RunFakeTunnelClientAsync(args);
        if (args.Length > 0 && args[0] == "app-server" && Environment.GetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX") == "1")
            return await RunFakeCodexAppServerAsync();

        if (!OperatingSystem.IsWindows())
        {
            Console.WriteLine("windows-tests: skipped (Windows required)");
            return 0;
        }

        var root = Path.Combine(Path.GetTempPath(), "filemcp-windows-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        try
        {
            await TestSettingsAndCredentialsAsync(root);
            await TestProcessRunnerAsync(root);
            await TestFilesystemAndToolsAsync(root);
            await TestAgentToolsAsync(root);
            await TestCodexHistoryAsync(root);
            await TestGitSafetyAsync(root);
            await TestHttpAndMcpAsync(root);
            await TestRuntimeAsync(root);
            Console.WriteLine($"windows-core-tests: ok ({_assertions} assertions)");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            var annotation = ex.ToString()
                .Replace("%", "%25", StringComparison.Ordinal)
                .Replace("\r", "%0D", StringComparison.Ordinal)
                .Replace("\n", "%0A", StringComparison.Ordinal);
            Console.Error.WriteLine($"::error file=windows/tests/FileMCP.Core.Tests/Program.cs,title=Windows integration failure::{annotation}");
            return 1;
        }
        finally
        {
            try { Directory.Delete(root, true); } catch { }
        }
    }

    private static Task TestSettingsAndCredentialsAsync(string root)
    {
        var settingsDir = Path.Combine(root, "settings");
        var store = new SettingsStore(settingsDir);
        var settings = new FileMcpSettings
        {
            TunnelId = "tunnel_" + new string('a', 32), Profile = "windows-test", Port = 18080,
            AllowedDirectory = Path.Combine(root, "workspace"), HealthAddress = "127.0.0.1:0",
            GitUserName = "FileMCP Test", GitUserEmail = "filemcp@example.invalid", EnableCommands = true,
        };
        store.Save(settings); var loaded = store.Load();
        Assert(loaded.TunnelId == settings.TunnelId && loaded.Profile == settings.Profile && loaded.EnableCommands, "settings roundtrip");
        Assert(!File.ReadAllText(Path.Combine(settingsDir, "settings.json")).Contains("apiKey", StringComparison.OrdinalIgnoreCase), "settings contain no API key");

        var target = "FileMCP/tests/" + Guid.NewGuid().ToString("N");
        var credentials = new WindowsCredentialStore(target);
        try
        {
            credentials.SaveApiKey("sk-test-filemcp");
            Assert(credentials.HasSavedApiKey, "credential exists");
            Assert(credentials.ReadApiKey() == "sk-test-filemcp", "credential roundtrip");
            credentials.DeleteApiKey();
            Assert(!credentials.HasSavedApiKey, "credential delete");
        }
        finally { try { credentials.DeleteApiKey(); } catch { } }
        Console.WriteLine("windows-settings-credentials: ok");
        return Task.CompletedTask;
    }

    private static async Task TestProcessRunnerAsync(string root)
    {
        var timeout = await ProcessRunner.RunAsync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "Start-Sleep -Seconds 10"], timeoutSeconds: 1);
        Assert(timeout.TimedOut, "process timeout");

        var bounded = await ProcessRunner.RunAsync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", "'x' * 150000"], timeoutSeconds: 5, outputLimitBytes: 10_000);
        Assert(bounded.Stdout.Contains("[...truncated ", StringComparison.Ordinal), "bounded process output");

        var pidFile = Path.Combine(root, "child.pid");
        var escaped = pidFile.Replace("'", "''", StringComparison.Ordinal);
        var script = "$p=Start-Process powershell.exe -ArgumentList '-NoLogo','-NoProfile','-NonInteractive','-Command','Start-Sleep -Seconds 20' -PassThru; Set-Content -LiteralPath '" + escaped + "' -Value $p.Id";
        var parent = await ProcessRunner.RunAsync("powershell.exe", ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", script], timeoutSeconds: 5);
        Assert(parent.ExitCode == 0 && File.Exists(pidFile), "descendant fixture");
        await Task.Delay(500);
        var childPid = int.Parse(File.ReadAllText(pidFile).Trim());
        var childAlive = false;
        try { using var child = Process.GetProcessById(childPid); childAlive = !child.HasExited; } catch (ArgumentException) { }
        Assert(!childAlive, "job object descendant cleanup");
        Console.WriteLine("windows-process-runner: ok");
    }

    private static async Task TestFilesystemAndToolsAsync(string root)
    {
        var workspace = Path.Combine(root, "files"); Directory.CreateDirectory(workspace);
        var safe = new LocalTools(workspace, "FileMCP Test", "filemcp@example.invalid", false);
        var full = new LocalTools(workspace, "FileMCP Test", "filemcp@example.invalid", true);
        Assert(safe.ToolDefinitions.Count == 22 && safe.HasTool("save_conversation_to_codex") && safe.HasTool("search_code") && safe.HasTool("repo_overview") && safe.HasTool("batch_read") && !safe.HasTool("run_command"), "safe tool count");
        Assert(full.ToolDefinitions.Count == 26 && full.HasTool("save_conversation_to_codex") && full.HasTool("search_code") && full.HasTool("repo_overview") && full.HasTool("batch_read") && full.HasTool("run_command"), "full tool count");

        await safe.CallAsync("write_file", Obj(("relative_path", "docs/note.txt"), ("content", "alpha\nbeta\ngamma\n")));
        var read = await safe.CallAsync("read_file", Obj(("relative_path", "docs/note.txt")));
        Assert(read.StructuredContent["result"]!.GetValue<string>().Contains("beta"), "read file");
        File.WriteAllText(Path.Combine(workspace, "long-read.txt"), new string('x', 80_001));
        var longRead = await safe.CallAsync("read_file", Obj(("relative_path", "long-read.txt")));
        Assert(longRead.StructuredContent["result"]!.GetValue<string>().EndsWith("[...truncated...]", StringComparison.Ordinal), "read file response truncation");
        var range = await safe.CallAsync("read_file_range", Obj(("relative_path", "docs/note.txt"), ("start_line", 2), ("end_line", 3)));
        Assert(range.StructuredContent["content"]!.GetValue<string>() == "beta\ngamma", "read range");
        var search = await safe.CallAsync("grep", Obj(("pattern", "beta"), ("path", "docs"), ("output_mode", "content"), ("context", 1)));
        var searchMatch = search.StructuredContent["matches"]!.AsArray().Single()!;
        Assert(searchMatch["path"]!.GetValue<string>() == "docs/note.txt" && searchMatch["line"]!.GetValue<int>() == 2, "grep content");
        Assert(searchMatch["before"]!.AsArray().Single()!["text"]!.GetValue<string>() == "alpha" && searchMatch["after"]!.AsArray().Single()!["line"]!.GetValue<int>() == 3, "grep content context");
        Assert(search.StructuredContent["truncation_reasons"]!.AsArray().Count == 0 && search.StructuredContent["next_offset"] is null, "grep complete metadata");
        Assert(search.StructuredContent["default_excluded_directory_names"]!.AsArray().Any(value => value!.GetValue<string>() == "node_modules"), "grep exclusion metadata");
        var binaryDirectory = Path.Combine(workspace, "binary-only"); Directory.CreateDirectory(binaryDirectory);
        var binaryBytes = Enumerable.Repeat((byte)65, 1024).ToArray(); binaryBytes[0] = 0; File.WriteAllBytes(Path.Combine(binaryDirectory, "blob.bin"), binaryBytes);
        var binarySearch = await safe.CallAsync("grep", Obj(("pattern", "A"), ("path", "binary-only")));
        Assert(binarySearch.StructuredContent["total"]!.GetValue<int>() == 0, "grep skips binary files");
        var names = await safe.CallAsync("glob", Obj(("pattern", "note*")));
        Assert(names.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "docs/note.txt", "glob file name");
        Directory.CreateDirectory(Path.Combine(workspace, "scope-a"));
        Directory.CreateDirectory(Path.Combine(workspace, "scope-b"));
        File.WriteAllText(Path.Combine(workspace, "scope-a", "scoped-target.txt"), "a");
        File.WriteAllText(Path.Combine(workspace, "scope-b", "scoped-target.txt"), "b");
        Directory.CreateDirectory(Path.Combine(workspace, ".next"));
        File.WriteAllText(Path.Combine(workspace, ".next", "generated-target.txt"), "generated");
        var scopedNames = await safe.CallAsync("glob", Obj(("pattern", "scoped-target*"), ("path", "scope-a")));
        Assert(scopedNames.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "scope-a/scoped-target.txt", "scoped glob");
        var broadGenerated = await safe.CallAsync("glob", Obj(("pattern", "generated-target.txt")));
        Assert(broadGenerated.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == ".next/generated-target.txt", "broad glob preserves hidden generated-directory coverage");
        var explicitGenerated = await safe.CallAsync("glob", Obj(("pattern", "*"), ("path", ".next")));
        Assert(explicitGenerated.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == ".next/generated-target.txt", "explicit generated-directory glob");
        var broadGeneratedContent = await safe.CallAsync("grep", Obj(("pattern", "generated"), ("output_mode", "content")));
        Assert(broadGeneratedContent.StructuredContent["matches"]!.AsArray().Single()!["path"]!.GetValue<string>() == ".next/generated-target.txt", "broad grep preserves generated-directory coverage");
        var explicitGeneratedContent = await safe.CallAsync("grep", Obj(("pattern", "generated"), ("path", ".next")));
        Assert(explicitGeneratedContent.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == ".next/generated-target.txt", "explicit generated-directory grep");

        var ignoredProject = Path.Combine(workspace, "ignored-project");
        Directory.CreateDirectory(Path.Combine(ignoredProject, "generated"));
        Directory.CreateDirectory(Path.Combine(ignoredProject, "src"));
        Directory.CreateDirectory(Path.Combine(ignoredProject, ".git"));
        Directory.CreateDirectory(Path.Combine(ignoredProject, "generated", "EmptyGenerated.xcodeproj"));
        Directory.CreateDirectory(Path.Combine(ignoredProject, "dotignored", "EmptyIgnored.xcworkspace"));
        File.WriteAllText(Path.Combine(ignoredProject, ".gitignore"), "generated/\n");
        File.WriteAllText(Path.Combine(ignoredProject, ".ignore"), "dotignored/\n");
        File.WriteAllText(Path.Combine(ignoredProject, "generated", "output.txt"), "ignore-probe\n");
        File.WriteAllText(Path.Combine(ignoredProject, "src", "kept.txt"), "ignore-probe\n");
        File.WriteAllText(Path.Combine(ignoredProject, ".git", "probe.txt"), "ignore-probe\n");
        var ignoredDefault = await safe.CallAsync("grep", Obj(("pattern", "ignore-probe"), ("path", "ignored-project")));
        Assert(ignoredDefault.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "ignored-project/src/kept.txt", "grep respects gitignore");
        var ignoredIncluded = await safe.CallAsync("grep", Obj(("pattern", "ignore-probe"), ("path", "ignored-project"), ("include_ignored", true)));
        var ignoredIncludedFiles = ignoredIncluded.StructuredContent["files"]!.AsArray().Select(value => value!.GetValue<string>()).ToList();
        Assert(ignoredIncludedFiles.Count == 2 && ignoredIncludedFiles.Contains("ignored-project/generated/output.txt") && !ignoredIncludedFiles.Any(value => value.Contains(".git/", StringComparison.Ordinal)), "grep include_ignored keeps .git excluded");
        var ignoredGlob = await safe.CallAsync("glob", Obj(("pattern", "*.txt"), ("path", "ignored-project")));
        Assert(ignoredGlob.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "ignored-project/src/kept.txt", "glob respects gitignore");
        var ignoredDefaultOverview = await safe.CallAsync("repo_overview", Obj(("path", "ignored-project")));
        Assert(ignoredDefaultOverview.StructuredContent["files_seen"]!.GetValue<int>() == 3, "repo overview default ignored file coverage");
        Assert(ignoredDefaultOverview.StructuredContent["directories_seen"]!.GetValue<int>() == 1, "repo overview excludes gitignored and dot-ignore empty directories");
        Assert(!ignoredDefaultOverview.StructuredContent["manifests"]!.AsArray().Any(value =>
            value!.GetValue<string>().Contains("EmptyGenerated.xcodeproj", StringComparison.Ordinal) ||
            value!.GetValue<string>().Contains("EmptyIgnored.xcworkspace", StringComparison.Ordinal)),
            "repo overview excludes ignored empty manifests");
        var ignoredOverview = await safe.CallAsync("repo_overview", Obj(("path", "ignored-project"), ("include_ignored", true)));
        Assert(ignoredOverview.StructuredContent["files_seen"]!.GetValue<int>() == 4, "repo overview include_ignored file coverage");
        Assert(ignoredOverview.StructuredContent["directories_seen"]!.GetValue<int>() == 5, "repo overview include_ignored directory coverage");
        Assert(ignoredOverview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>().EndsWith("EmptyGenerated.xcodeproj", StringComparison.Ordinal)), "repo overview include_ignored gitignored empty manifest");
        Assert(ignoredOverview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>().EndsWith("EmptyIgnored.xcworkspace", StringComparison.Ordinal)), "repo overview include_ignored dot-ignore empty manifest");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "ignore-probe"), ("path", "ignored-project/.git"))), ".git is always excluded from search", "grep rejects explicit .git root");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "ignore-probe"), ("path", "ignored-project/.git/probe.txt"), ("include_ignored", true))), ".git is always excluded from search", "grep rejects explicit file inside .git");
        await AssertThrowsAsync(() => safe.CallAsync("glob", Obj(("pattern", "*"), ("path", "ignored-project/.git"), ("include_ignored", true))), ".git is always excluded from search", "glob rejects explicit .git root");
        await AssertThrowsAsync(() => safe.CallAsync("search_code", Obj(("queries", new JsonArray("ignore-probe")), ("path", "ignored-project/.git"), ("include_ignored", true))), ".git is always excluded from search", "search_code rejects explicit .git root");
        await AssertThrowsAsync(() => safe.CallAsync("repo_overview", Obj(("path", "ignored-project/.git"), ("include_ignored", true))), ".git is always excluded from search", "repo_overview rejects explicit .git root");

        var grepFixture = Path.Combine(workspace, "grep-fixture"); Directory.CreateDirectory(grepFixture);
        File.WriteAllText(Path.Combine(grepFixture, "alpha.swift"), "let grepAlpha = 1\nlet grepAlpha2 = 2\nfunc grepBeta() {\n    grepAlpha\n}\n");
        File.WriteAllText(Path.Combine(grepFixture, "beta.ts"), "const GREPALPHA = 3;\r\nconst grepBeta = { start:\r\n  end };\r\n");
        var grepRegex = await safe.CallAsync("grep", Obj(("pattern", "grepAlpha\\b"), ("path", "grep-fixture"), ("output_mode", "content"), ("context", 1)));
        var regexMatches = grepRegex.StructuredContent["matches"]!.AsArray();
        Assert(regexMatches.Count == 2 && regexMatches[0]!["line"]!.GetValue<int>() == 1 && regexMatches[1]!["line"]!.GetValue<int>() == 4, "grep regex word boundary");
        Assert(regexMatches[0]!["after"]!.AsArray().Single()!["text"]!.GetValue<string>() == "let grepAlpha2 = 2" && regexMatches[1]!["before"]!.AsArray().Single()!["line"]!.GetValue<int>() == 3, "grep context lines");
        var grepCount = await safe.CallAsync("grep", Obj(("pattern", "grepalpha"), ("fixed_strings", true), ("case_insensitive", true), ("path", "grep-fixture"), ("output_mode", "count")));
        var counts = grepCount.StructuredContent["counts"]!.AsArray();
        Assert(counts.Count == 2 && counts[0]!["path"]!.GetValue<string>() == "grep-fixture/alpha.swift" && counts[0]!["count"]!.GetValue<int>() == 3 && counts[1]!["count"]!.GetValue<int>() == 1, "grep count mode");
        var grepType = await safe.CallAsync("grep", Obj(("pattern", "grepBeta"), ("path", "grep-fixture"), ("type", "ts")));
        Assert(grepType.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "grep-fixture/beta.ts", "grep type filter");
        var grepGlob = await safe.CallAsync("grep", Obj(("pattern", "grepBeta"), ("path", "grep-fixture"), ("glob", "*.swift")));
        Assert(grepGlob.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "grep-fixture/alpha.swift", "grep glob filter");
        var grepFilePath = await safe.CallAsync("grep", Obj(("pattern", "grepBeta"), ("path", "grep-fixture/beta.ts"), ("output_mode", "content")));
        Assert(grepFilePath.StructuredContent["matches"]!.AsArray().Single()!["text"]!.GetValue<string>() == "const grepBeta = { start:", "grep single file path strips CRLF");
        var grepMultiline = await safe.CallAsync("grep", Obj(("pattern", "start:.*end"), ("path", "grep-fixture"), ("multiline", true), ("output_mode", "content")));
        Assert(grepMultiline.StructuredContent["matches"]!.AsArray().Count == 2 && grepMultiline.StructuredContent["matches"]!.AsArray()[1]!["text"]!.GetValue<string>() == "  end };", "grep multiline");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "x"), ("type", "not a type"))), "type must be a ripgrep file type name", "grep validates type names");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "x"), ("type", "definitelynotatype"))), "definitelynotatype", "grep reports unknown types");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "(unclosed"))), "regex parse error", "grep reports regex errors");
        await AssertThrowsAsync(() => safe.CallAsync("grep", Obj(("pattern", "x"), ("output_mode", "lines"))), "must be one of", "grep validates output_mode");
        var optionPattern = await safe.CallAsync("grep", Obj(("pattern", "--pre=cmd.exe"), ("path", "grep-fixture")));
        Assert(optionPattern.StructuredContent["total"]!.GetValue<int>() == 0, "grep treats option-like pattern as data");
        var optionGlob = await safe.CallAsync("glob", Obj(("pattern", "--pre=cmd.exe"), ("path", "grep-fixture")));
        Assert(optionGlob.StructuredContent["total"]!.GetValue<int>() == 0, "glob treats option-like pattern as data");
        var caseGlob = Path.Combine(workspace, "case-glob"); Directory.CreateDirectory(caseGlob);
        File.WriteAllText(Path.Combine(caseGlob, "ReadMe.MD"), "case-probe\n");
        var caseGlobResult = await safe.CallAsync("glob", Obj(("pattern", "*readme*"), ("path", "case-glob")));
        Assert(caseGlobResult.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "case-glob/ReadMe.MD", "glob is case-insensitive");
        var caseGrepGlob = await safe.CallAsync("grep", Obj(("pattern", "case-probe"), ("path", "case-glob"), ("glob", "*.md")));
        Assert(caseGrepGlob.StructuredContent["total"]!.GetValue<int>() == 1, "grep glob filter is case-insensitive");
        var largeListing = Path.Combine(workspace, "large-listing"); Directory.CreateDirectory(largeListing);
        File.WriteAllBytes(Path.Combine(largeListing, "large.txt"), Enumerable.Repeat((byte)'x', 1_000_001).ToArray());
        var largeGlob = await safe.CallAsync("glob", Obj(("pattern", "*.txt"), ("path", "large-listing")));
        Assert(largeGlob.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "large-listing/large.txt", "glob lists files larger than the grep size limit");
        var largeOverview = await safe.CallAsync("repo_overview", Obj(("path", "large-listing")));
        Assert(largeOverview.StructuredContent["files_seen"]!.GetValue<int>() == 1, "repo overview counts files larger than the grep size limit");
        var globOrder = Path.Combine(workspace, "glob-order"); Directory.CreateDirectory(globOrder);
        foreach (var (name, year) in new[] { ("older.swift", 2020), ("newer.swift", 2024), ("middle.swift", 2022) })
        {
            var orderFile = Path.Combine(globOrder, name);
            File.WriteAllText(orderFile, "order\n");
            File.SetLastWriteTimeUtc(orderFile, new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Utc));
        }
        var orderedGlob = await safe.CallAsync("glob", Obj(("pattern", "*.swift"), ("path", "glob-order"), ("head_limit", 2)));
        var orderedFiles = orderedGlob.StructuredContent["files"]!.AsArray().Select(value => value!.GetValue<string>()).ToList();
        Assert(orderedFiles.SequenceEqual(["glob-order/newer.swift", "glob-order/middle.swift"]) && orderedGlob.StructuredContent["next_offset"]!.GetValue<int>() == 2, "glob newest-first pagination");

        var rankedSearch = Path.Combine(workspace, "ranked-search"); Directory.CreateDirectory(rankedSearch);
        for (var index = 1; index <= 30; index++)
            File.WriteAllText(Path.Combine(rankedSearch, $"usage-{index:00}.cs"), $"var usage_{index} = new QualityTarget();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "definition.cs"), "public sealed class QualityTarget {}\n");
        File.WriteAllText(Path.Combine(rankedSearch, "typed.cs"), "var call = TypedTarget();\nprivate JsonObject TypedTarget() => new();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "typed-value.cs"), "var used = TypedValueTarget;\nprivate static int TypedValueTarget = 1;\n");
        File.WriteAllText(Path.Combine(rankedSearch, "generic-method.cs"), "var call = GenericTarget<int>(1);\nprivate TResult GenericTarget<TArg>(TArg value) => default!;\n");
        File.WriteAllText(Path.Combine(rankedSearch, "python-comment.py"), "value = 1# class PythonCommentTarget: pass\n");
        File.WriteAllText(Path.Combine(rankedSearch, "go-raw.go"), "var raw = `\ntype GoRawStringTarget struct{}\n`\n");
        File.WriteAllText(Path.Combine(rankedSearch, "shell-comment.sh"), "echo ok # class ShellCommentTarget {}\n");
        File.WriteAllText(Path.Combine(rankedSearch, "powershell-comment.ps1"), "<#\nclass PowerShellBlockTarget {}\n#>\n#class PowerShellLineTarget {}\n");
        File.WriteAllText(Path.Combine(rankedSearch, "case-exact.cs"), "var exact = CaseTarget();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "case-lower.cs"), "var lower = casetarget();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "FilenameOnlyTarget.cs"), "var reference = FilenameOnlyTarget();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "prefix-FilenameMatchTarget-suffix.cs"), "var reference = FilenameMatchTarget();\n");
        File.WriteAllText(Path.Combine(rankedSearch, "ambiguous-type-usage.cpp"), "const AmbiguousTypeUsage& value = source;\n");
        File.WriteAllText(Path.Combine(rankedSearch, "ambiguous-type-definition.hpp"), "class AmbiguousTypeUsage {};\n");
        File.WriteAllText(Path.Combine(rankedSearch, "constant.js"), "const ConstantTarget = 1;\n");
        File.WriteAllText(Path.Combine(rankedSearch, "static.rs"), "static RustStaticTarget: i32 = 1;\n");
        File.WriteAllText(Path.Combine(rankedSearch, "string-fixture.cs"), "var fixture = \"public class StringOnlyTarget {}\";\n");
        File.WriteAllText(Path.Combine(rankedSearch, "lexical-state.cs"), "/*\npublic class BlockCommentTarget {}\n/* nested-looking */\npublic class CSharpAfterCommentTarget {}\nvar raw = \"\"\"\npublic class MultilineStringTarget {}\n\"\"\";\n");
        File.WriteAllText(Path.Combine(rankedSearch, "lexical-nested.swift"), "/*\n/* nested */\nfinal class NestedBlockCommentTarget {}\n*/\nprivate func `EscapedTarget`() {}\n");
        File.WriteAllText(Path.Combine(rankedSearch, "lexical-template.ts"), "const raw = `\nclass TemplateStringTarget {}\n`;\n");
        var limitedContent = await safe.CallAsync("grep", Obj(("pattern", "QualityTarget"), ("path", "ranked-search"), ("head_limit", 1)));
        Assert(limitedContent.StructuredContent["truncated"]!.GetValue<bool>() && limitedContent.StructuredContent["truncation_reasons"]!.AsArray().Any(value => value!.GetValue<string>() == "head_limit"), "grep head_limit truncation reason");
        Assert(limitedContent.StructuredContent["total"]!.GetValue<int>() == 31 && limitedContent.StructuredContent["next_offset"]!.GetValue<int>() == 1, "grep pagination metadata");
        var secondPage = await safe.CallAsync("grep", Obj(("pattern", "QualityTarget"), ("path", "ranked-search"), ("head_limit", 30), ("offset", 1)));
        Assert(secondPage.StructuredContent["returned"]!.GetValue<int>() == 30 && secondPage.StructuredContent["next_offset"] is null, "grep second page");

        var rankedCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("QualityTarget", "class QualityTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        var rankedQueries = rankedCode.StructuredContent["query_results"]!.AsArray();
        Assert(!rankedCode.StructuredContent["truncated"]!.GetValue<bool>() && rankedCode.StructuredContent["files_matched"]!.GetValue<int>() == 31 && rankedCode.StructuredContent["files_ranked"]!.GetValue<int>() == 31, "ranked code single-pass coverage");
        Assert(rankedQueries[0]!["observed_matching_lines"]!.GetValue<int>() == 31 && rankedQueries[0]!["returned_matches"]!.GetValue<int>() == 1 && rankedQueries[0]!["result_limit_reached"]!.GetValue<bool>(), "ranked code top-N metadata");
        Assert(rankedQueries[0]!["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == "ranked-search/definition.cs", "ranked code prioritizes declaration");
        Assert(rankedQueries[0]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code declaration signal");
        Assert(rankedQueries[1]!["observed_matching_lines"]!.GetValue<int>() == 1 && rankedQueries[1]!["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == "ranked-search/definition.cs", "ranked code multi-query");
        var typedCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("TypedTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        var typedMatch = typedCode.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!;
        Assert(typedMatch["path"]!.GetValue<string>() == "ranked-search/typed.cs" && typedMatch["line"]!.GetValue<int>() == 2, "ranked code prioritizes typed method declaration");
        Assert(typedMatch["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code typed method declaration signal");
        var typedValueCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("TypedValueTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        var typedValueMatch = typedValueCode.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!;
        Assert(typedValueMatch["path"]!.GetValue<string>() == "ranked-search/typed-value.cs" && typedValueMatch["line"]!.GetValue<int>() == 2, "ranked code prioritizes typed value declaration");
        Assert(typedValueMatch["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code typed value declaration signal");
        var genericCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("GenericTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        var genericMatch = genericCode.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!;
        Assert(genericMatch["path"]!.GetValue<string>() == "ranked-search/generic-method.cs" && genericMatch["line"]!.GetValue<int>() == 2, "ranked code prioritizes generic typed method declaration");
        Assert(genericMatch["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code generic method declaration signal");
        var caseInsensitiveCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("CaseTarget")), ("path", "ranked-search"), ("max_results_per_query", 2)));
        var caseInsensitiveQuery = caseInsensitiveCode.StructuredContent["query_results"]!.AsArray()[0]!;
        Assert(caseInsensitiveQuery["observed_matching_lines"]!.GetValue<int>() == 2 && caseInsensitiveQuery["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == "ranked-search/case-exact.cs", "ranked code case-insensitive exact-case ordering");
        Assert(caseInsensitiveQuery["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "exact_case"), "ranked code exact-case signal");
        var caseSensitiveCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("CaseTarget")), ("path", "ranked-search"), ("case_sensitive", true), ("max_results_per_query", 2)));
        Assert(caseSensitiveCode.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 1, "ranked code case-sensitive matching");
        var filenameSignals = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("FilenameOnlyTarget", "FilenameMatchTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        Assert(filenameSignals.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "filename_exact"), "ranked code exact filename signal");
        Assert(filenameSignals.StructuredContent["query_results"]!.AsArray()[1]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "filename_match"), "ranked code partial filename signal");
        var ambiguousDeclarations = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("AmbiguousTypeUsage", "ConstantTarget", "RustStaticTarget")), ("path", "ranked-search"), ("max_results_per_query", 2)));
        var ambiguousQueries = ambiguousDeclarations.StructuredContent["query_results"]!.AsArray();
        Assert(ambiguousQueries[0]!["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == "ranked-search/ambiguous-type-definition.hpp", "ranked code does not boost const type usage");
        Assert(!ambiguousQueries[0]!["matches"]!.AsArray()[1]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code const type usage has no declaration signal");
        Assert(ambiguousQueries[1]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code still recognizes const value declaration");
        Assert(ambiguousQueries[2]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code recognizes Rust static value declaration");
        var languageLexicalCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("PythonCommentTarget", "GoRawStringTarget", "ShellCommentTarget", "PowerShellBlockTarget", "PowerShellLineTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        Assert(languageLexicalCode.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores Python hash comments without whitespace");
        Assert(languageLexicalCode.StructuredContent["query_results"]!.AsArray()[1]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores Go raw strings");
        Assert(languageLexicalCode.StructuredContent["query_results"]!.AsArray()[2]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores shell hash comments");
        Assert(languageLexicalCode.StructuredContent["query_results"]!.AsArray()[3]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores PowerShell block comments");
        Assert(languageLexicalCode.StructuredContent["query_results"]!.AsArray()[4]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores PowerShell line comments");
        var stringFixture = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("StringOnlyTarget")), ("path", "ranked-search"), ("max_results_per_query", 2)));
        Assert(stringFixture.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores declaration keywords inside strings");
        var lexicalStateCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("BlockCommentTarget", "CSharpAfterCommentTarget", "NestedBlockCommentTarget", "MultilineStringTarget", "EscapedTarget", "TemplateStringTarget")), ("path", "ranked-search"), ("max_results_per_query", 2)));
        var lexicalStateQueries = lexicalStateCode.StructuredContent["query_results"]!.AsArray();
        Assert(lexicalStateQueries[0]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores declarations inside block comments");
        Assert(lexicalStateQueries[1]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code preserves non-nested C# block-comment semantics");
        Assert(lexicalStateQueries[2]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code honors nested Swift block comments");
        Assert(lexicalStateQueries[3]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores declarations inside multiline strings");
        Assert(lexicalStateQueries[4]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Any(value => value!.GetValue<string>() == "likely_declaration"), "ranked code preserves Swift escaped identifiers");
        Assert(lexicalStateQueries[5]!["matches"]!.AsArray()[0]!["signals"]!.AsArray().Count == 0, "ranked code ignores declarations inside TypeScript template strings");
        var rankedGenerated = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("generated")), ("max_results_per_query", 1)));
        Assert(rankedGenerated.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == ".next/generated-target.txt", "ranked code preserves generated-directory coverage");
        await AssertThrowsAsync(() => safe.CallAsync("search_code", Obj(("queries", new JsonArray(JsonValue.Create(123))))), "queries[0] must be a string", "ranked code validates query types");
        var sixQueries = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("QualityTarget", "TypedTarget", "TypedValueTarget", "GenericTarget", "CaseTarget", "FilenameOnlyTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)));
        Assert(sixQueries.StructuredContent["query_results"]!.AsArray().Count == 6, "ranked code accepts six queries");
        await AssertThrowsAsync(() => safe.CallAsync("search_code", Obj(("queries", new JsonArray("a", "b", "c", "d", "e", "f", "g")))), "at most 6", "ranked code rejects seven queries");
        _ = await safe.CallAsync("search_code", Obj(("queries", new JsonArray(new string('x', 500))), ("path", "ranked-search")));
        await AssertThrowsAsync(() => safe.CallAsync("search_code", Obj(("queries", new JsonArray(new string('x', 501))), ("path", "ranked-search"))), "longer than 500 characters", "ranked code query length limit");

        var overviewProject = Path.Combine(workspace, "overview-project");
        Directory.CreateDirectory(Path.Combine(overviewProject, "src"));
        Directory.CreateDirectory(Path.Combine(overviewProject, "tests"));
        Directory.CreateDirectory(Path.Combine(overviewProject, "node_modules", "ignored"));
        File.WriteAllText(Path.Combine(overviewProject, "package.json"), "{}");
        File.WriteAllText(Path.Combine(overviewProject, "src", "main.ts"), "export const main = 1;\n");
        File.WriteAllText(Path.Combine(overviewProject, "tests", "main.test.ts"), "export const test = 1;\n");
        File.WriteAllText(Path.Combine(overviewProject, "node_modules", "ignored", "hidden.ts"), "hidden\n");
        File.WriteAllText(Path.Combine(overviewProject, "node_modules", "ignored", "package.json"), "{}");
        Directory.CreateDirectory(Path.Combine(overviewProject, "Demo.xcodeproj"));
        File.WriteAllText(Path.Combine(overviewProject, "Demo.xcodeproj", "project.pbxproj"), "project-marker\n");
        Directory.CreateDirectory(Path.Combine(overviewProject, "empty-dir"));
        Directory.CreateDirectory(Path.Combine(overviewProject, "EmptyProject.xcodeproj"));
        Directory.CreateDirectory(Path.Combine(overviewProject, "EmptyWorkspace.xcworkspace"));
        var overview = await safe.CallAsync("repo_overview", Obj(("path", "overview-project")));
        Assert(overview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>() == "overview-project/package.json"), "repo overview package manifest");
        Assert(overview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>() == "overview-project/Demo.xcodeproj"), "repo overview Xcode manifest");
        Assert(overview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>() == "overview-project/EmptyProject.xcodeproj"), "repo overview empty Xcode project manifest");
        Assert(overview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>() == "overview-project/EmptyWorkspace.xcworkspace"), "repo overview empty Xcode workspace manifest");
        Assert(overview.StructuredContent["directories_seen"]!.GetValue<int>() >= 6, "repo overview counts empty directories");
        Assert(overview.StructuredContent["default_excluded_directory_names"]!.AsArray().Any(value => value!.GetValue<string>() == "node_modules"), "repo overview exclusion metadata");
        var tsExtension = overview.StructuredContent["file_extensions"]!.AsArray().Single(value => value!["extension"]!.GetValue<string>() == ".ts");
        Assert(tsExtension!["count"]!.GetValue<int>() == 2, "repo overview extension counts exclude dependency tree");
        var xcodeContent = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("project-marker")), ("path", "overview-project"), ("max_results_per_query", 2)));
        Assert(xcodeContent.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 1, "ranked code traverses Xcode project packages");
        var xcodeNames = await safe.CallAsync("glob", Obj(("pattern", "project.pbxproj"), ("path", "overview-project")));
        Assert(xcodeNames.StructuredContent["files"]!.AsArray().Single()!.GetValue<string>() == "overview-project/Demo.xcodeproj/project.pbxproj", "glob traverses Xcode project packages");
        var broadExcludedCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("hidden")), ("path", "overview-project"), ("max_results_per_query", 2)));
        Assert(broadExcludedCode.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 0, "ranked code respects default dependency exclusion");
        var explicitExcludedCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("hidden")), ("path", "overview-project/node_modules"), ("max_results_per_query", 2)));
        Assert(explicitExcludedCode.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 1, "ranked code can explicitly inspect excluded root");
        Assert(explicitExcludedCode.StructuredContent["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["path"]!.GetValue<string>() == "overview-project/node_modules/ignored/hidden.ts", "ranked code explicit excluded-root path");
        var explicitExcludedOverview = await safe.CallAsync("repo_overview", Obj(("path", "overview-project/node_modules")));
        Assert(explicitExcludedOverview.StructuredContent["manifests"]!.AsArray().Single()!.GetValue<string>() == "overview-project/node_modules/ignored/package.json", "repo overview can explicitly inspect excluded root");
        var caseExcludedProject = Path.Combine(workspace, "case-exclusion-project");
        Directory.CreateDirectory(Path.Combine(caseExcludedProject, "NODE_MODULES", "ignored"));
        File.WriteAllText(Path.Combine(caseExcludedProject, "NODE_MODULES", "ignored", "hidden.ts"), "case-hidden\n");
        var caseExcludedCode = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("case-hidden")), ("path", "case-exclusion-project"), ("max_results_per_query", 2)));
        Assert(caseExcludedCode.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 0, "ranked code exclusion names are case-insensitive");

        var batch = await safe.CallAsync("batch_read", Obj(("operations", new JsonArray
        {
            Obj(("tool", "read_file"), ("arguments", Obj(("relative_path", "docs/note.txt")))),
            Obj(("tool", "read_file_range"), ("arguments", Obj(("relative_path", "docs/note.txt"), ("start_line", 2), ("end_line", 3)))),
            Obj(("tool", "glob"), ("arguments", Obj(("pattern", "scoped-target*"), ("path", "scope-a")))),
            Obj(("tool", "search_code"), ("arguments", Obj(("queries", new JsonArray("TypedTarget")), ("path", "ranked-search"), ("max_results_per_query", 1)))),
            Obj(("tool", "repo_overview"), ("arguments", Obj(("path", "overview-project")))),
        })));
        Assert(batch.StructuredContent["requested"]!.GetValue<int>() == 5 && batch.StructuredContent["completed"]!.GetValue<int>() == 5, "batch read completion");
        Assert(batch.StructuredContent["succeeded"]!.GetValue<int>() == 5 && batch.StructuredContent["failed"]!.GetValue<int>() == 0, "batch read success counts");
        Assert(batch.StructuredContent["results"]!.AsArray()[0]!["structured_content"]!["result"]!.GetValue<string>().Contains("beta"), "batch read result");
        Assert(batch.StructuredContent["results"]!.AsArray()[2]!["structured_content"]!["files"]!.AsArray().Single()!.GetValue<string>() == "scope-a/scoped-target.txt", "batch glob result");
        Assert(batch.StructuredContent["results"]!.AsArray()[3]!["structured_content"]!["query_results"]!.AsArray()[0]!["matches"]!.AsArray()[0]!["line"]!.GetValue<int>() == 2, "batch ranked code result");
        Assert(batch.StructuredContent["results"]!.AsArray()[4]!["structured_content"]!["manifests"]!.AsArray().Any(value => value!.GetValue<string>() == "overview-project/package.json"), "batch repo overview result");
        var rejectedBatch = await safe.CallAsync("batch_read", Obj(("stop_on_error", true), ("operations", new JsonArray
        {
            Obj(("tool", "write_file"), ("arguments", Obj(("relative_path", "should-not-exist.txt"), ("content", "no")))),
            Obj(("tool", "read_file"), ("arguments", Obj(("relative_path", "docs/note.txt")))),
        })));
        Assert(rejectedBatch.StructuredContent["completed"]!.GetValue<int>() == 1 && rejectedBatch.StructuredContent["stopped_on_error"]!.GetValue<bool>(), "batch rejects mutating tools");
        Assert(rejectedBatch.StructuredContent["succeeded"]!.GetValue<int>() == 0 && rejectedBatch.StructuredContent["failed"]!.GetValue<int>() == 1, "batch rejection counts");
        Assert(!File.Exists(Path.Combine(workspace, "should-not-exist.txt")), "batch did not mutate workspace");
        var continuedBatch = await safe.CallAsync("batch_read", Obj(("operations", new JsonArray
        {
            Obj(("tool", "write_file"), ("arguments", Obj(("relative_path", "still-should-not-exist.txt"), ("content", "no")))),
            Obj(("tool", "read_file"), ("arguments", Obj(("relative_path", "docs/note.txt")))),
        })));
        Assert(continuedBatch.StructuredContent["completed"]!.GetValue<int>() == 2 && continuedBatch.StructuredContent["succeeded"]!.GetValue<int>() == 1 && continuedBatch.StructuredContent["failed"]!.GetValue<int>() == 1, "batch continues after non-stopping error");
        Assert(!continuedBatch.StructuredContent["stopped_on_error"]!.GetValue<bool>(), "batch continue flag");
        Assert(continuedBatch.StructuredContent["results"]!.AsArray()[1]!["structured_content"]!["result"]!.GetValue<string>().Contains("beta"), "batch continued result");
        Assert(!File.Exists(Path.Combine(workspace, "still-should-not-exist.txt")), "continued batch did not mutate workspace");
        var maxBatchOperations = new JsonArray();
        for (var index = 0; index < 16; index++)
            maxBatchOperations.Add(Obj(("tool", "read_file"), ("arguments", Obj(("relative_path", "docs/note.txt")))));
        var maxBatch = await safe.CallAsync("batch_read", Obj(("operations", maxBatchOperations)));
        Assert(maxBatch.StructuredContent["requested"]!.GetValue<int>() == 16 && maxBatch.StructuredContent["succeeded"]!.GetValue<int>() == 16, "batch accepts sixteen operations");
        var tooManyBatchOperations = new JsonArray();
        for (var index = 0; index < 17; index++)
            tooManyBatchOperations.Add(Obj(("tool", "read_file"), ("arguments", Obj(("relative_path", "docs/note.txt")))));
        await AssertThrowsAsync(() => safe.CallAsync("batch_read", Obj(("operations", tooManyBatchOperations))), "at most 16", "batch rejects seventeen operations");

        var list = await safe.CallAsync("list_files", Obj(("subpath", "docs")));
        Assert(list.StructuredContent["result"]!.AsArray().Any(n => n!.GetValue<string>() == "note.txt"), "list files");

        await full.CallAsync("run_command", Obj(("command", "Write-Output windows-command-ok"), ("cwd", ""), ("timeout_seconds", 5)));
        var command = await full.CallAsync("run_command", Obj(("command", "Write-Output windows-command-ok"), ("timeout_seconds", 5)));
        Assert(command.StructuredContent["result"]!.GetValue<string>().Contains("windows-command-ok"), "run command");

        await AssertThrowsAsync(() => safe.CallAsync("read_file", Obj(("relative_path", "..\\outside.txt"))), "outside the shared directory", "lexical traversal refused");

        var outside = Path.Combine(root, "outside"); Directory.CreateDirectory(outside); File.WriteAllText(Path.Combine(outside, "secret.txt"), "outside-secret"); File.WriteAllText(Path.Combine(outside, "package.json"), "{}");
        var junction = Path.Combine(workspace, "escape");
        var mklink = await ProcessRunner.RunAsync("cmd.exe", ["/d", "/c", "mklink", "/J", junction, outside], timeoutSeconds: 5);
        Assert(mklink.ExitCode == 0, $"junction fixture: exit={mklink.ExitCode} stdout={mklink.Stdout} stderr={mklink.Stderr}");
        await AssertThrowsAsync(() => safe.CallAsync("read_file", Obj(("relative_path", "escape/secret.txt"))), "outside the shared directory", "junction read refused");
        var rankedEscape = await safe.CallAsync("search_code", Obj(("queries", new JsonArray("outside-secret")), ("max_results_per_query", 3)));
        Assert(rankedEscape.StructuredContent["query_results"]!.AsArray()[0]!["observed_matching_lines"]!.GetValue<int>() == 0, "ranked code does not traverse junctions");
        var grepEscape = await safe.CallAsync("grep", Obj(("pattern", "outside-secret")));
        Assert(grepEscape.StructuredContent["total"]!.GetValue<int>() == 0, "grep does not traverse junctions");
        var globEscape = await safe.CallAsync("glob", Obj(("pattern", "**/secret.txt")));
        Assert(globEscape.StructuredContent["total"]!.GetValue<int>() == 0, "glob does not traverse junctions");
        var rootOverview = await safe.CallAsync("repo_overview", Obj());
        Assert(!rootOverview.StructuredContent["manifests"]!.AsArray().Any(value => value!.GetValue<string>().Contains("escape/package.json", StringComparison.Ordinal)), "repo overview does not traverse junctions");
        await AssertThrowsAsync(() => safe.CallAsync("delete_directory", Obj(("relative_path", "escape"))), "Use delete_file", "junction directory delete refused");
        await safe.CallAsync("delete_file", Obj(("relative_path", "escape")));
        Assert(!Directory.Exists(junction) && File.Exists(Path.Combine(outside, "secret.txt")), "junction delete removes link only");
        await safe.CallAsync("delete_file", Obj(("relative_path", "docs/note.txt")));
        await safe.CallAsync("delete_directory", Obj(("relative_path", "docs")));
        Assert(!Directory.Exists(Path.Combine(workspace, "docs")), "delete directory");
        Console.WriteLine("windows-filesystem-tools: ok");
    }

    private static async Task TestCodexHistoryAsync(string root)
    {
        var workspace = Path.Combine(root, "codex-workspace");
        Directory.CreateDirectory(workspace);
        var codexHome = Path.Combine(root, "fake-codex-home");
        Directory.CreateDirectory(codexHome);
        var oldCodexBin = Environment.GetEnvironmentVariable("CODEX_BIN");
        var oldFake = Environment.GetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX");
        var oldFakeHome = Environment.GetEnvironmentVariable("FILEMCP_TEST_CODEX_HOME");
        var oldFakeCorruptTurns = Environment.GetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX_CORRUPT_TURNS");
        var testAssembly = typeof(Program).Assembly.Location;
        var fakeLauncher = Path.ChangeExtension(testAssembly, ".exe");
        if (!File.Exists(fakeLauncher)) throw new Exception("Windows test apphost executable is unavailable");
        Environment.SetEnvironmentVariable("CODEX_BIN", fakeLauncher);
        Environment.SetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX", "1");
        Environment.SetEnvironmentVariable("FILEMCP_TEST_CODEX_HOME", codexHome);
        try
        {
            var tools = new LocalTools(workspace, "FileMCP Test", "filemcp@example.invalid", false);
            var invalidMessages = new JsonArray(new JsonObject { ["role"] = "system", ["content"] = "reject" });
            await AssertThrowsAsync(
                () => tools.CallAsync("save_conversation_to_codex", new JsonObject { ["title"] = "invalid", ["messages"] = invalidMessages }),
                "role must be user or assistant",
                "Codex invalid role rejected");

            var messages = new JsonArray(
                new JsonObject { ["role"] = "user", ["content"] = "Windows import user one" },
                new JsonObject { ["role"] = "assistant", ["content"] = "Windows import commentary" },
                new JsonObject { ["role"] = "assistant", ["content"] = "Windows import final one" },
                new JsonObject { ["role"] = "user", ["content"] = "Windows import user two" },
                new JsonObject { ["role"] = "assistant", ["content"] = "Windows import final two" });
            var result = await tools.CallAsync(
                "save_conversation_to_codex",
                new JsonObject
                {
                    ["title"] = "FileMCP Windows Codex E2E",
                    ["repo_path"] = "",
                    ["messages"] = messages,
                });
            var output = result.StructuredContent;
            var threadId = output["thread_id"]!.GetValue<string>();
            Assert(!string.IsNullOrWhiteSpace(threadId), "Codex Windows thread id returned");
            Assert(output["title"]!.GetValue<string>() == "FileMCP Windows Codex E2E", "Codex Windows title returned");
            Assert(output["repo_path"]!.GetValue<string>() == ".", "Codex Windows relative repo path returned");
            Assert(output["message_count"]!.GetValue<int>() == 5 && output["turn_count"]!.GetValue<int>() == 2, "Codex Windows message and turn counts");
            Assert(output["path"] is null && output["cwd"] is null, "Codex Windows output does not leak absolute paths");

            var rollout = Directory.EnumerateFiles(Path.Combine(codexHome, "sessions"), "*.jsonl", SearchOption.AllDirectories)
                .Single(path => Path.GetFileName(path).Contains(threadId, StringComparison.OrdinalIgnoreCase));
            var text = File.ReadAllText(rollout);
            Assert(text.Contains("Windows import user one", StringComparison.Ordinal) && text.Contains("Windows import final two", StringComparison.Ordinal), "Codex Windows rollout persisted messages");
            Assert(text.Contains("\"type\":\"session_meta\"", StringComparison.Ordinal), "Codex Windows rollout retained session metadata");

            var filesBeforeFailedImport = Directory.EnumerateFiles(Path.Combine(codexHome, "sessions"), "*.jsonl", SearchOption.AllDirectories).Count();
            Environment.SetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX_CORRUPT_TURNS", "1");
            await AssertThrowsAsync(
                () => tools.CallAsync(
                    "save_conversation_to_codex",
                    new JsonObject
                    {
                        ["title"] = "FileMCP Windows cleanup E2E",
                        ["messages"] = new JsonArray(new JsonObject { ["role"] = "user", ["content"] = "cleanup fixture" }),
                    }),
                "could not hydrate all imported conversation turns",
                "Codex Windows verification failure propagated");
            Environment.SetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX_CORRUPT_TURNS", null);
            var filesAfterFailedImport = Directory.EnumerateFiles(Path.Combine(codexHome, "sessions"), "*.jsonl", SearchOption.AllDirectories).Count();
            Assert(filesAfterFailedImport == filesBeforeFailedImport, "Codex Windows failed import cleaned its rollout");
            Console.WriteLine("windows-codex-history: ok");
        }
        finally
        {
            Environment.SetEnvironmentVariable("CODEX_BIN", oldCodexBin);
            Environment.SetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX", oldFake);
            Environment.SetEnvironmentVariable("FILEMCP_TEST_CODEX_HOME", oldFakeHome);
            Environment.SetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX_CORRUPT_TURNS", oldFakeCorruptTurns);
        }

        if (Environment.GetEnvironmentVariable("FILEMCP_REAL_CODEX_E2E") == "1")
        {
            if (!CodexHistoryImporter.TryLocateCodexExecutable(out var realCodex))
                throw new Exception("FILEMCP_REAL_CODEX_E2E=1 but no Codex executable was found");
            var imported = await CodexHistoryImporter.SaveAsync(
                "FileMCP Windows real Codex E2E",
                workspace,
                [
                    new CodexHistoryMessage("user", "Real Windows Codex E2E user"),
                    new CodexHistoryMessage("assistant", "Real Windows Codex E2E assistant"),
                ]);
            await using var cleanup = new CodexAppServerClient(realCodex);
            _ = await cleanup.InitializeAsync(CancellationToken.None);
            _ = await cleanup.RequestAsync("thread/delete", new JsonObject { ["threadId"] = imported.ThreadId });
            Console.WriteLine("windows-codex-history-real: ok");
        }
    }

    private static async Task TestGitSafetyAsync(string root)
    {
        var gitVersion = await ProcessRunner.RunAsync("git.exe", ["--version"], timeoutSeconds: 10);
        Assert(gitVersion.ExitCode == 0, "git available");
        var workspace = Path.Combine(root, "git"); Directory.CreateDirectory(workspace);
        var tools = new LocalTools(workspace, "FileMCP Test", "filemcp@example.invalid", false);
        await tools.CallAsync("git_init", Obj(("repo_path", "repo")));
        await tools.CallAsync("write_file", Obj(("relative_path", "repo/a.txt"), ("content", "one\n")));
        await tools.CallAsync("git_add", Obj(("repo_path", "repo"), ("paths", "a.txt")));
        await tools.CallAsync("git_commit", Obj(("repo_path", "repo"), ("message", "initial")));
        var log = await tools.CallAsync("git_log", Obj(("repo_path", "repo"), ("count", 5)));
        Assert(log.StructuredContent["result"]!.GetValue<string>().Contains("initial"), "git log");

        var repo = Path.Combine(workspace, "repo");
        var hooksDirectory = Path.Combine(repo, ".git", "hooks");
        Directory.CreateDirectory(hooksDirectory);
        var hook = Path.Combine(hooksDirectory, "pre-commit");
        File.WriteAllText(hook, "#!/bin/sh\ntouch hook-ran\n", new UTF8Encoding(false));
        File.AppendAllText(Path.Combine(repo, "a.txt"), "two\n");
        await tools.CallAsync("git_add", Obj(("repo_path", "repo"), ("paths", "a.txt")));
        await tools.CallAsync("git_commit", Obj(("repo_path", "repo"), ("message", "safe commit")));
        Assert(!File.Exists(Path.Combine(repo, "hook-ran")), "git hooks suppressed");

        await GitCli(repo, ["config", "filter.audit.clean", "cat"]);
        await GitCli(repo, ["config", "filter.audit.smudge", "cat"]);
        File.WriteAllText(Path.Combine(repo, ".gitattributes"), "*.filter filter=audit\n");
        File.WriteAllText(Path.Combine(repo, "blocked.filter"), "filtered\n");
        await AssertThrowsAsync(() => tools.CallAsync("git_add", Obj(("repo_path", "repo"), ("paths", "blocked.filter"))), "content filter", "git filter refused");

        var include = Path.Combine(root, "outside-gitconfig"); File.WriteAllText(include, "[user]\nname = outside\n");
        await GitCli(repo, ["config", "include.path", include]);
        await AssertThrowsAsync(() => tools.CallAsync("git_status", Obj(("repo_path", "repo"))), "config includes", "git config include refused");
        await GitCli(repo, ["config", "--unset-all", "include.path"]);

        var linkedMain = Path.Combine(workspace, "linked-main");
        var linkedWorktree = Path.Combine(workspace, "linked-worktree");
        Directory.CreateDirectory(linkedMain);
        await GitCli(linkedMain, ["init", "-b", "main"]);
        File.WriteAllText(Path.Combine(linkedMain, "linked.txt"), "linked\n");
        await GitCli(linkedMain, ["add", "linked.txt"]);
        await GitCli(linkedMain, ["-c", "user.name=FileMCP Test", "-c", "user.email=filemcp@example.invalid", "commit", "-m", "linked initial"]);
        await GitCli(linkedMain, ["worktree", "add", "-b", "linked-branch", linkedWorktree]);
        var linkedStatus = await tools.CallAsync("git_status", Obj(("repo_path", "linked-worktree")));
        Assert(linkedStatus.StructuredContent["result"]!.GetValue<string>() == "(working tree clean)", "linked worktree inside shared root");

        var escapeRepo = Path.Combine(workspace, "worktree-escape");
        var outsideWorktree = Path.Combine(root, "outside-worktree");
        Directory.CreateDirectory(escapeRepo); Directory.CreateDirectory(outsideWorktree);
        await GitCli(escapeRepo, ["init", "-b", "main"]);
        await GitCli(escapeRepo, ["config", "core.worktree", outsideWorktree]);
        await AssertThrowsAsync(() => tools.CallAsync("git_status", Obj(("repo_path", "worktree-escape"))), "worktree is outside or different", "core.worktree escape refused");

        var bare = Path.Combine(root, "outside.git");
        var initBare = await ProcessRunner.RunAsync("git.exe", ["init", "--bare", bare], timeoutSeconds: 20); Assert(initBare.ExitCode == 0, "bare remote fixture");
        await GitCli(repo, ["remote", "add", "origin", bare]);
        await GitCli(repo, ["config", "branch.main.remote", "origin"]); await GitCli(repo, ["config", "branch.main.merge", "refs/heads/main"]);
        await AssertThrowsAsync(() => tools.CallAsync("git_push", Obj(("repo_path", "repo"))), "transport 'file' not allowed", "local file push refused");
        Console.WriteLine("windows-git-safe-mode: ok");
    }

    private static async Task TestHttpAndMcpAsync(string root)
    {
        var workspace = Path.Combine(root, "http"); Directory.CreateDirectory(workspace); File.WriteAllText(Path.Combine(workspace, "hello.txt"), "hello");
        var port = FreePort(); var token = new string('a', 64);
        await using var server = new LocalMcpServer((ushort)port, workspace, "", "", false, token, _ => { });
        await server.StartAsync();

        var fuzzIterations = int.TryParse(Environment.GetEnvironmentVariable("MCP_HTTP_FUZZ_ITERATIONS"), out var configuredFuzz) ? Math.Max(1, configuredFuzz) : 160;
        var random = new Random(0xF11E);
        for (var index = 0; index < fuzzIterations; index++)
        {
            var bytes = new byte[random.Next(0, 2048)];
            random.NextBytes(bytes);
            _ = server.ParseHttpRequest(bytes);
        }
        Assert(true, $"HTTP malformed fuzz ({fuzzIterations} iterations)");
        var authBeforeBodyRequest = Encoding.ASCII.GetBytes(
            $"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nContent-Type: application/json\r\nContent-Length: 1000000\r\n\r\n");
        var authBeforeBody = server.ParseHttpRequest(authBeforeBodyRequest);
        Assert(authBeforeBody.Status == HttpParseStatus.Failure && authBeforeBody.FailureStatus == 401, "local auth rejected before request body");

        var unauthorized = await SendHttpAsync(port, "POST", "/mcp", new Dictionary<string, string> { ["Content-Type"] = "application/json" }, "");
        Assert(unauthorized.StartsWith("HTTP/1.1 401 Unauthorized", StringComparison.Ordinal), "local auth required");

        var discoveryPath = await SendHttpAsync(port, "GET", "/.well-known/oauth-protected-resource/mcp", new Dictionary<string, string>(), "");
        Assert(discoveryPath.StartsWith("HTTP/1.1 404 Not Found", StringComparison.Ordinal) && HttpBody(discoveryPath) == "Not found", "OAuth discovery path is public and not advertised");

        var discoveryRoot = await SendHttpAsync(port, "GET", "/.well-known/oauth-protected-resource", new Dictionary<string, string>(), "");
        Assert(discoveryRoot.StartsWith("HTTP/1.1 404 Not Found", StringComparison.Ordinal), "OAuth discovery root is public and not advertised");

        var unauthorizedUnknownPath = await SendHttpAsync(port, "GET", "/not-found", new Dictionary<string, string>(), "");
        Assert(unauthorizedUnknownPath.StartsWith("HTTP/1.1 401 Unauthorized", StringComparison.Ordinal), "unknown paths still require local auth");

        var unauthorizedDiscoveryPost = await SendHttpAsync(port, "POST", "/.well-known/oauth-protected-resource/mcp", new Dictionary<string, string>(), "");
        Assert(unauthorizedDiscoveryPost.StartsWith("HTTP/1.1 401 Unauthorized", StringComparison.Ordinal), "only GET OAuth discovery bypasses local auth");

        var legacy = await SendHttpAsync(port, "POST", "/mcp", AuthHeaders(token), "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}");
        var legacyBody = JsonNode.Parse(HttpBody(legacy))!.AsObject();
        Assert(legacyBody["result"]!["tools"]!.AsArray().Count == 22, "legacy tools list");

        var modernHeaders = AuthHeaders(token); modernHeaders["MCP-Protocol-Version"] = FileMcpConstants.ModernProtocolVersion; modernHeaders["Mcp-Method"] = "tools/list";
        var modernBody = new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 3, ["method"] = "tools/list",
            ["params"] = new JsonObject { ["_meta"] = new JsonObject { ["io.modelcontextprotocol/protocolVersion"] = FileMcpConstants.ModernProtocolVersion, ["io.modelcontextprotocol/clientCapabilities"] = new JsonObject(), ["io.modelcontextprotocol/clientInfo"] = new JsonObject { ["name"] = "test", ["version"] = "1" } } },
        };
        var modern = await SendHttpAsync(port, "POST", "/mcp", modernHeaders, modernBody.ToJsonString());
        var modernJson = JsonNode.Parse(HttpBody(modern))!.AsObject();
        Assert(modernJson["result"]!["resultType"]!.GetValue<string>() == "complete", "modern result type");
        Assert(modernJson["result"]!["tools"]!.AsArray().Count == 22, "modern tools list");
        Assert(modernJson["result"]!["tools"]!.AsArray().Any(tool => tool!["name"]!.GetValue<string>() == "search_code"), "modern ranked search tool");
        Assert(modernJson["result"]!["tools"]!.AsArray().Any(tool => tool!["name"]!.GetValue<string>() == "repo_overview"), "modern repository overview tool");

        var discoverHeaders = AuthHeaders(token);
        discoverHeaders["MCP-Protocol-Version"] = FileMcpConstants.ModernProtocolVersion;
        discoverHeaders["Mcp-Method"] = "server/discover";
        var discoverBody = new JsonObject
        {
            ["jsonrpc"] = "2.0", ["id"] = 4, ["method"] = "server/discover",
            ["params"] = modernBody["params"]!.DeepClone(),
        };
        var discover = await SendHttpAsync(port, "POST", "/mcp", discoverHeaders, discoverBody.ToJsonString());
        var discoverJson = JsonNode.Parse(HttpBody(discover))!.AsObject();
        var instructions = discoverJson["result"]!["instructions"]!.GetValue<string>();
        Assert(instructions.Contains("search_code", StringComparison.Ordinal) && instructions.Contains("repo_overview", StringComparison.Ordinal) && instructions.Contains("apply_patch", StringComparison.Ordinal) && instructions.Contains("workspace_context", StringComparison.Ordinal), "modern coding-workflow instructions");

        var badHost = await SendHttpAsync(port, "POST", "/mcp", AuthHeaders(token), "", host: "evil.example");
        Assert(badHost.StartsWith("HTTP/1.1 403 Forbidden", StringComparison.Ordinal), "host validation");
        Console.WriteLine("windows-http-mcp: ok");
    }

    private static async Task TestRuntimeAsync(string root)
    {
        var workspace = Path.Combine(root, "runtime-workspace"); Directory.CreateDirectory(workspace);
        var profiles = Path.Combine(root, "runtime-profiles"); var capture = Path.Combine(root, "tunnel-env.txt");
        Environment.SetEnvironmentVariable("MCP_TUNNEL_CLIENT", Environment.ProcessPath);
        Environment.SetEnvironmentVariable("MCP_TEST_ENV_CAPTURE", capture);
        Environment.SetEnvironmentVariable("LOG_HTTP_RAW_UNSAFE", "true");
        Environment.SetEnvironmentVariable("MCP_SERVER_URL", "http://evil.invalid/mcp");
        var runtime = new LocalMcpRuntime(profiles); var logs = new StringBuilder(); runtime.Log += text => logs.Append(text);
        try
        {
            var config = new LocalMcpConfiguration("tunnel_" + new string('b', 32), "sk-runtime-test-secret", "runtime-test", (ushort)FreePort(), workspace, "127.0.0.1:0", "", "", false);
            await runtime.StartAsync(config);
            Assert(runtime.State.Status == LocalMcpRuntimeStatus.Running, "runtime running");
            Assert(File.Exists(Path.Combine(profiles, "runtime-test.yaml")), "isolated profile created");
            var captureText = File.ReadAllText(capture);
            Assert(captureText.Contains("X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN"), "local auth header env indirection");
            Assert(!captureText.Contains("LOG_HTTP_RAW_UNSAFE=true", StringComparison.Ordinal) && !captureText.Contains("MCP_SERVER_URL=http://evil", StringComparison.Ordinal), "dangerous tunnel env not inherited");
            Assert(!logs.ToString().Contains("sk-runtime-test-secret", StringComparison.Ordinal), "api key redacted");
            Assert(!System.Text.RegularExpressions.Regex.IsMatch(logs.ToString(), "[0-9a-f]{64}"), "local token redacted");
            await runtime.StopAsync();
            Assert(runtime.State.Status == LocalMcpRuntimeStatus.Stopped, "runtime stopped");
        }
        finally
        {
            await runtime.DisposeAsync();
            Environment.SetEnvironmentVariable("MCP_TUNNEL_CLIENT", null); Environment.SetEnvironmentVariable("MCP_TEST_ENV_CAPTURE", null);
            Environment.SetEnvironmentVariable("LOG_HTTP_RAW_UNSAFE", null); Environment.SetEnvironmentVariable("MCP_SERVER_URL", null);
        }
        Console.WriteLine("windows-runtime-lifecycle: ok");
    }

    private static async Task<int> RunFakeCodexAppServerAsync()
    {
        var codexHome = Environment.GetEnvironmentVariable("FILEMCP_TEST_CODEX_HOME")
            ?? throw new InvalidOperationException("FILEMCP_TEST_CODEX_HOME is required for the fake Codex server");
        Directory.CreateDirectory(Path.Combine(codexHome, "sessions"));
        string? line;
        while ((line = await Console.In.ReadLineAsync()) is not null)
        {
            JsonObject? request;
            try { request = JsonNode.Parse(line) as JsonObject; }
            catch { continue; }
            if (request is null || request["id"] is not JsonValue idValue || !idValue.TryGetValue<int>(out var id))
                continue;
            var method = request["method"]?.GetValue<string>() ?? "";
            var parameters = request["params"] as JsonObject ?? new JsonObject();
            JsonObject response;
            try
            {
                var result = HandleFakeCodexRequest(codexHome, method, parameters);
                response = new JsonObject { ["jsonrpc"] = "2.0", ["id"] = id, ["result"] = result };
            }
            catch (Exception ex)
            {
                response = new JsonObject
                {
                    ["jsonrpc"] = "2.0",
                    ["id"] = id,
                    ["error"] = new JsonObject { ["code"] = -32603, ["message"] = ex.Message },
                };
            }
            await Console.Out.WriteLineAsync(response.ToJsonString());
            await Console.Out.FlushAsync();
        }
        return 0;
    }

    private static JsonObject HandleFakeCodexRequest(string codexHome, string method, JsonObject parameters)
    {
        switch (method)
        {
            case "initialize":
                return new JsonObject { ["codexHome"] = codexHome };
            case "thread/start":
            {
                var cwd = parameters["cwd"]?.GetValue<string>() ?? throw new InvalidOperationException("missing cwd");
                var id = "fake-" + Guid.NewGuid().ToString("N");
                var sessions = Path.Combine(codexHome, "sessions", "2026", "08", "24");
                Directory.CreateDirectory(sessions);
                var path = Path.Combine(sessions, $"rollout-2026-08-24T09-00-00-{id}.jsonl");
                var metadata = new JsonObject
                {
                    ["timestamp"] = DateTimeOffset.UtcNow.ToString("O"),
                    ["type"] = "session_meta",
                    ["payload"] = new JsonObject
                    {
                        ["session_id"] = id,
                        ["id"] = id,
                        ["timestamp"] = DateTimeOffset.UtcNow.ToString("O"),
                        ["cwd"] = cwd,
                        ["originator"] = "filemcp-test",
                        ["cli_version"] = "test",
                        ["source"] = "vscode",
                        ["model_provider"] = "openai",
                    },
                };
                File.WriteAllText(path, metadata.ToJsonString() + "\n", new UTF8Encoding(false));
                return new JsonObject
                {
                    ["thread"] = new JsonObject { ["id"] = id, ["path"] = path, ["cwd"] = cwd },
                };
            }
            case "thread/name/set":
            {
                var id = parameters["threadId"]?.GetValue<string>() ?? throw new InvalidOperationException("missing threadId");
                var name = parameters["name"]?.GetValue<string>() ?? "";
                var names = Path.Combine(codexHome, "fake-thread-names");
                Directory.CreateDirectory(names);
                File.WriteAllText(Path.Combine(names, id + ".txt"), name, new UTF8Encoding(false));
                return new JsonObject();
            }
            case "thread/list":
            {
                var cwd = parameters["cwd"]?.GetValue<string>();
                var limit = parameters["limit"]?.GetValue<int>() ?? 100;
                var data = new JsonArray();
                var sessions = Path.Combine(codexHome, "sessions");
                if (Directory.Exists(sessions))
                {
                    foreach (var path in Directory.EnumerateFiles(sessions, "*.jsonl", SearchOption.AllDirectories).OrderByDescending(File.GetLastWriteTimeUtc))
                    {
                        var metadata = ReadFakeSessionMetadata(path);
                        if (metadata is null) continue;
                        var id = metadata.Value.Id;
                        if (cwd is not null && !string.Equals(metadata.Value.Cwd, cwd, StringComparison.OrdinalIgnoreCase)) continue;
                        var namePath = Path.Combine(codexHome, "fake-thread-names", id + ".txt");
                        var name = File.Exists(namePath) ? File.ReadAllText(namePath) : null;
                        data.Add(new JsonObject
                        {
                            ["id"] = id,
                            ["name"] = name,
                            ["cwd"] = metadata.Value.Cwd,
                            ["path"] = path,
                            ["status"] = new JsonObject { ["type"] = "notLoaded" },
                        });
                        if (data.Count >= limit) break;
                    }
                }
                return new JsonObject { ["data"] = data };
            }
            case "thread/resume":
            {
                var id = parameters["threadId"]?.GetValue<string>() ?? throw new InvalidOperationException("missing threadId");
                var path = FindFakeRollout(codexHome, id) ?? throw new InvalidOperationException("thread not found");
                return new JsonObject { ["thread"] = new JsonObject { ["id"] = id, ["path"] = path } };
            }
            case "thread/turns/list":
            {
                var id = parameters["threadId"]?.GetValue<string>() ?? throw new InvalidOperationException("missing threadId");
                var path = FindFakeRollout(codexHome, id) ?? throw new InvalidOperationException("thread not found");
                var turns = Environment.GetEnvironmentVariable("FILEMCP_TEST_FAKE_CODEX_CORRUPT_TURNS") == "1"
                    ? new List<FakeCodexTurn>()
                    : ParseFakeCodexTurns(path);
                if (parameters["sortDirection"]?.GetValue<string>() == "desc") turns.Reverse();
                var data = new JsonArray();
                foreach (var turn in turns)
                {
                    data.Add(new JsonObject
                    {
                        ["id"] = turn.Id,
                        ["items"] = turn.Items,
                        ["itemsView"] = "full",
                        ["status"] = turn.Completed ? "completed" : "inProgress",
                        ["error"] = null,
                        ["startedAt"] = turn.StartedAt,
                        ["completedAt"] = turn.CompletedAt,
                        ["durationMs"] = Math.Max(0, turn.CompletedAt - turn.StartedAt) * 1000,
                    });
                }
                return new JsonObject { ["data"] = data, ["nextCursor"] = null, ["backwardsCursor"] = null };
            }
            case "thread/delete":
            {
                var id = parameters["threadId"]?.GetValue<string>() ?? throw new InvalidOperationException("missing threadId");
                var path = FindFakeRollout(codexHome, id);
                if (path is not null) File.Delete(path);
                var namePath = Path.Combine(codexHome, "fake-thread-names", id + ".txt");
                if (File.Exists(namePath)) File.Delete(namePath);
                return new JsonObject();
            }
            default:
                throw new InvalidOperationException("unsupported fake Codex method: " + method);
        }
    }

    private static (string Id, string Cwd)? ReadFakeSessionMetadata(string path)
    {
        try
        {
            var line = File.ReadLines(path).FirstOrDefault();
            var record = line is null ? null : JsonNode.Parse(line) as JsonObject;
            if (record?["type"]?.GetValue<string>() != "session_meta") return null;
            var payload = record["payload"] as JsonObject;
            var id = payload?["id"]?.GetValue<string>() ?? payload?["session_id"]?.GetValue<string>();
            var cwd = payload?["cwd"]?.GetValue<string>();
            return string.IsNullOrWhiteSpace(id) || string.IsNullOrWhiteSpace(cwd) ? null : (id!, cwd!);
        }
        catch { return null; }
    }

    private static string? FindFakeRollout(string codexHome, string threadId)
    {
        var sessions = Path.Combine(codexHome, "sessions");
        return Directory.Exists(sessions)
            ? Directory.EnumerateFiles(sessions, "*.jsonl", SearchOption.AllDirectories)
                .FirstOrDefault(path => Path.GetFileName(path).Contains(threadId, StringComparison.OrdinalIgnoreCase))
            : null;
    }

    private static List<FakeCodexTurn> ParseFakeCodexTurns(string path)
    {
        var ordered = new List<FakeCodexTurn>();
        var byId = new Dictionary<string, FakeCodexTurn>(StringComparer.Ordinal);
        var itemIndex = 0;
        foreach (var line in File.ReadLines(path).Skip(1))
        {
            JsonObject? record;
            try { record = JsonNode.Parse(line) as JsonObject; } catch { continue; }
            if (record is null) continue;
            var type = record["type"]?.GetValue<string>();
            var payload = record["payload"] as JsonObject;
            if (type == "event_msg" && payload?["type"]?.GetValue<string>() == "task_started")
            {
                var id = payload["turn_id"]?.GetValue<string>();
                if (id is null) continue;
                var turn = new FakeCodexTurn { Id = id, StartedAt = payload["started_at"]?.GetValue<long>() ?? 0 };
                ordered.Add(turn); byId[id] = turn;
            }
            else if (type == "response_item" && payload?["type"]?.GetValue<string>() == "message")
            {
                var metadata = payload["internal_chat_message_metadata_passthrough"] as JsonObject;
                var turnId = metadata?["turn_id"]?.GetValue<string>();
                if (turnId is null || !byId.TryGetValue(turnId, out var turn)) continue;
                var role = payload["role"]?.GetValue<string>();
                var content = payload["content"] as JsonArray;
                if (role == "user")
                {
                    var text = content?.OfType<JsonObject>().FirstOrDefault(node => node["type"]?.GetValue<string>() == "input_text")?["text"]?.GetValue<string>();
                    if (text is not null)
                        turn.Items.Add(new JsonObject { ["type"] = "userMessage", ["id"] = "item-" + (++itemIndex), ["clientId"] = null, ["content"] = new JsonArray(new JsonObject { ["type"] = "text", ["text"] = text, ["text_elements"] = new JsonArray() }) });
                }
                else if (role == "assistant")
                {
                    var text = content?.OfType<JsonObject>().FirstOrDefault(node => node["type"]?.GetValue<string>() == "output_text")?["text"]?.GetValue<string>();
                    if (text is not null)
                        turn.Items.Add(new JsonObject { ["type"] = "agentMessage", ["id"] = "item-" + (++itemIndex), ["text"] = text, ["phase"] = payload["phase"]?.GetValue<string>(), ["memoryCitation"] = null, ["delivery"] = null });
                }
            }
            else if (type == "event_msg" && payload?["type"]?.GetValue<string>() == "task_complete")
            {
                var turnId = payload["turn_id"]?.GetValue<string>();
                if (turnId is null || !byId.TryGetValue(turnId, out var turn)) continue;
                turn.Completed = true;
                turn.CompletedAt = payload["completed_at"]?.GetValue<long>() ?? turn.StartedAt;
            }
        }
        return ordered;
    }

    private static async Task<int> RunFakeTunnelClientAsync(string[] args)
    {
        var capture = Environment.GetEnvironmentVariable("MCP_TEST_ENV_CAPTURE");
        if (!string.IsNullOrEmpty(capture))
        {
            var text = string.Join('\n', new[]
            {
                "MCP_EXTRA_HEADERS=" + Environment.GetEnvironmentVariable("MCP_EXTRA_HEADERS"),
                "MCP_DISCOVERY_EXTRA_HEADERS=" + Environment.GetEnvironmentVariable("MCP_DISCOVERY_EXTRA_HEADERS"),
                "FILEMCP_LOCAL_AUTH_TOKEN=" + Environment.GetEnvironmentVariable("FILEMCP_LOCAL_AUTH_TOKEN"),
                "LOG_HTTP_RAW_UNSAFE=" + Environment.GetEnvironmentVariable("LOG_HTTP_RAW_UNSAFE"),
                "MCP_SERVER_URL=" + Environment.GetEnvironmentVariable("MCP_SERVER_URL"),
            });
            File.WriteAllText(capture, text);
        }
        var token = Environment.GetEnvironmentVariable("FILEMCP_LOCAL_AUTH_TOKEN") ?? ""; var apiKey = Environment.GetEnvironmentVariable("CONTROL_PLANE_API_KEY") ?? "";
        if (args[0] == "init")
        {
            var profile = ValueAfter(args, "--profile"); var profileDir = ValueAfter(args, "--profile-dir");
            Directory.CreateDirectory(profileDir); File.WriteAllText(Path.Combine(profileDir, profile + ".yaml"), "control_plane:\n  api_key: env:CONTROL_PLANE_API_KEY\n");
            Console.WriteLine("init-ok " + apiKey + " " + token); return 0;
        }
        if (args[0] == "doctor") { Console.WriteLine("doctor-ok " + apiKey + " " + token); return 0; }
        Console.WriteLine("run-ok " + apiKey + " " + token);
        await Task.Delay(Timeout.InfiniteTimeSpan); return 0;
    }

    private static string ValueAfter(string[] args, string key) { var index = Array.IndexOf(args, key); return index >= 0 && index + 1 < args.Length ? args[index + 1] : throw new InvalidOperationException("missing " + key); }
    private static async Task GitCli(string repo, string[] args) { var all = new List<string> { "-C", repo }; all.AddRange(args); var result = await ProcessRunner.RunAsync("git.exe", all, timeoutSeconds: 20); if (result.ExitCode != 0) throw new Exception("git fixture failed: " + result.Stderr); }
    private static JsonObject Obj(params (string Key, object Value)[] values)
    {
        var obj = new JsonObject();
        foreach (var (key, value) in values)
            obj[key] = value is JsonNode node ? node.DeepClone() : JsonValue.Create(value);
        return obj;
    }
    private static void Assert(bool condition, string message) { _assertions++; if (!condition) throw new Exception("Assertion failed: " + message); }
    private static async Task AssertThrowsAsync(Func<Task> action, string contains, string message) { try { await action(); } catch (Exception ex) when (ex.Message.Contains(contains, StringComparison.OrdinalIgnoreCase)) { Assert(true, message); return; } throw new Exception("Assertion failed: " + message); }
    private static int FreePort() { var listener = new TcpListener(IPAddress.Loopback, 0); listener.Start(); var port = ((IPEndPoint)listener.LocalEndpoint).Port; listener.Stop(); return port; }
    private static Dictionary<string, string> AuthHeaders(string token) => new(StringComparer.OrdinalIgnoreCase) { ["Content-Type"] = "application/json", [FileMcpConstants.LocalAuthHeaderName] = token };
    private static async Task<string> SendHttpAsync(int port, string method, string path, Dictionary<string, string> headers, string body, string? host = null)
    {
        var bytes = Encoding.UTF8.GetBytes(body); using var client = new TcpClient(); await client.ConnectAsync(IPAddress.Loopback, port); var stream = client.GetStream();
        var builder = new StringBuilder($"{method} {path} HTTP/1.1\r\nHost: {host ?? $"127.0.0.1:{port}"}\r\n"); foreach (var pair in headers) builder.Append(pair.Key).Append(": ").Append(pair.Value).Append("\r\n"); builder.Append("Content-Length: ").Append(bytes.Length).Append("\r\n\r\n");
        var head = Encoding.UTF8.GetBytes(builder.ToString()); await stream.WriteAsync(head); await stream.WriteAsync(bytes); client.Client.Shutdown(SocketShutdown.Send);
        using var memory = new MemoryStream(); var buffer = new byte[8192]; int read; while ((read = await stream.ReadAsync(buffer)) > 0) memory.Write(buffer, 0, read); return Encoding.UTF8.GetString(memory.ToArray());
    }
    private static string HttpBody(string response) { var index = response.IndexOf("\r\n\r\n", StringComparison.Ordinal); return index >= 0 ? response[(index + 4)..] : response; }
}
