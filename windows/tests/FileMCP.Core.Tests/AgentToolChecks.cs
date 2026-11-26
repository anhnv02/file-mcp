using System.Diagnostics;
using System.Text;
using System.Text.Json.Nodes;
using FileMCP.Core;

namespace FileMCP.Core.Tests;

internal static partial class Program
{
    private static bool IsProcessRunning(int pid)
    {
        try { using var process = Process.GetProcessById(pid); return !process.HasExited; }
        catch (ArgumentException) { return false; }
    }

    private static async Task TestAgentToolsAsync(string testRoot)
    {
        var root = Path.Combine(testRoot, "agent-tools");
        Directory.CreateDirectory(Path.Combine(root, "nested"));
        var safe = new LocalTools(root, "Test", "test@example.invalid", false);
        var capacity = int.TryParse(Environment.GetEnvironmentVariable("FILEMCP_MAX_CONCURRENT_COMMANDS"), out var configured) ? Math.Clamp(configured, 4, 16) : 8;
        var sharedBudget = new WorkspaceCommandBudget(capacity);
        var full = new LocalTools(root, "Test", "test@example.invalid", true, sharedBudget: sharedBudget);
        async Task<JsonObject> Call(LocalTools tools, string name, JsonObject? args = null) => (await tools.CallAsync(name, args ?? new JsonObject())).StructuredContent;
        async Task<JsonObject> Poll(string id, int cursor = 0, int deadlineSeconds = 12)
        {
            var watch = Stopwatch.StartNew();
            while (watch.Elapsed < TimeSpan.FromSeconds(deadlineSeconds))
            {
                var value = await Call(full, "read_command_output", Obj(("session_id", id), ("cursor", cursor)));
                if (value["state"]!.GetValue<string>() is not ("running" or "stopping")) return value;
                await Task.Delay(30);
            }
            throw new Exception($"Command {id} did not finish within {deadlineSeconds}s");
        }
        try
        {
            Assert(safe.HasTool("edit_file") && safe.HasTool("workspace_context") && !safe.HasTool("start_command"), "agent tool permissions");
            var file = Path.Combine(root, "nested", "code.txt");
            File.WriteAllText(file, "héllo 👋\r\nkeep\r\n", new UTF8Encoding(false));
            var edit = Obj(("relative_path", "nested/code.txt"), ("old_text", "héllo 👋"), ("new_text", "xin chào"), ("dry_run", true));
            var preview = await Call(safe, "edit_file", edit);
            Assert(!preview["applied"]!.GetValue<bool>() && File.ReadAllText(file).StartsWith("héllo"), "edit preview does not write");
            edit["dry_run"] = false; edit["expected_sha256"] = preview["before_sha256"]!.GetValue<string>();
            await Call(safe, "edit_file", edit);
            Assert(File.ReadAllText(file) == "xin chào\r\nkeep\r\n", "edit preserves Unicode and CRLF");
            await AssertThrowsAsync(() => Call(safe, "edit_file", edit), "conflict", "stale edit refused");
            File.WriteAllText(Path.Combine(root, "ambiguous.txt"), "aaa");
            await AssertThrowsAsync(() => Call(safe, "edit_file", Obj(("relative_path", "ambiguous.txt"), ("old_text", "aa"), ("new_text", "x"))), "more than once", "overlapping edits refused");
            await AssertThrowsAsync(() => Call(safe, "edit_file", Obj(("relative_path", "../outside.txt"), ("old_text", "a"), ("new_text", "x"))), "outside", "edit path escape refused");
            await AssertThrowsAsync(() => Call(safe, "edit_file", Obj(("relative_path", "ambiguous.txt"), ("old_text", ""), ("new_text", "x"))), "empty", "empty match refused");
            File.WriteAllBytes(Path.Combine(root, "binary"), [0xff, 0xfe]);
            await AssertThrowsAsync(() => Call(safe, "edit_file", Obj(("relative_path", "binary"), ("old_text", "a"), ("new_text", "x"))), "UTF-8", "invalid UTF8 refused");
            File.WriteAllText(Path.Combine(root, "patch-a.txt"), "alpha\nbeta\n", new UTF8Encoding(false));
            File.WriteAllText(Path.Combine(root, "patch-b.txt"), "one\n", new UTF8Encoding(false));
            var patchChanges = new JsonArray(
                Obj(("relative_path", "patch-a.txt"), ("old_text", "alpha"), ("new_text", "ALPHA")),
                Obj(("relative_path", "patch-a.txt"), ("old_text", "beta"), ("new_text", "BETA")),
                Obj(("relative_path", "patch-b.txt"), ("old_text", "one"), ("new_text", "ONE")));
            var patchPreview = await Call(safe, "apply_patch", Obj(("changes", patchChanges.DeepClone()), ("dry_run", true)));
            Assert(!patchPreview["applied"]!.GetValue<bool>() && patchPreview["file_count"]!.GetValue<int>() == 2 && patchPreview["change_count"]!.GetValue<int>() == 3, "patch preview summary");
            Assert(File.ReadAllText(Path.Combine(root, "patch-a.txt")) == "alpha\nbeta\n", "patch preview does not write");
            var guarded = patchChanges.DeepClone().AsArray();
            guarded[0]!.AsObject()["expected_sha256"] = patchPreview["files"]!.AsArray()[0]!["before_sha256"]!.GetValue<string>();
            await Call(safe, "apply_patch", Obj(("changes", guarded)));
            Assert(File.ReadAllText(Path.Combine(root, "patch-a.txt")) == "ALPHA\nBETA\n" && File.ReadAllText(Path.Combine(root, "patch-b.txt")) == "ONE\n", "multi-file patch applies in order");
            File.WriteAllText(Path.Combine(root, "patch-atomic-a.txt"), "keep-a");
            File.WriteAllText(Path.Combine(root, "patch-atomic-b.txt"), "keep-b");
            await AssertThrowsAsync(() => Call(safe, "apply_patch", Obj(("changes", new JsonArray(
                Obj(("relative_path", "patch-atomic-a.txt"), ("old_text", "keep-a"), ("new_text", "changed-a")),
                Obj(("relative_path", "patch-atomic-b.txt"), ("old_text", "missing"), ("new_text", "changed-b")))))), "not found", "patch validates before writes");
            Assert(File.ReadAllText(Path.Combine(root, "patch-atomic-a.txt")) == "keep-a", "failed patch leaves earlier files untouched");
            var oversizedPatch = new JsonArray();
            for (var index = 0; index < 7; index++)
            {
                var name = $"patch-large-{index}.txt";
                File.WriteAllText(Path.Combine(root, name), new string('x', 4_600_000) + "needle", new UTF8Encoding(false));
                oversizedPatch.Add(Obj(("relative_path", name), ("old_text", "needle"), ("new_text", "done")));
            }
            await AssertThrowsAsync(() => Call(safe, "apply_patch", Obj(("changes", oversizedPatch), ("dry_run", true))), "32 MB aggregate", "patch aggregate budget");
            File.WriteAllText(Path.Combine(root, "AGENTS.md"), "root guidance");
            File.WriteAllText(Path.Combine(root, "nested", "AGENTS.md"), "nested guidance");
            File.WriteAllText(Path.Combine(root, "nested", "package.json"), "{\"scripts\":{\"test\":\"echo test\"}}");
            var context = await Call(safe, "workspace_context", Obj(("path", "nested")));
            Assert(context["files"]!.AsArray().Select(value => value!["path"]!.GetValue<string>()).SequenceEqual(["AGENTS.md", "nested/AGENTS.md", "nested/package.json"]), "scoped instructions and manifests");
            File.WriteAllText(Path.Combine(root, "nested", "AGENTS.md"), new string('x', 20_000));
            context = await Call(safe, "workspace_context", Obj(("path", "nested")));
            Assert(context["files"]!.AsArray()[1]!["truncated"]!.GetValue<bool>(), "context is bounded");
            var args = Obj(("request_id", "stream"), ("command", "[Console]::Write('first'); Start-Sleep -Seconds 2; [Console]::Write('second'); [Console]::Error.Write('error'); exit 7"), ("timeout_seconds", 10));
            var started = await Call(full, "start_command", args);
            var id = started["session_id"]!.GetValue<string>();
            Assert((await Call(full, "start_command", args))["session_id"]!.GetValue<string>() == id, "idempotent retry");
            await AssertThrowsAsync(() => Call(full, "start_command", Obj(("request_id", "stream"), ("command", "exit 0"))), "different", "retry mismatch refused");
            await AssertThrowsAsync(() => Call(full, "edit_file", edit), "active", "mutations wait for job");
            var watch = Stopwatch.StartNew(); JsonObject partial;
            do
            {
                partial = await Call(full, "read_command_output", Obj(("session_id", id)));
                if (partial["output"]!.GetValue<string>().Contains("first")) break;
                await Task.Delay(30);
            } while (watch.Elapsed < TimeSpan.FromSeconds(5));
            Assert(partial["state"]!.GetValue<string>() == "running" && partial["output"]!.GetValue<string>().Contains("first"), "output arrives before exit");
            var completed = await Poll(id, partial["next_cursor"]!.GetValue<int>());
            Assert(completed["exit_code"]!.GetValue<int>() == 7 && completed["output"]!.GetValue<string>().Contains("second") && !completed["output"]!.GetValue<string>().Contains("first"), "cursor and nonzero exit");
            await AssertThrowsAsync(() => Call(full, "read_command_output", Obj(("session_id", id), ("cursor", 999999))), "cursor", "future cursor refused");
            // Verify the same capacity and isolation promises as macOS.
            var sessions = new List<string>();
            for (var n = 0; n < capacity; n++)
            {
                Directory.CreateDirectory(Path.Combine(root, "parallel", $"w{n}"));
                var slot = await Call(full, "start_command", Obj(
                    ("request_id", $"parallel-{n}"), ("command", "Start-Sleep -Seconds 30"),
                    ("cwd", $"parallel/w{n}")));
                Assert(slot["state"]!.GetValue<string>() == "running", "parallel slot admitted");
                sessions.Add(slot["session_id"]!.GetValue<string>());
            }
            Assert(sharedBudget.Status()["active_total"]!.GetValue<int>() == capacity, "all parallel slots occupied");
            Directory.CreateDirectory(Path.Combine(root, "parallel", $"w{capacity}"));
            await AssertThrowsAsync(() => Call(full, "start_command", Obj(
                ("request_id", "parallel-capacity"), ("command", "Start-Sleep -Seconds 30"),
                ("cwd", $"parallel/w{capacity}"))), "limit", "capacity enforced");
            await Call(full, "write_file", Obj(("relative_path", "parallel/free.txt"), ("content", "safe")));
            await AssertThrowsAsync(() => Call(full, "write_file", Obj(("relative_path", "parallel/w0/blocked.txt"), ("content", "blocked"))), "occupies", "overlapping mutation refused");
            await Call(full, "workspace_context", Obj(("path", "parallel")));
            await Call(full, "cancel_command", Obj(("session_id", sessions[0])));
            Assert((await Poll(sessions[0]))["state"]!.GetValue<string>() == "cancelled", "one slot cancelled");
            await AssertThrowsAsync(() => Call(full, "start_command", Obj(
                ("request_id", "parallel-overlap"), ("command", "Start-Sleep -Seconds 30"),
                ("cwd", "parallel/w1"))), "occupies", "cwd conflict refused");
            var replacement = await Call(full, "start_command", Obj(
                ("request_id", "parallel-replacement"), ("command", "Start-Sleep -Seconds 30"),
                ("cwd", $"parallel/w{capacity}")));
            Assert(replacement["state"]!.GetValue<string>() == "running", "released slot reusable");
            for (var n = 1; n < sessions.Count; n++)
                await Call(full, "cancel_command", Obj(("session_id", sessions[n])));
            await Call(full, "cancel_command", Obj(("session_id", replacement["session_id"]!.GetValue<string>())));
            for (var n = 1; n < sessions.Count; n++)
                Assert((await Poll(sessions[n]))["state"]!.GetValue<string>() == "cancelled", "parallel session cancelled");
            Assert((await Poll(replacement["session_id"]!.GetValue<string>()))["state"]!.GetValue<string>() == "cancelled", "replacement cancelled");
            Assert(sharedBudget.Status()["active_total"]!.GetValue<int>() == 0, "parallel capacity released");
            Directory.CreateDirectory(Path.Combine(root, "sync-a"));
            Directory.CreateDirectory(Path.Combine(root, "sync-b"));
            var syncA = Call(full, "run_command", Obj(("command", "Start-Sleep -Seconds 4; Write-Output SYNC_A"), ("cwd", "sync-a")));
            var syncB = Call(full, "run_command", Obj(("command", "Start-Sleep -Seconds 4; Write-Output SYNC_B"), ("cwd", "sync-b")));
            var syncWatch = Stopwatch.StartNew();
            while (sharedBudget.Status()["active_synchronous"]!.GetValue<int>() < 2 && syncWatch.Elapsed < TimeSpan.FromSeconds(3))
                await Task.Delay(25);
            Assert(sharedBudget.Status()["active_synchronous"]!.GetValue<int>() == 2, "two synchronous commands overlapped");
            await AssertThrowsAsync(() => Call(full, "run_command", Obj(("command", "Write-Output nope"), ("cwd", "sync-a"))),
                "occupies", "synchronous cwd overlap refused");
            await Call(full, "write_file", Obj(("relative_path", "nested/independent.txt"), ("content", "safe")));
            await AssertThrowsAsync(() => Call(full, "write_file", Obj(("relative_path", "sync-a/blocked.txt"), ("content", "blocked"))), "occupies", "overlapping mutation blocked during synchronous commands");
            var results = await Task.WhenAll(syncA, syncB);
            Assert(results[0]["result"]!.GetValue<string>().Contains("SYNC_A") &&
                   results[1]["result"]!.GetValue<string>().Contains("SYNC_B"), "parallel results available");
            Assert(sharedBudget.Status()["active_total"]!.GetValue<int>() == 0, "synchronous capacity released");
            Console.WriteLine($"windows-agent-capacity-{capacity}: testing completed output retention");
            var retained = new List<string>();
            var gate = "while (-not (Test-Path release)) { Start-Sleep -Milliseconds 50 }";
            for (var n = 0; n <= capacity; n++)
                Directory.CreateDirectory(Path.Combine(root, $"retained-{n}"));
            try
            {
                for (var n = 0; n < capacity - 1; n++)
                {
                    var held = await Call(full, "start_command", Obj(("request_id", $"retained-{n}"), ("cwd", $"retained-{n}"), ("command", gate)));
                    retained.Add(held["session_id"]!.GetValue<string>());
                }
                var shortDir = $"retained-{capacity - 1}";
                var shortJob = await Call(full, "start_command", Obj(("request_id", shortDir), ("cwd", shortDir), ("command", gate + "; $bytes = [Text.Encoding]::ASCII.GetBytes(('x' * 120000)); $out = [Console]::OpenStandardOutput(); $out.Write($bytes, 0, $bytes.Length); $out.Flush()")));
                var shortId = shortJob["session_id"]!.GetValue<string>();
                File.WriteAllText(Path.Combine(root, shortDir, "release"), "");
                var retainedPage = await Poll(shortId, deadlineSeconds: 30);
                Assert(retainedPage["exit_code"]!.GetValue<int>() == 0, "retention fixture exits successfully");
                Assert(!retainedPage["truncated"]!.GetValue<bool>(), "retention fixture output is not truncated");
                Assert(retainedPage["has_more"]!.GetValue<bool>(), "retained output has more pages");
                var next = await Call(full, "start_command", Obj(("request_id", "retained-replacement"), ("cwd", $"retained-{capacity}"), ("command", gate)));
                retained.Add(next["session_id"]!.GetValue<string>());
                var length = retainedPage["output"]!.GetValue<string>().Length;
                while (retainedPage["has_more"]!.GetValue<bool>())
                {
                    retainedPage = await Call(full, "read_command_output", Obj(("session_id", shortId), ("cursor", retainedPage["next_cursor"]!.GetValue<int>())));
                    length += retainedPage["output"]!.GetValue<string>().Length;
                }
                Assert(length == 120000, $"completed output survives replacement admission (received {length} of 120000 bytes)");
            }
            finally
            {
                for (var n = 0; n <= capacity; n++) File.WriteAllText(Path.Combine(root, $"retained-{n}", "release"), "");
                foreach (var held in retained) await Poll(held, deadlineSeconds: 30);
            }
            Console.WriteLine($"windows-agent-capacity-{capacity}: testing synchronous saturation");
            var synchronous = new List<Task<JsonObject>>();
            for (var n = 0; n < capacity; n++)
            {
                var dir = $"sync-full-{n}";
                Directory.CreateDirectory(Path.Combine(root, dir));
                synchronous.Add(Call(full, "run_command", Obj(("cwd", dir), ("command", gate), ("timeout_seconds", 30))));
            }
            try
            {
                var deadline = Stopwatch.StartNew();
                while (sharedBudget.Status()["active_synchronous"]!.GetValue<int>() < capacity && deadline.Elapsed < TimeSpan.FromSeconds(12))
                    await Task.Delay(50);
                Assert(sharedBudget.Status()["active_synchronous"]!.GetValue<int>() == capacity, "all synchronous slots occupied");
                await Call(full, "list_files").WaitAsync(TimeSpan.FromSeconds(3));
            }
            finally
            {
                for (var n = 0; n < capacity; n++) File.WriteAllText(Path.Combine(root, $"sync-full-{n}", "release"), "");
                await Task.WhenAll(synchronous);
            }
            var cancel = await Call(full, "start_command", Obj(("request_id", "cancel"), ("command", "$child = Start-Process ping.exe -ArgumentList '-t 127.0.0.1' -PassThru -WindowStyle Hidden; $child.Id | Set-Content child.pid; Start-Sleep -Seconds 30")));
            var cancelId = cancel["session_id"]!.GetValue<string>();
            watch.Restart();
            while (!File.Exists(Path.Combine(root, "child.pid")) && watch.Elapsed < TimeSpan.FromSeconds(5)) await Task.Delay(30);
            var pid = int.Parse(File.ReadAllText(Path.Combine(root, "child.pid")).Trim());
            await Call(full, "cancel_command", Obj(("session_id", cancelId)));
            Assert((await Poll(cancelId))["state"]!.GetValue<string>() == "cancelled", "cancel reaches terminal state");
            Assert(!IsProcessRunning(pid), "cancel kills descendants");
            var timeout = await Call(full, "start_command", Obj(("request_id", "timeout"), ("command", "Start-Sleep -Seconds 30"), ("timeout_seconds", 1)));
            Assert((await Poll(timeout["session_id"]!.GetValue<string>()))["state"]!.GetValue<string>() == "timed_out", "timeout state");
            var flood = await Call(full, "start_command", Obj(("request_id", "flood"), ("command", "[Console]::Write(('x' * 1000000))")));
            var floodId = flood["session_id"]!.GetValue<string>(); var page = await Poll(floodId); var total = 0;
            Assert(page["truncated"]!.GetValue<bool>(), "bounded output marks truncation");
            while (true)
            {
                var size = Encoding.UTF8.GetByteCount(page["output"]!.GetValue<string>()); total += size;
                Assert(size <= 65_536, "output page bounded");
                if (!page["has_more"]!.GetValue<bool>()) break;
                page = await Call(full, "read_command_output", Obj(("session_id", floodId), ("cursor", page["next_cursor"]!.GetValue<int>())));
            }
            Assert(total is > 0 and <= 262_144, "retained output bounded");
            for (var n = 0; n < Math.Max(8, capacity); n++)
            {
                var result = await Call(full, "start_command", Obj(("request_id", "retention-" + n), ("command", "exit 0")));
                await Poll(result["session_id"]!.GetValue<string>());
            }
            await AssertThrowsAsync(() => Call(full, "start_command", args), "expired", "evicted retry cannot rerun");
            var stop = await Call(full, "start_command", Obj(("request_id", "shutdown"), ("command", "$PID | Set-Content shutdown.pid; Start-Sleep -Seconds 30")));
            watch.Restart();
            while (!File.Exists(Path.Combine(root, "shutdown.pid")) && watch.Elapsed < TimeSpan.FromSeconds(5)) await Task.Delay(30);
            var stopPid = int.Parse(File.ReadAllText(Path.Combine(root, "shutdown.pid")).Trim());
            full.StopCommandSessions();
            Assert(!IsProcessRunning(stopPid), "runtime shutdown kills process");
            await AssertThrowsAsync(() => Call(full, "start_command", Obj(("request_id", "late"), ("command", "exit 0"))), "stopped", "no jobs after shutdown");
        }
        finally { full.StopCommandSessions(); }
        Console.WriteLine("agent tools: ok");
    }
}
