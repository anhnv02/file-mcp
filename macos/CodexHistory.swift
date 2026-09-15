import Foundation
import Darwin

struct CodexHistoryMessage {
    let role: String
    let content: String
}

struct CodexHistoryImportResult {
    let threadID: String
    let title: String
    let messageCount: Int
    let turnCount: Int
}

enum CodexHistoryError: LocalizedError {
    case unavailable(String)
    case protocolFailure(String)
    case timedOut(String)

    var errorDescription: String? {
        switch self {
        case let .unavailable(message), let .protocolFailure(message), let .timedOut(message):
            return message
        }
    }
}

final class CodexHistoryImporter {
    static func save(
        title: String,
        cwd: URL,
        messages: [CodexHistoryMessage]
    ) throws -> CodexHistoryImportResult {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty, normalizedTitle.utf8.count <= 500 else {
            throw CodexHistoryError.protocolFailure("Codex thread title is empty or too long.")
        }
        guard !messages.isEmpty, messages.count <= 500, messages.first?.role == "user" else {
            throw CodexHistoryError.protocolFailure(
                "Codex conversation must contain 1...500 messages and start with a user message."
            )
        }
        var totalBytes = 0
        for message in messages {
            guard message.role == "user" || message.role == "assistant", !message.content.isEmpty else {
                throw CodexHistoryError.protocolFailure(
                    "Codex conversation contains an invalid role or empty message."
                )
            }
            totalBytes += message.content.utf8.count
            guard totalBytes <= 2_000_000 else {
                throw CodexHistoryError.protocolFailure("Codex conversation exceeds the 2 MB limit.")
            }
        }

        let codexURL = try locateCodexExecutable()
        let turns = conversationTurns(from: messages)
        let creator = try CodexAppServerClient(executableURL: codexURL)
        var threadID = ""
        var rolloutPath = ""
        var codexHome = ""

        do {
            codexHome = try creator.initialize()
            let start = try creator.request(
                method: "thread/start",
                params: [
                    "cwd": cwd.path,
                    "ephemeral": false,
                    "historyMode": "legacy",
                ]
            )
            guard let thread = start["thread"] as? [String: Any],
                  let id = thread["id"] as? String, !id.isEmpty,
                  let path = thread["path"] as? String, !path.isEmpty else {
                throw CodexHistoryError.protocolFailure(
                    "Codex thread/start did not return a durable thread id and rollout path."
                )
            }
            threadID = id
            rolloutPath = path

            _ = try creator.request(
                method: "thread/name/set",
                params: ["threadId": threadID, "name": normalizedTitle]
            )
            creator.close()

            let rolloutURL = try validatedRolloutURL(
                rolloutPath: rolloutPath,
                codexHome: codexHome,
                threadID: threadID
            )
            try appendConversationTurns(turns, to: rolloutURL)
            try verifyConversation(
                executableURL: codexURL,
                threadID: threadID,
                cwd: cwd.path,
                expectedTurns: turns
            )
        } catch {
            creator.close()
            if !threadID.isEmpty {
                bestEffortDeleteThread(executableURL: codexURL, threadID: threadID)
            }
            bestEffortRemoveRolloutFile(
                rolloutPath: rolloutPath,
                codexHome: codexHome,
                threadID: threadID
            )
            throw error
        }

        return CodexHistoryImportResult(
            threadID: threadID,
            title: normalizedTitle,
            messageCount: messages.count,
            turnCount: turns.count
        )
    }

    private static func conversationTurns(
        from messages: [CodexHistoryMessage]
    ) -> [(user: String, assistants: [String])] {
        var turns: [(user: String, assistants: [String])] = []
        var currentUser: String?
        var assistants: [String] = []

        for message in messages {
            if message.role == "user" {
                if let user = currentUser {
                    turns.append((user, assistants))
                }
                currentUser = message.content
                assistants = []
            } else if currentUser != nil {
                assistants.append(message.content)
            }
        }
        if let user = currentUser {
            turns.append((user, assistants))
        }
        return turns
    }

    private static func appendConversationTurns(
        _ turns: [(user: String, assistants: [String])],
        to rolloutURL: URL
    ) throws {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let baseDate = Date()
        var output = Data()

        for (offset, turn) in turns.enumerated() {
            let turnID = UUID().uuidString.lowercased()
            let turnDate = baseDate.addingTimeInterval(Double(offset) * 0.01)
            let timestamp = formatter.string(from: turnDate)
            let startedAt = Int(turnDate.timeIntervalSince1970)
            let completedAt = startedAt + 1

            var records: [[String: Any]] = [
                [
                    "timestamp": timestamp,
                    "type": "event_msg",
                    "payload": [
                        "type": "task_started",
                        "turn_id": turnID,
                        "started_at": startedAt,
                    ],
                ],
                [
                    "timestamp": timestamp,
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "id": messageID(),
                        "role": "user",
                        "content": [["type": "input_text", "text": turn.user]],
                        "internal_chat_message_metadata_passthrough": [
                            "turn_id": turnID,
                            "create_time": turnDate.timeIntervalSince1970,
                        ],
                    ],
                ],
                [
                    "timestamp": timestamp,
                    "type": "event_msg",
                    "payload": [
                        "type": "user_message",
                        "message": turn.user,
                        "images": [],
                        "local_images": [],
                        "audio": [],
                        "local_audio": [],
                        "text_elements": [],
                    ],
                ],
            ]

            for (index, assistant) in turn.assistants.enumerated() {
                let phase = index == turn.assistants.count - 1 ? "final_answer" : "commentary"
                records.append([
                    "timestamp": timestamp,
                    "type": "response_item",
                    "payload": [
                        "type": "message",
                        "id": messageID(),
                        "role": "assistant",
                        "content": [["type": "output_text", "text": assistant]],
                        "phase": phase,
                        "internal_chat_message_metadata_passthrough": ["turn_id": turnID],
                    ],
                ])
                records.append([
                    "timestamp": timestamp,
                    "type": "event_msg",
                    "payload": [
                        "type": "agent_message",
                        "message": assistant,
                    ],
                ])
            }

            records.append([
                "timestamp": timestamp,
                "type": "event_msg",
                "payload": [
                    "type": "task_complete",
                    "turn_id": turnID,
                    "last_agent_message": turn.assistants.last ?? NSNull(),
                    "error": NSNull(),
                    "started_at": startedAt,
                    "completed_at": completedAt,
                    "duration_ms": 1_000,
                ],
            ])

            for record in records {
                guard JSONSerialization.isValidJSONObject(record) else {
                    throw CodexHistoryError.protocolFailure("Could not serialize a Codex history record.")
                }
                output.append(try JSONSerialization.data(withJSONObject: record, options: []))
                output.append(0x0A)
            }
        }

        let handle = try FileHandle(forWritingTo: rolloutURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: output)
        try handle.synchronize()
    }

    private static func verifyConversation(
        executableURL: URL,
        threadID: String,
        cwd: String,
        expectedTurns: [(user: String, assistants: [String])]
    ) throws {
        let verifier = try CodexAppServerClient(executableURL: executableURL)
        defer { verifier.close() }
        _ = try verifier.initialize()

        let listed = try verifier.request(
            method: "thread/list",
            params: [
                "cwd": cwd,
                "limit": 100,
                "useStateDbOnly": false,
            ]
        )
        guard let threads = listed["data"] as? [[String: Any]],
              threads.contains(where: { $0["id"] as? String == threadID }) else {
            throw CodexHistoryError.protocolFailure(
                "Codex did not index the imported conversation under the requested working directory."
            )
        }

        _ = try verifier.request(method: "thread/resume", params: ["threadId": threadID])
        let result = try verifier.request(
            method: "thread/turns/list",
            params: [
                "threadId": threadID,
                "limit": 500,
                "itemsView": "full",
                "sortDirection": "asc",
            ]
        )
        guard let actualTurns = result["data"] as? [[String: Any]],
              actualTurns.count == expectedTurns.count else {
            throw CodexHistoryError.protocolFailure("Codex could not hydrate all imported conversation turns.")
        }

        for (turnIndex, expectedTurn) in expectedTurns.enumerated() {
            let actualTurn = actualTurns[turnIndex]
            guard actualTurn["status"] as? String == "completed",
                  let items = actualTurn["items"] as? [[String: Any]] else {
                throw CodexHistoryError.protocolFailure(
                    "Codex hydrated turn \(turnIndex + 1) with an unexpected status or item shape."
                )
            }

            var actualMessages: [CodexHistoryMessage] = []
            for item in items {
                switch item["type"] as? String {
                case "userMessage":
                    guard let content = item["content"] as? [[String: Any]],
                          let textItem = content.first(where: { $0["type"] as? String == "text" }),
                          let text = textItem["text"] as? String else {
                        throw CodexHistoryError.protocolFailure(
                            "Codex hydrated an invalid user message in turn \(turnIndex + 1)."
                        )
                    }
                    actualMessages.append(CodexHistoryMessage(role: "user", content: text))
                case "agentMessage":
                    guard let text = item["text"] as? String else {
                        throw CodexHistoryError.protocolFailure(
                            "Codex hydrated an invalid assistant message in turn \(turnIndex + 1)."
                        )
                    }
                    actualMessages.append(CodexHistoryMessage(role: "assistant", content: text))
                default:
                    continue
                }
            }

            let expectedMessages = [CodexHistoryMessage(role: "user", content: expectedTurn.user)]
                + expectedTurn.assistants.map { CodexHistoryMessage(role: "assistant", content: $0) }
            guard actualMessages.count == expectedMessages.count else {
                throw CodexHistoryError.protocolFailure(
                    "Codex hydrated the wrong number of messages in turn \(turnIndex + 1)."
                )
            }
            for messageIndex in expectedMessages.indices {
                guard actualMessages[messageIndex].role == expectedMessages[messageIndex].role,
                      actualMessages[messageIndex].content == expectedMessages[messageIndex].content else {
                    throw CodexHistoryError.protocolFailure(
                        "Codex changed imported message content in turn \(turnIndex + 1)."
                    )
                }
            }
        }
    }

    private static func validatedRolloutURL(
        rolloutPath: String,
        codexHome: String,
        threadID: String
    ) throws -> URL {
        let canonicalURL = try safeRolloutURL(
            rolloutPath: rolloutPath,
            codexHome: codexHome,
            threadID: threadID
        )
        try validateSessionMetadata(at: canonicalURL, threadID: threadID)
        return canonicalURL
    }

    private static func safeRolloutURL(
        rolloutPath: String,
        codexHome: String,
        threadID: String
    ) throws -> URL {
        guard !rolloutPath.isEmpty, !codexHome.isEmpty, !threadID.isEmpty else {
            throw CodexHistoryError.protocolFailure("Codex rollout identity is incomplete.")
        }
        let homeURL = URL(
            fileURLWithPath: NSString(string: codexHome).expandingTildeInPath,
            isDirectory: true
        ).resolvingSymlinksInPath().standardizedFileURL
        let sessionsURL = homeURL.appendingPathComponent("sessions", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let declaredURL = URL(fileURLWithPath: rolloutPath).standardizedFileURL

        var info = stat()
        guard declaredURL.path.withCString({ lstat($0, &info) }) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw CodexHistoryError.protocolFailure("Codex rollout path is not a regular file.")
        }

        let canonicalURL = declaredURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalURL.path.hasPrefix(sessionsURL.path + "/") else {
            throw CodexHistoryError.protocolFailure("Codex returned a rollout path outside codexHome/sessions.")
        }
        guard canonicalURL.lastPathComponent.contains(threadID) else {
            throw CodexHistoryError.protocolFailure("Codex rollout filename does not match the created thread id.")
        }
        return canonicalURL
    }

    private static func validateSessionMetadata(at rolloutURL: URL, threadID: String) throws {
        let handle = try FileHandle(forReadingFrom: rolloutURL)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 1_000_000) ?? Data()
        guard let newline = prefix.firstIndex(of: 0x0A) else {
            throw CodexHistoryError.protocolFailure(
                "Codex rollout is missing a complete session metadata record."
            )
        }
        let firstLine = Data(prefix[..<newline])
        guard let record = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              record["type"] as? String == "session_meta",
              let payload = record["payload"] as? [String: Any] else {
            throw CodexHistoryError.protocolFailure(
                "Codex rollout does not start with a valid session metadata record."
            )
        }
        let sessionID = payload["session_id"] as? String ?? payload["id"] as? String
        guard sessionID == threadID else {
            throw CodexHistoryError.protocolFailure(
                "Codex session metadata does not match the created thread id."
            )
        }
    }

    private static func bestEffortRemoveRolloutFile(
        rolloutPath: String,
        codexHome: String,
        threadID: String
    ) {
        guard let url = try? safeRolloutURL(
            rolloutPath: rolloutPath,
            codexHome: codexHome,
            threadID: threadID
        ) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func bestEffortDeleteThread(executableURL: URL, threadID: String) {
        guard let client = try? CodexAppServerClient(executableURL: executableURL) else { return }
        defer { client.close() }
        guard (try? client.initialize()) != nil else { return }
        _ = try? client.request(method: "thread/delete", params: ["threadId": threadID])
    }

    private static func locateCodexExecutable() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [String] = []

        if let configured = ProcessInfo.processInfo.environment["CODEX_BIN"], !configured.isEmpty {
            candidates.append(NSString(string: configured).expandingTildeInPath)
        }
        candidates.append("/Applications/ChatGPT.app/Contents/Resources/codex")
        candidates.append("/Applications/Codex.app/Contents/Resources/codex")

        if let path = ProcessInfo.processInfo.environment["PATH"] {
            for directory in path.split(separator: ":", omittingEmptySubsequences: true) {
                candidates.append(URL(fileURLWithPath: String(directory)).appendingPathComponent("codex").path)
            }
        }

        for candidate in candidates where fileManager.isExecutableFile(atPath: candidate) {
            return URL(fileURLWithPath: candidate)
        }
        throw CodexHistoryError.unavailable(
            "Codex executable was not found. Install ChatGPT/Codex or set CODEX_BIN to its executable path."
        )
    }

    private static func messageID() -> String {
        "msg_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

private final class CodexAppServerClient {
    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var responses: [Int: [String: Any]] = [:]
    private var stderrData = Data()
    private var nextRequestID = 1
    private var closed = false

    init(executableURL: URL) throws {
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw CodexHistoryError.unavailable(
                "Could not start Codex app-server: \(error.localizedDescription)"
            )
        }

        let stderrFD = stderrPipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(stderrFD, F_GETFL)
        if flags >= 0 {
            _ = fcntl(stderrFD, F_SETFL, flags | O_NONBLOCK)
        }
    }

    deinit {
        close()
    }

    func initialize() throws -> String {
        let result = try request(
            method: "initialize",
            params: [
                "clientInfo": ["name": "filemcp", "version": "0.4.0"],
                "capabilities": ["experimentalApi": true],
            ],
            timeoutSeconds: 15
        )
        guard let codexHome = result["codexHome"] as? String, !codexHome.isEmpty else {
            throw CodexHistoryError.protocolFailure("Codex initialize did not return codexHome.")
        }
        try notify(method: "initialized", params: [:])
        return codexHome
    }

    func request(
        method: String,
        params: [String: Any],
        timeoutSeconds: TimeInterval = 20
    ) throws -> [String: Any] {
        let id = nextRequestID
        nextRequestID += 1
        try writeJSON([
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        ])

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while responses[id] == nil {
            try readAvailableResponses(until: deadline, method: method)
        }

        guard let response = responses.removeValue(forKey: id) else {
            throw CodexHistoryError.protocolFailure("Codex lost the response for \(method).")
        }
        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "Unknown Codex app-server error"
            throw CodexHistoryError.protocolFailure("Codex \(method) failed: \(message)")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw CodexHistoryError.protocolFailure("Codex \(method) returned an invalid result.")
        }
        return result
    }

    func notify(method: String, params: [String: Any]) throws {
        try writeJSON([
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        ])
    }

    func close() {
        if closed { return }
        closed = true
        try? stdinPipe.fileHandleForWriting.close()

        let deadline = Date().addingTimeInterval(2)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }

    private func writeJSON(_ object: [String: Any]) throws {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw CodexHistoryError.protocolFailure("Could not serialize a Codex app-server request.")
        }
        var data = try JSONSerialization.data(withJSONObject: object, options: [])
        data.append(0x0A)

        let fd = stdinPipe.fileHandleForWriting.fileDescriptor
        var written = 0
        while written < data.count {
            let count = data.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: written), data.count - written)
            }
            if count > 0 {
                written += count
                continue
            }
            if count < 0 && errno == EINTR { continue }
            throw CodexHistoryError.protocolFailure(
                "Could not write to Codex app-server: \(String(cString: strerror(errno)))"
            )
        }
    }

    private func readAvailableResponses(until deadline: Date, method: String) throws {
        drainStderr()
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else {
            throw CodexHistoryError.timedOut(
                "Timed out waiting for Codex app-server method \(method)." + stderrSuffix()
            )
        }

        let stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        var descriptor = pollfd(fd: stdoutFD, events: Int16(POLLIN | POLLHUP), revents: 0)
        let timeoutMs = Int32(max(1, min(500, Int(remaining * 1_000))))
        let pollResult = withUnsafeMutablePointer(to: &descriptor) { pointer in
            poll(pointer, 1, timeoutMs)
        }
        if pollResult < 0 {
            if errno == EINTR { return }
            throw CodexHistoryError.protocolFailure(
                "Could not poll Codex stdout: \(String(cString: strerror(errno)))"
            )
        }
        if pollResult == 0 { return }
        if descriptor.revents & Int16(POLLERR | POLLNVAL) != 0 {
            throw CodexHistoryError.protocolFailure("Codex app-server stdout pipe failed while waiting for \(method).")
        }

        if descriptor.revents & Int16(POLLIN | POLLHUP) != 0 {
            var bytes = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(stdoutFD, &bytes, bytes.count)
            if count > 0 {
                stdoutBuffer.append(bytes, count: count)
                try parseBufferedResponses()
                return
            }
            if count == 0 {
                drainStderr()
                throw CodexHistoryError.protocolFailure(
                    "Codex app-server exited before replying to \(method)." + stderrSuffix()
                )
            }
            if errno != EINTR && errno != EAGAIN {
                throw CodexHistoryError.protocolFailure(
                    "Could not read Codex stdout: \(String(cString: strerror(errno)))"
                )
            }
        }
    }

    private func parseBufferedResponses() throws {
        while let newline = stdoutBuffer.firstIndex(of: 0x0A) {
            let line = Data(stdoutBuffer[..<newline])
            stdoutBuffer.removeSubrange(...newline)
            if line.isEmpty { continue }

            let object: [String: Any]
            do {
                guard let parsed = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    continue
                }
                object = parsed
            } catch {
                throw CodexHistoryError.protocolFailure(
                    "Could not parse a Codex response: \(error.localizedDescription)"
                )
            }
            guard let id = object["id"] as? NSNumber else { continue }
            responses[id.intValue] = object
        }
    }

    private func drainStderr() {
        let fd = stderrPipe.fileHandleForReading.fileDescriptor
        while stderrData.count < 32_000 {
            var bytes = [UInt8](repeating: 0, count: min(8_192, 32_000 - stderrData.count))
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count > 0 {
                stderrData.append(bytes, count: count)
                continue
            }
            break
        }
    }

    private func stderrSuffix() -> String {
        let text = String(decoding: stderrData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "" : " Codex stderr: \(text)"
    }
}
