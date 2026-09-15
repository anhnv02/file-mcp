import Foundation

enum RipgrepError: LocalizedError {
    case unavailable
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "ripgrep (rg) was not found beside FileMCP; search tools are unavailable"
        case let .failed(message):
            return message
        }
    }
}

struct RipgrepOutput {
    let stdout: String
    let timedOut: Bool
    let outputLimited: Bool
    let searchErrors: Int
    let ignoredPaths: [String]
    let diagnosticsLimited: Bool
}

struct RipgrepLine {
    let path: String
    let lineNumber: Int
    let text: String
    let isMatch: Bool
}

/// Runs the bundled ripgrep with a fixed argument set. Callers still validate every returned path.
final class Ripgrep {
    static let environmentOverrideKey = "FILEMCP_RG"
    static let excludedDirectoryNames = [".git", ".venv", "__pycache__", "build", "dist", "node_modules"]
    static let maxFileBytes = 1_000_000
    static let outputLimitBytes = 8_000_000
    static let timeoutSeconds = 30

    let executable: String?
    private let slots = DispatchSemaphore(value: 2)

    init(executable: String? = Ripgrep.locateExecutable()) {
        self.executable = executable
    }

    static func locateExecutable() -> String? {
        if let override = ProcessInfo.processInfo.environment[environmentOverrideKey], !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }
        let sibling = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("rg")
            .path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    /// `arguments` must not contain positional values; `target` is passed after `--`.
    /// `limitFileSize` skips files over `maxFileBytes`; file listings pass false so large files are still reported.
    func run(
        arguments: [String],
        includeIgnored: Bool,
        cwd: String,
        target: String,
        limitFileSize: Bool = true
    ) throws -> RipgrepOutput {
        guard let executable else { throw RipgrepError.unavailable }
        slots.wait()
        defer { slots.signal() }

        let debugEnabled = arguments.contains("--debug")
        var fullArguments = [
            "--no-config", "--hidden", "--no-follow", "--no-ignore-global", "--no-require-git",
            "--engine=default", "--color=never",
        ]
        if limitFileSize {
            fullArguments.append("--max-filesize=\(Ripgrep.maxFileBytes)")
        }
        fullArguments += arguments
        // Exclusions come after caller globs so a caller glob cannot re-include them.
        if includeIgnored {
            fullArguments += ["--no-ignore", "--iglob=!.git/"]
        } else {
            fullArguments += Ripgrep.excludedDirectoryNames.map { "--iglob=!\($0)/" }
        }
        fullArguments += ["--", target]

        let result = try ProcessRunner.run(
            executable: executable,
            arguments: fullArguments,
            cwd: cwd,
            environment: [:],
            timeoutSeconds: Ripgrep.timeoutSeconds,
            outputLimitBytes: Ripgrep.outputLimitBytes
        )

        var stdout = result.stdout
        if result.stdoutTruncated, let marker = stdout.range(of: "\n\n[...truncated ", options: .backwards) {
            stdout = String(stdout[..<marker.lowerBound])
        }
        let stderrLines = result.stderr.split(separator: "\n")
        let errorLines = stderrLines.filter {
            guard $0.hasPrefix("rg: ") else { return false }
            return !debugEnabled || (!$0.hasPrefix("rg: DEBUG|") && !$0.hasPrefix("rg: TRACE|"))
        }
        // Per-path I/O failures ("(os error N)") still produce a usable, partial result.
        // Anything else with exit code 2 (bad regex, unknown type, invalid glob) is a request error.
        let hasOnlyPathErrors = !errorLines.isEmpty && errorLines.allSatisfy { $0.contains("(os error ") }
        if result.exitCode == 2, !result.timedOut, stdout.isEmpty, !hasOnlyPathErrors {
            let message = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw RipgrepError.failed(message.isEmpty ? "ripgrep failed" : message)
        }
        return RipgrepOutput(
            stdout: stdout,
            timedOut: result.timedOut,
            outputLimited: result.stdoutTruncated,
            searchErrors: errorLines.count,
            ignoredPaths: debugEnabled ? Ripgrep.ignoredPaths(from: result.stderr) : [],
            diagnosticsLimited: debugEnabled && result.stderrTruncated
        )
    }

    private static func ignoredPaths(from stderr: String) -> [String] {
        var paths: [String] = []
        for rawLine in stderr.split(separator: "\n") {
            let line = String(rawLine)
            guard let start = line.range(of: ": ignoring "),
                  let end = line.range(of: ": Ignore(", options: .backwards),
                  start.upperBound < end.lowerBound else {
                continue
            }
            let path = normalizedPath(String(line[start.upperBound..<end.lowerBound]).replacingOccurrences(of: "\\", with: "/"))
            if !path.isEmpty { paths.append(path) }
        }
        return paths
    }

    static func normalizedPath(_ value: String) -> String {
        value.hasPrefix("./") ? String(value.dropFirst(2)) : value
    }

    /// Parses `--null` separated paths (from `--files` or `--files-with-matches`).
    static func nulSeparatedPaths(_ output: RipgrepOutput) -> [String] {
        var parts = output.stdout.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        if output.outputLimited, !parts.isEmpty { parts.removeLast() }
        return parts.map(normalizedPath)
    }

    /// Parses `--count --null` output: `path\0count\n` records.
    static func nulSeparatedCounts(_ output: RipgrepOutput) -> [(path: String, count: Int)] {
        var results: [(path: String, count: Int)] = []
        var remainder = Substring(output.stdout)
        while let separator = remainder.firstIndex(of: "\0") {
            let path = String(remainder[..<separator])
            let afterSeparator = remainder[remainder.index(after: separator)...]
            guard let newline = afterSeparator.firstIndex(of: "\n") else { break }
            if let count = Int(afterSeparator[..<newline]) {
                results.append((normalizedPath(path), count))
            }
            remainder = afterSeparator[afterSeparator.index(after: newline)...]
        }
        return results
    }

    /// Parses `--json` match and context events. Multi-line matches are split into one entry per line.
    static func jsonLines(_ output: RipgrepOutput) -> [RipgrepLine] {
        var lines: [RipgrepLine] = []
        for record in output.stdout.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any],
                  let type = object["type"] as? String, type == "match" || type == "context",
                  let data = object["data"] as? [String: Any],
                  let path = jsonText(data["path"]),
                  let text = jsonText(data["lines"]),
                  let lineNumber = (data["line_number"] as? NSNumber)?.intValue else {
                continue
            }
            // Split on LF code units: Swift treats "\r\n" as one Character, so split(separator:) would miss CRLF.
            var parts = text.components(separatedBy: "\n")
            if parts.count > 1, parts.last?.isEmpty == true { parts.removeLast() }
            for (offset, part) in parts.enumerated() {
                let clean = part.unicodeScalars.last == "\r" ? String(String.UnicodeScalarView(part.unicodeScalars.dropLast())) : part
                lines.append(RipgrepLine(
                    path: normalizedPath(path),
                    lineNumber: lineNumber + offset,
                    text: clean,
                    isMatch: type == "match"
                ))
            }
        }
        return lines
    }

    private static func jsonText(_ value: Any?) -> String? {
        guard let object = value as? [String: Any] else { return nil }
        if let text = object["text"] as? String { return text }
        if let encoded = object["bytes"] as? String, let data = Data(base64Encoded: encoded) {
            return String(decoding: data, as: UTF8.self)
        }
        return nil
    }
}
