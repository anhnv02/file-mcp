// Compiled in the server file so these tests exercise the real private tool dispatcher.
func runAgentToolChecks(rootPath: String) throws {
    func check(_ condition: Bool, line: Int = #line) { precondition(condition, "Failed at fixture line \(line)") }
    let root = URL(fileURLWithPath: rootPath)
    let resolver = try SafePathResolver(rootPath: rootPath)
    let safe = LocalTools(resolver: resolver, gitUserName: "Test", gitUserEmail: "test@example.invalid", enableCommands: false)
    let full = LocalTools(resolver: resolver, gitUserName: "Test", gitUserEmail: "test@example.invalid", enableCommands: true)
    defer { full.stopCommandSessions() }
    func call(_ tools: LocalTools, _ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        let result = try tools.call(name: name, arguments: args).structuredContent
        precondition(JSONSerialization.isValidJSONObject(result))
        return result
    }
    func rejects(_ label: String, _ operation: () throws -> Void) {
        do { try operation(); fatalError("Expected rejection: \(label)") } catch { print("PASS reject: \(label)") }
    }
    func write(_ path: String, _ text: String) throws {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }
    func poll(_ id: String, cursor: Int = 0, deadline: TimeInterval = 8) throws -> [String: Any] {
        let end = Date().addingTimeInterval(deadline)
        while Date() < end {
            let result = try call(full, "read_command_output", ["session_id": id, "cursor": cursor])
            if !["running", "stopping"].contains(result["state"] as! String) { return result }
            Thread.sleep(forTimeInterval: 0.03)
        }
        fatalError("Session did not finish")
    }
    check(safe.toolDefinitions.count == 22 && full.toolDefinitions.count == 26)
    check(safe.hasTool(named: "apply_patch") && !safe.hasTool(named: "start_command") && !safe.hasTool(named: "read_command_output"))
    rejects("disabled commands") { _ = try call(safe, "start_command", ["request_id": "disabled", "command": "true"]) }
    try write("nested/code.txt", "héllo 👋\r\nkeep\r\n")
    let edit: [String: Any] = ["relative_path": "nested/code.txt", "old_text": "héllo 👋", "new_text": "xin chào", "dry_run": true]
    let preview = try call(safe, "edit_file", edit)
    check(preview["applied"] as? Bool == false)
    check(try String(contentsOf: root.appendingPathComponent("nested/code.txt"), encoding: .utf8) == "héllo 👋\r\nkeep\r\n")
    var apply = edit; apply["dry_run"] = false; apply["expected_sha256"] = preview["before_sha256"]
    _ = try call(safe, "edit_file", apply)
    check(try String(contentsOf: root.appendingPathComponent("nested/code.txt"), encoding: .utf8) == "xin chào\r\nkeep\r\n")
    rejects("stale hash") { _ = try call(safe, "edit_file", apply) }
    rejects("missing text") { _ = try call(safe, "edit_file", ["relative_path": "nested/code.txt", "old_text": "missing", "new_text": "bad"]) }
    try write("ambiguous.txt", "aaa")
    rejects("overlapping matches") { _ = try call(safe, "edit_file", ["relative_path": "ambiguous.txt", "old_text": "aa", "new_text": "x"]) }
    rejects("empty old text") { _ = try call(safe, "edit_file", ["relative_path": "ambiguous.txt", "old_text": "", "new_text": "x"]) }
    rejects("escape path") { _ = try call(safe, "edit_file", ["relative_path": "../outside.txt", "old_text": "a", "new_text": "x"]) }
    try Data([0xff, 0xfe]).write(to: root.appendingPathComponent("binary"))
    rejects("invalid UTF8") { _ = try call(safe, "edit_file", ["relative_path": "binary", "old_text": "a", "new_text": "x"]) }
    try write("patch-a.txt", "alpha\nbeta\n")
    try write("patch-b.txt", "one\n")
    let patchChanges: [[String: Any]] = [
        ["relative_path": "patch-a.txt", "old_text": "alpha", "new_text": "ALPHA"],
        ["relative_path": "patch-a.txt", "old_text": "beta", "new_text": "BETA"],
        ["relative_path": "patch-b.txt", "old_text": "one", "new_text": "ONE"],
    ]
    let patchPreview = try call(safe, "apply_patch", ["changes": patchChanges, "dry_run": true])
    check(patchPreview["applied"] as? Bool == false && patchPreview["file_count"] as? Int == 2 && patchPreview["change_count"] as? Int == 3)
    check(try String(contentsOf: root.appendingPathComponent("patch-a.txt"), encoding: .utf8) == "alpha\nbeta\n")
    var guardedChanges = patchChanges
    let patchFiles = patchPreview["files"] as! [[String: Any]]
    guardedChanges[0]["expected_sha256"] = patchFiles[0]["before_sha256"]
    _ = try call(safe, "apply_patch", ["changes": guardedChanges])
    check(try String(contentsOf: root.appendingPathComponent("patch-a.txt"), encoding: .utf8) == "ALPHA\nBETA\n")
    check(try String(contentsOf: root.appendingPathComponent("patch-b.txt"), encoding: .utf8) == "ONE\n")
    try write("patch-atomic-a.txt", "keep-a")
    try write("patch-atomic-b.txt", "keep-b")
    rejects("patch validates before writes") {
        _ = try call(safe, "apply_patch", ["changes": [
            ["relative_path": "patch-atomic-a.txt", "old_text": "keep-a", "new_text": "changed-a"],
            ["relative_path": "patch-atomic-b.txt", "old_text": "missing", "new_text": "changed-b"],
        ]])
    }
    check(try String(contentsOf: root.appendingPathComponent("patch-atomic-a.txt"), encoding: .utf8) == "keep-a")
    var oversizedPatch: [[String: Any]] = []
    for index in 0..<7 {
        let name = "patch-large-\(index).txt"
        try write(name, String(repeating: "x", count: 4_600_000) + "needle")
        oversizedPatch.append(["relative_path": name, "old_text": "needle", "new_text": "done"])
    }
    rejects("patch aggregate budget") { _ = try call(safe, "apply_patch", ["changes": oversizedPatch, "dry_run": true]) }
    try write("AGENTS.md", "root guidance")
    try write("nested/AGENTS.md", "nested guidance")
    try write("nested/package.json", "{\"scripts\":{\"test\":\"echo test\"}}")
    let context = try call(safe, "workspace_context", ["path": "nested"])
    let files = context["files"] as! [[String: Any]]
    check(files.map { $0["path"] as! String } == ["AGENTS.md", "nested/AGENTS.md", "nested/package.json"])
    check(context["cwd"] as? String == "nested")
    try write("nested/AGENTS.md", String(repeating: "x", count: 20_000))
    let bounded = try call(safe, "workspace_context", ["path": "nested"])
    check((bounded["files"] as! [[String: Any]])[1]["truncated"] as? Bool == true)
    let outside = root.deletingLastPathComponent().appendingPathComponent("outside.txt")
    try Data("PRIVATE OUTSIDE".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("outside-link").path, withDestinationPath: outside.path)
    rejects("symlink edit escape") { _ = try call(safe, "edit_file", ["relative_path": "outside-link", "old_text": "PRIVATE", "new_text": "LEAK"]) }
    try FileManager.default.removeItem(at: root.appendingPathComponent("nested/AGENTS.md"))
    try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("nested/AGENTS.md").path, withDestinationPath: outside.path)
    let escaped = try call(safe, "workspace_context", ["path": "nested"])
    check(!String(describing: escaped).contains("PRIVATE OUTSIDE"))
    print("PASS: edit preview/apply/Unicode/CRLF and scoped bounded context")

    let args: [String: Any] = ["request_id": "stream", "command": "printf first; sleep 1; printf second; printf error >&2; exit 7", "timeout_seconds": 10]
    let started = try call(full, "start_command", args)
    let id = started["session_id"] as! String
    check(try call(full, "start_command", args)["session_id"] as? String == id)
    rejects("retry key mismatch") { _ = try call(full, "start_command", ["request_id": "stream", "command": "true"]) }
    rejects("mutation while command active") { _ = try call(full, "edit_file", edit) }
    rejects("second session while active") { _ = try call(full, "start_command", ["request_id": "second", "command": "true"]) }
    Thread.sleep(forTimeInterval: 0.25)
    let partial = try call(full, "read_command_output", ["session_id": id])
    check(partial["state"] as? String == "running" && (partial["output"] as! String).contains("first"))
    let cursor = partial["next_cursor"] as! Int
    let completed = try poll(id, cursor: cursor)
    check(completed["exit_code"] as? Int32 == 7)
    check((completed["output"] as! String).contains("second") && !(completed["output"] as! String).contains("first"))
    check(try call(full, "read_command_output", ["session_id": id, "cursor": completed["next_cursor"]!])["output"] as? String == "")
    rejects("future cursor") { _ = try call(full, "read_command_output", ["session_id": id, "cursor": 99999]) }
    let cancel = try call(full, "start_command", ["request_id": "cancel", "command": "sleep 30 & echo $! > child.pid; wait"])
    let cancelID = cancel["session_id"] as! String
    Thread.sleep(forTimeInterval: 0.2)
    _ = try call(full, "cancel_command", ["session_id": cancelID])
    check(try poll(cancelID)["state"] as? String == "cancelled")
    let pid = Int32(try String(contentsOf: root.appendingPathComponent("child.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    check(kill(pid, 0) == -1 && errno == ESRCH)
    let timeout = try call(full, "start_command", ["request_id": "timeout", "command": "sleep 30", "timeout_seconds": 1])
    check(try poll(timeout["session_id"] as! String)["state"] as? String == "timed_out")
    let flood = try call(full, "start_command", ["request_id": "flood", "command": "head -c 1000000 /dev/zero | tr '\\0' x"])
    let floodID = flood["session_id"] as! String
    var page = try poll(floodID)
    check(page["truncated"] as? Bool == true)
    var total = 0
    repeat {
        total += (page["output"] as! String).utf8.count
        check((page["output"] as! String).utf8.count <= 65_536)
        if page["has_more"] as? Bool == false { break }
        page = try call(full, "read_command_output", ["session_id": floodID, "cursor": page["next_cursor"]!])
    } while true
    check(total <= 262_144 && total > 0)
    // Fill retention, then ensure retrying an evicted key cannot execute it again.
    for n in 0..<8 {
        let result = try call(full, "start_command", ["request_id": "retention-\(n)", "command": "true"])
        _ = try poll(result["session_id"] as! String)
    }
    rejects("evicted retry key") { _ = try call(full, "start_command", args) }
    let shutdown = try call(full, "start_command", ["request_id": "shutdown", "command": "sleep 30 & echo $! > shutdown.pid; wait"])
    Thread.sleep(forTimeInterval: 0.2)
    full.stopCommandSessions()
    _ = try poll(shutdown["session_id"] as! String)
    let stoppedPID = Int32(try String(contentsOf: root.appendingPathComponent("shutdown.pid"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
    check(kill(stoppedPID, 0) == -1 && errno == ESRCH)
    rejects("start after shutdown") { _ = try call(full, "start_command", ["request_id": "late", "command": "true"]) }
    print("PASS: command streaming/cursors/exit status/retries/bounds/cancel/timeout/descendant cleanup/shutdown")
}
