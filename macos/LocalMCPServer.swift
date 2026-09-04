import Foundation
import CoreFoundation
import Network
import Darwin

private let mcpProtocolFallback = "2025-03-26"
private let mcpLatestLegacyProtocolVersion = "2025-11-25"
private let mcpModernProtocolVersion = "2026-07-28"
private let mcpLegacySupportedVersions = ["2025-03-26", "2025-06-18", "2025-11-25"]
private let mcpAllSupportedVersions = [mcpModernProtocolVersion] + mcpLegacySupportedVersions.reversed()
private let mcpServerName = "filemcp"
private let mcpServerVersion = "0.4.0-swift"
private let maxFileBytes = 5_000_000
private let maxWriteBytes = 5_000_000
private let maxCharsReturned = 40_000
private let maxListEntries = 1_000
private let maxSearchResults = 200
private let maxSearchVisited = 50_000
private let maxSearchContentResults = 50
private let maxSearchContentFileBytes = 1_000_000
private let maxSearchContentBytesScanned = 50_000_000
private let maxSearchPreviewLineChars = 1_000
private let maxSearchPreviewChars = 60_000
private let maxReadRangeLines = 1_000
private let maxReadRangeChars = 80_000
private let maxToolProcessOutputBytes = 100_000
private let maxGitSafetyOutputBytes = 2_000_000
private let maxHTTPRequestHeaderBytes = 64_000
private let maxHTTPRequestBodyBytes = 8_000_000
let fileMCPLocalAuthHeaderName = "X-FileMCP-Local-Token"
private let fileMCPLocalAuthHeaderKey = fileMCPLocalAuthHeaderName.lowercased()
private let unauthenticatedOAuthDiscoveryPaths: Set<String> = [
    "/.well-known/oauth-protected-resource/mcp",
    "/.well-known/oauth-protected-resource",
]
private let singleValueHTTPRequestHeaders: Set<String> = [
    "content-length", "content-type", "host", "origin",
    "mcp-protocol-version", "mcp-method", "mcp-name", "transfer-encoding",
    fileMCPLocalAuthHeaderKey,
]

private enum MCPServerError: LocalizedError {
    case invalidPath(String)
    case invalidArguments(String)
    case notFound(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case let .invalidPath(message), let .invalidArguments(message), let .notFound(message), let .operationFailed(message):
            return message
        }
    }
}

private final class SafePathResolver {
    let root: URL
    private let rootPath: String

    init(rootPath: String) throws {
        let expanded = NSString(string: rootPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let canonicalRoot = url.resolvingSymlinksInPath().standardizedFileURL
        root = canonicalRoot
        self.rootPath = canonicalRoot.path
    }

    func resolve(_ relativePath: String) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonicalCandidate = canonicalizeExistingAncestor(of: candidate)
        guard containsCanonicalPath(canonicalCandidate.path) else {
            throw MCPServerError.invalidPath("Refused: path is outside the shared directory")
        }
        return canonicalCandidate
    }

    func contains(_ url: URL) -> Bool {
        containsCanonicalPath(canonicalizeExistingAncestor(of: url.standardizedFileURL).path)
    }

    func resolveForDeletion(_ relativePath: String) throws -> URL {
        let lexicalTarget = root.appendingPathComponent(relativePath).standardizedFileURL
        if lexicalTarget.path == root.path { return root }
        let parent = canonicalizeExistingAncestor(of: lexicalTarget.deletingLastPathComponent())
        guard containsCanonicalPath(parent.path) else {
            throw MCPServerError.invalidPath("Refused: path is outside the shared directory")
        }
        return parent.appendingPathComponent(lexicalTarget.lastPathComponent).standardizedFileURL
    }

    private func containsCanonicalPath(_ path: String) -> Bool {
        path == rootPath || path.hasPrefix(rootPath + "/")
    }

    private func canonicalizeExistingAncestor(of url: URL) -> URL {
        var ancestor = url
        var suffix: [String] = []

        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }

        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL
    }
}

private enum LocalToolOutputShape {
    case string
    case stringArray
    case object([String: Any])
}

private struct LocalToolCallOutput {
    let content: [[String: Any]]
    let structuredContent: [String: Any]
}

private final class LocalTools {
    private let resolver: SafePathResolver
    private let gitUserName: String
    private let gitUserEmail: String
    private let enableCommands: Bool
    private let toolSlots = DispatchSemaphore(value: 8)
    private let mutationSlot = DispatchSemaphore(value: 1)
    private let commandSlots = DispatchSemaphore(value: 2)
    private let gitSlots = DispatchSemaphore(value: 3)
    private let serializedToolNames: Set<String> = [
        "write_file", "delete_file", "delete_directory", "run_command",
        "git_init", "git_status", "git_log", "git_diff", "git_add", "git_commit", "git_push",
    ]
    private let skippedSearchDirectories: Set<String> = [
        ".git", ".venv", "node_modules", "__pycache__", "build", "dist"
    ]

    init(resolver: SafePathResolver, gitUserName: String, gitUserEmail: String, enableCommands: Bool) {
        self.resolver = resolver
        self.gitUserName = gitUserName
        self.gitUserEmail = gitUserEmail
        self.enableCommands = enableCommands
    }

    var toolDefinitions: [[String: Any]] {
        var tools: [[String: Any]] = [
            tool(
                name: "list_files",
                description: "List files and folders inside the shared directory (optionally a subfolder).",
                properties: ["subpath": stringProperty("Subpath inside the shared root.")],
                required: [],
                readOnly: true,
                output: .stringArray
            ),
            tool(
                name: "read_file",
                description: "Read the text content of a file inside the shared directory.",
                properties: ["relative_path": stringProperty("Relative path to a text file.")],
                required: ["relative_path"],
                readOnly: true
            ),
            tool(
                name: "read_file_range",
                description: "Read a targeted line range from a text file. Use this after search_content to inspect surrounding implementation. Expand the range or use read_file before drawing conclusions when callers, state, imports, or other surrounding code may matter.",
                properties: [
                    "relative_path": stringProperty("Relative path to a text file."),
                    "start_line": ["type": "integer", "minimum": 1, "description": "1-based first line to return."],
                    "end_line": ["type": "integer", "minimum": 1, "description": "1-based last line to return (inclusive)."],
                ],
                required: ["relative_path", "start_line", "end_line"],
                readOnly: true,
                output: .object(readFileRangeOutputSchema())
            ),
            tool(
                name: "search_content",
                description: "Search text content recursively to locate relevant files and line regions. This is a locator, not a substitute for reading the implementation: inspect important matches with read_file_range or read_file before drawing conclusions.",
                properties: [
                    "query": stringProperty("Literal text to search for."),
                    "path": stringProperty("Optional subdirectory to search inside the shared root."),
                    "case_sensitive": ["type": "boolean", "default": false],
                    "context_lines": ["type": "integer", "minimum": 0, "maximum": 10, "default": 2],
                    "max_results": ["type": "integer", "minimum": 1, "maximum": maxSearchContentResults, "default": 20],
                ],
                required: ["query"],
                readOnly: true,
                output: .object(searchContentOutputSchema())
            ),
            tool(
                name: "search_filenames",
                description: "Recursively search filenames (not content) under the shared directory.",
                properties: ["query": stringProperty("Case-insensitive filename substring.")],
                required: ["query"],
                readOnly: true,
                output: .stringArray
            ),
            tool(
                name: "write_file",
                description: "Create a file, overwrite it, or append to it inside the shared directory.",
                properties: [
                    "relative_path": stringProperty("Relative file path."),
                    "content": stringProperty("UTF-8 text content."),
                    "append": ["type": "boolean", "default": false],
                ],
                required: ["relative_path", "content"],
                readOnly: false,
                destructive: true
            ),
            tool(
                name: "delete_file",
                description: "Delete a file inside the shared directory (files only, not directories).",
                properties: ["relative_path": stringProperty("Relative file path.")],
                required: ["relative_path"],
                readOnly: false,
                destructive: true
            ),
            tool(
                name: "delete_directory",
                description: "Recursively delete a folder and everything inside it.",
                properties: ["relative_path": stringProperty("Relative directory path.")],
                required: ["relative_path"],
                readOnly: false,
                destructive: true
            ),
            tool(
                name: "git_init",
                description: "Create a new git repository inside the shared directory.",
                properties: ["repo_path": stringProperty("Repository path relative to the shared root.")],
                required: [],
                readOnly: false
            ),
            tool(
                name: "git_status",
                description: "Show the working-tree status of a git repo whose worktree and Git metadata stay inside the shared directory.",
                properties: ["repo_path": stringProperty("Repository path relative to the shared root.")],
                required: [],
                readOnly: true
            ),
            tool(
                name: "git_log",
                description: "Show recent commit history of a Git repo fully contained inside the shared directory.",
                properties: [
                    "repo_path": stringProperty("Repository path relative to the shared root."),
                    "count": ["type": "integer", "minimum": 1, "maximum": 50, "default": 10],
                ],
                required: [],
                readOnly: true
            ),
            tool(
                name: "git_diff",
                description: "Show uncommitted changes (working tree vs index). Repository paths are containment-checked; external diff/textconv are suppressed when command execution is disabled.",
                properties: [
                    "repo_path": stringProperty("Repository path relative to the shared root."),
                    "paths": stringProperty("Optional path or whitespace-separated pathspecs. Quote pathspecs that contain spaces."),
                ],
                required: [],
                readOnly: true
            ),
            tool(
                name: "git_add",
                description: "Stage files for the next commit. When command execution is disabled, paths using Git content filters are refused.",
                properties: [
                    "repo_path": stringProperty("Repository path relative to the shared root."),
                    "paths": [
                        "type": "string",
                        "default": ".",
                        "description": "Path or whitespace-separated pathspecs. Quote pathspecs that contain spaces.",
                    ],
                ],
                required: [],
                readOnly: false
            ),
            tool(
                name: "git_commit",
                description: "Create a commit from staged changes. Repository hooks and GPG signing are suppressed when command execution is disabled.",
                properties: [
                    "repo_path": stringProperty("Repository path relative to the shared root."),
                    "message": ["type": "string", "default": "update"],
                ],
                required: [],
                readOnly: false
            ),
            tool(
                name: "git_push",
                description: "Push the current branch to its upstream remote. In safe mode, repository hooks, signing, local file transport, and repository-local credential helpers are restricted.",
                properties: ["repo_path": stringProperty("Repository path relative to the shared root.")],
                required: [],
                readOnly: false,
                openWorld: true
            ),
        ]

        if enableCommands {
            tools.append(
                tool(
                    name: "run_command",
                    description: "Run a shell command on the local machine. The command inherits the current user's environment and is not OS-sandboxed. cwd must stay inside the shared directory.",
                    properties: [
                        "command": stringProperty("Shell command to execute."),
                        "cwd": stringProperty("Working directory relative to the shared root."),
                        "timeout_seconds": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": ProcessRunner.maxCommandTimeoutSeconds,
                            "default": ProcessRunner.defaultCommandTimeoutSeconds,
                        ],
                    ],
                    required: ["command"],
                    readOnly: false,
                    destructive: true,
                    openWorld: true
                )
            )
        }
        return tools
    }

    func hasTool(named name: String) -> Bool {
        toolDefinitions.contains { $0["name"] as? String == name }
    }

    func call(name: String, arguments: [String: Any]) throws -> LocalToolCallOutput {
        toolSlots.wait()
        defer { toolSlots.signal() }
        try validateArguments(arguments, for: name)

        let needsSerialization = serializedToolNames.contains(name)
        if needsSerialization { mutationSlot.wait() }
        defer { if needsSerialization { mutationSlot.signal() } }

        switch name {
        case "list_files":
            let result = try listFiles(subpath: string(arguments, "subpath", default: ""))
            return stringArrayOutput(result.values, truncated: result.truncated)
        case "read_file":
            return stringOutput(try readFile(relativePath: requiredString(arguments, "relative_path")))
        case "read_file_range":
            return objectOutput(try readFileRange(
                relativePath: requiredString(arguments, "relative_path"),
                startLine: try requiredInt(arguments, "start_line"),
                endLine: try requiredInt(arguments, "end_line")
            ))
        case "search_content":
            return objectOutput(try searchContent(
                query: requiredString(arguments, "query"),
                path: string(arguments, "path", default: ""),
                caseSensitive: bool(arguments, "case_sensitive", default: false),
                contextLines: int(arguments, "context_lines", default: 2),
                maxResults: int(arguments, "max_results", default: 20)
            ))
        case "search_filenames":
            let result = try searchFilenames(query: requiredString(arguments, "query"))
            return stringArrayOutput(result.values, truncated: result.truncated)
        case "write_file":
            return stringOutput(try writeFile(
                relativePath: requiredString(arguments, "relative_path"),
                content: requiredString(arguments, "content"),
                append: bool(arguments, "append", default: false)
            ))
        case "delete_file":
            return stringOutput(try deleteFile(relativePath: requiredString(arguments, "relative_path")))
        case "delete_directory":
            return stringOutput(try deleteDirectory(relativePath: requiredString(arguments, "relative_path")))
        case "run_command":
            guard enableCommands else {
                throw MCPServerError.operationFailed("Command execution is disabled")
            }
            return stringOutput(try runCommand(
                command: requiredString(arguments, "command"),
                cwd: string(arguments, "cwd", default: ""),
                timeoutSeconds: int(arguments, "timeout_seconds", default: ProcessRunner.defaultCommandTimeoutSeconds)
            ))
        case "git_init":
            return stringOutput(try gitInit(repoPath: string(arguments, "repo_path", default: "")))
        case "git_status":
            return stringOutput(try gitStatus(repoPath: string(arguments, "repo_path", default: "")))
        case "git_log":
            return stringOutput(try gitLog(
                repoPath: string(arguments, "repo_path", default: ""),
                count: int(arguments, "count", default: 10)
            ))
        case "git_diff":
            return stringOutput(try gitDiff(
                repoPath: string(arguments, "repo_path", default: ""),
                paths: string(arguments, "paths", default: "")
            ))
        case "git_add":
            return stringOutput(try gitAdd(
                repoPath: string(arguments, "repo_path", default: ""),
                paths: string(arguments, "paths", default: ".")
            ))
        case "git_commit":
            return stringOutput(try gitCommit(
                repoPath: string(arguments, "repo_path", default: ""),
                message: string(arguments, "message", default: "update")
            ))
        case "git_push":
            return stringOutput(try gitPush(repoPath: string(arguments, "repo_path", default: "")))
        default:
            throw MCPServerError.notFound("Unknown tool: \(name)")
        }
    }

    private func listFiles(subpath: String) throws -> (values: [String], truncated: Bool) {
        let directory = try resolver.resolve(subpath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return ([], false)
        }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        let sorted = urls.sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        var entries: [String] = []
        entries.reserveCapacity(min(sorted.count, maxListEntries))
        for url in sorted.prefix(maxListEntries) {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            entries.append(url.lastPathComponent + ((values?.isDirectory ?? false) ? "/" : ""))
        }
        return (entries, sorted.count > maxListEntries)
    }

    private func readFile(relativePath: String) throws -> String {
        let target = try resolver.resolve(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MCPServerError.notFound("No such file: \(relativePath)")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxFileBytes else {
            throw MCPServerError.operationFailed("File is larger than the 5 MB limit for this tool")
        }
        let data = try Data(contentsOf: target, options: [.mappedIfSafe])
        guard data.count <= maxFileBytes else {
            throw MCPServerError.operationFailed("File is larger than the 5 MB limit for this tool")
        }
        var text = String(decoding: data, as: UTF8.self)
        if text.count > maxCharsReturned {
            let end = text.index(text.startIndex, offsetBy: maxCharsReturned)
            text = String(text[..<end]) + "\n\n[...truncated...]"
        }
        return text
    }

    private func splitTextLines(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline }).map(String.init)
        if text.last?.isNewline == true, lines.count > 1 {
            lines.removeLast()
        }
        return lines
    }

    private func readFileRange(relativePath: String, startLine: Int, endLine: Int) throws -> [String: Any] {
        guard startLine >= 1, endLine >= startLine else {
            throw MCPServerError.invalidArguments("start_line and end_line must define a valid 1-based inclusive range")
        }

        let target = try resolver.resolve(relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MCPServerError.notFound("No such file: \(relativePath)")
        }
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= maxFileBytes else {
            throw MCPServerError.operationFailed("File is larger than the 5 MB limit for this tool")
        }

        let data = try Data(contentsOf: target, options: [.mappedIfSafe])
        guard data.count <= maxFileBytes else {
            throw MCPServerError.operationFailed("File is larger than the 5 MB limit for this tool")
        }
        let text = String(decoding: data, as: UTF8.self)
        let lines = splitTextLines(text)
        let totalLines = max(1, lines.count)
        guard startLine <= totalLines else {
            throw MCPServerError.invalidArguments("start_line \(startLine) is beyond the end of the file (\(totalLines) lines)")
        }

        let requestedEnd = min(endLine, totalLines)
        let lineLimitedEnd = min(requestedEnd, startLine + maxReadRangeLines - 1)
        var returnedLines: [String] = []
        returnedLines.reserveCapacity(lineLimitedEnd - startLine + 1)
        var returnedChars = 0

        for lineNumber in startLine...lineLimitedEnd {
            let line = lines[lineNumber - 1]
            let separatorChars = returnedLines.isEmpty ? 0 : 1
            guard returnedChars + separatorChars + line.count <= maxReadRangeChars else { break }
            returnedLines.append(line)
            returnedChars += separatorChars + line.count
        }

        guard !returnedLines.isEmpty else {
            throw MCPServerError.operationFailed(
                "Line \(startLine) is larger than the 80,000 character response limit for read_file_range"
            )
        }

        let actualEndLine = startLine + returnedLines.count - 1
        let content = returnedLines.joined(separator: "\n")

        return [
            "path": relativePath,
            "start_line": startLine,
            "end_line": actualEndLine,
            "requested_end_line": endLine,
            "total_lines": totalLines,
            "has_before": startLine > 1,
            "has_after": actualEndLine < totalLines,
            "truncated": actualEndLine < requestedEnd,
            "content": content,
        ]
    }

    private func searchContent(
        query: String,
        path: String,
        caseSensitive: Bool,
        contextLines: Int,
        maxResults: Int
    ) throws -> [String: Any] {
        guard !query.isEmpty else {
            throw MCPServerError.invalidArguments("query must not be empty")
        }
        let searchRoot = try resolver.resolve(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPServerError.invalidPath("No such search directory: \(path.isEmpty ? "." : path)")
        }

        let effectiveContext = max(0, min(contextLines, 10))
        let effectiveMaxResults = max(1, min(maxResults, maxSearchContentResults))
        guard let enumerator = FileManager.default.enumerator(
            at: searchRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return [
                "query": query,
                "path": path,
                "case_sensitive": caseSensitive,
                "matches": [],
                "truncated": false,
                "visited_entries": 0,
                "files_scanned": 0,
                "bytes_scanned": 0,
            ]
        }

        var matches: [[String: Any]] = []
        var visited = 0
        var filesScanned = 0
        var bytesScanned = 0
        var previewChars = 0
        var truncated = false
        let needle = caseSensitive ? query : query.lowercased()

        searchLoop: while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxSearchVisited {
                truncated = true
                break
            }

            var itemIsDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path, isDirectory: &itemIsDirectory) else { continue }
            if itemIsDirectory.boolValue {
                if skippedSearchDirectories.contains(item.lastPathComponent) {
                    enumerator.skipDescendants()
                }
                continue
            }

            let attributes = try? FileManager.default.attributesOfItem(atPath: item.path)
            let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            if fileSize > maxSearchContentFileBytes { continue }
            if bytesScanned + fileSize > maxSearchContentBytesScanned {
                truncated = true
                break
            }

            let relative = relativePath(for: item)
            guard let safeItem = try? resolver.resolve(relative), safeItem.path == item.resolvingSymlinksInPath().standardizedFileURL.path else {
                continue
            }
            guard let data = try? Data(contentsOf: safeItem, options: [.mappedIfSafe]) else { continue }
            if data.count > maxSearchContentFileBytes { continue }
            if bytesScanned + data.count > maxSearchContentBytesScanned {
                truncated = true
                break
            }
            bytesScanned += data.count
            if data.prefix(8_192).contains(0) { continue }

            filesScanned += 1
            let text = String(decoding: data, as: UTF8.self)
            let lines = splitTextLines(text)

            for (index, line) in lines.enumerated() {
                let haystack = caseSensitive ? line : line.lowercased()
                guard haystack.contains(needle) else { continue }

                let matchLine = index + 1
                let previewStart = max(1, matchLine - effectiveContext)
                let previewEnd = min(lines.count, matchLine + effectiveContext)
                let preview = lines[(previewStart - 1)..<previewEnd].enumerated().map { offset, value in
                    let clipped: String
                    if value.count > maxSearchPreviewLineChars {
                        let cutoff = value.index(value.startIndex, offsetBy: maxSearchPreviewLineChars)
                        clipped = String(value[..<cutoff]) + "..."
                    } else {
                        clipped = value
                    }
                    return "\(previewStart + offset): \(clipped)"
                }.joined(separator: "\n")
                if previewChars + preview.count > maxSearchPreviewChars {
                    truncated = true
                    break searchLoop
                }
                previewChars += preview.count

                matches.append([
                    "path": relative,
                    "line": matchLine,
                    "preview_start_line": previewStart,
                    "preview_end_line": previewEnd,
                    "preview": preview,
                ])
                if matches.count >= effectiveMaxResults {
                    truncated = true
                    break searchLoop
                }
            }
        }

        return [
            "query": query,
            "path": path,
            "case_sensitive": caseSensitive,
            "matches": matches,
            "truncated": truncated,
            "visited_entries": min(visited, maxSearchVisited),
            "files_scanned": filesScanned,
            "bytes_scanned": bytesScanned,
        ]
    }

    private func relativePath(for url: URL) -> String {
        let rootPath = resolver.root.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != rootPath, path.hasPrefix(rootPath + "/") else { return "" }
        return String(path.dropFirst(rootPath.count + 1))
    }

    private func jsonText(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func searchFilenames(query: String) throws -> (values: [String], truncated: Bool) {
        let needle = query.lowercased()
        guard !needle.isEmpty else {
            throw MCPServerError.invalidArguments("query must not be empty")
        }
        guard let enumerator = FileManager.default.enumerator(
            at: resolver.root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else {
            return ([], false)
        }

        var matches: [String] = []
        var visited = 0
        var truncated = false
        while let item = enumerator.nextObject() as? URL {
            visited += 1
            if visited > maxSearchVisited {
                truncated = true
                break
            }

            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            if values?.isDirectory == true, skippedSearchDirectories.contains(item.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == false, item.lastPathComponent.lowercased().contains(needle) {
                let relative = relativePath(for: item)
                guard !relative.isEmpty else { continue }
                matches.append(relative)
                if matches.count >= maxSearchResults {
                    truncated = true
                    break
                }
            }
        }
        return (matches, truncated)
    }

    private func writeFile(relativePath: String, content: String, append: Bool) throws -> String {
        guard let data = content.data(using: .utf8), data.count <= maxWriteBytes else {
            throw MCPServerError.operationFailed("Content is larger than the 5 MB write limit")
        }
        let target = try resolver.resolve(relativePath)
        var isDirectory: ObjCBool = false
        if append, FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw MCPServerError.invalidPath("Not a file: \(relativePath)")
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if append, FileManager.default.fileExists(atPath: target.path) {
            let handle = try FileHandle(forWritingTo: target)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } else {
            try data.write(to: target, options: .atomic)
        }
        return "\(append ? "Appended to" : "Wrote") \(relativePath) (\(data.count) bytes)"
    }

    private func deleteFile(relativePath: String) throws -> String {
        let target = try resolver.resolveForDeletion(relativePath)
        let mode = try fileModeWithoutFollowingSymlink(target, missingMessage: "No such file: \(relativePath)")
        guard mode & S_IFMT != S_IFDIR else {
            throw MCPServerError.invalidPath("delete_file only removes files or symlinks; use delete_directory for folders")
        }
        try FileManager.default.removeItem(at: target)
        return "Deleted \(relativePath)"
    }

    private func deleteDirectory(relativePath: String) throws -> String {
        let target = try resolver.resolveForDeletion(relativePath)
        guard target.path != resolver.root.path else {
            throw MCPServerError.invalidPath("Refusing to delete the shared root directory")
        }
        let mode = try fileModeWithoutFollowingSymlink(target, missingMessage: "No such directory: \(relativePath)")
        guard mode & S_IFMT == S_IFDIR else {
            throw MCPServerError.invalidPath("Not a directory: \(relativePath). Use delete_file for symlinks.")
        }
        try FileManager.default.removeItem(at: target)
        return "Deleted directory \(relativePath)"
    }

    private func fileModeWithoutFollowingSymlink(_ url: URL, missingMessage: String) throws -> mode_t {
        var info = stat()
        let result = url.path.withCString { pointer in
            lstat(pointer, &info)
        }
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR {
                throw MCPServerError.notFound(missingMessage)
            }
            throw MCPServerError.operationFailed("Could not inspect \(url.lastPathComponent): \(String(cString: strerror(errno)))")
        }
        return info.st_mode
    }

    private func runCommand(command: String, cwd: String, timeoutSeconds: Int) throws -> String {
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MCPServerError.invalidArguments("command must not be empty")
        }
        let workdir = try resolver.resolve(cwd)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workdir.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPServerError.invalidPath("No such working directory: \(cwd.isEmpty ? "." : cwd)")
        }

        commandSlots.wait()
        defer { commandSlots.signal() }

        let shell = preferredShell()
        let result = try ProcessRunner.run(
            executable: shell,
            arguments: ["-lc", command],
            cwd: workdir.path,
            timeoutSeconds: timeoutSeconds,
            outputLimitBytes: maxToolProcessOutputBytes
        )
        if result.timedOut {
            var partial = "Command timed out after \(max(1, min(timeoutSeconds, ProcessRunner.maxCommandTimeoutSeconds))) seconds."
            if !result.stdout.isEmpty { partial += "\nstdout:\n\(result.stdout)" }
            if !result.stderr.isEmpty { partial += "\nstderr:\n\(result.stderr)" }
            throw MCPServerError.operationFailed(partial)
        }
        return formatProcessResult(result)
    }

    private func gitInit(repoPath: String) throws -> String {
        let repo = try resolver.resolve(repoPath)
        if FileManager.default.fileExists(atPath: repo.path) {
            let contents = try FileManager.default.contentsOfDirectory(atPath: repo.path)
            if !contents.isEmpty {
                if FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) {
                    return "Already a git repository: \(repoPath.isEmpty ? "." : repoPath)"
                }
                throw MCPServerError.operationFailed("Directory not empty, cannot init here: \(repoPath.isEmpty ? "." : repoPath)")
            }
        } else {
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        }
        var arguments = ["init", "-b", "main"]
        if !enableCommands { arguments.append("--template=") }
        _ = try runGit(repo: repo, arguments: arguments)
        _ = try gitRepo(repoPath)
        return "Initialized Git repository: \(repoPath.isEmpty ? "." : repoPath)"
    }

    private func gitRepo(_ repoPath: String) throws -> URL {
        let repo = try resolver.resolve(repoPath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repo.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw MCPServerError.notFound("No such path: \(repoPath.isEmpty ? "." : repoPath)")
        }
        let gitEntry = repo.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitEntry.path) else {
            throw MCPServerError.invalidPath("Not a git repository: \(repoPath.isEmpty ? "." : repoPath)")
        }
        try validateGitMetadataEntry(gitEntry, repo: repo)
        try ensureNoRepositoryConfigIncludes(repo: repo)

        let layout = try runGit(
            repo: repo,
            arguments: [
                "rev-parse", "--path-format=absolute", "--show-toplevel",
                "--absolute-git-dir", "--git-common-dir", "--git-path", "objects",
            ],
            outputLimitBytes: 20_000,
            trimOutput: false
        )
        let paths = layout.split(whereSeparator: { $0.isNewline }).map(String.init)
        guard paths.count == 4 else {
            throw MCPServerError.invalidPath("Could not validate Git repository layout safely")
        }

        let worktree = URL(fileURLWithPath: paths[0]).resolvingSymlinksInPath().standardizedFileURL
        guard worktree.path == repo.path else {
            throw MCPServerError.invalidPath("Refused: Git worktree is outside or different from the requested repository path")
        }

        let gitDirectory = URL(fileURLWithPath: paths[1])
        let commonDirectory = URL(fileURLWithPath: paths[2])
        let objectDirectory = URL(fileURLWithPath: paths[3])
        for (label, url) in [
            ("Git directory", gitDirectory),
            ("Git common directory", commonDirectory),
            ("Git object directory", objectDirectory),
        ] where !resolver.contains(url) {
            throw MCPServerError.invalidPath("Refused: \(label) is outside the shared directory")
        }

        try validateGitAlternates(objectDirectory: objectDirectory)
        return repo
    }

    private func validateGitMetadataEntry(_ gitEntry: URL, repo: URL) throws {
        let mode = try fileModeWithoutFollowingSymlink(gitEntry, missingMessage: "Not a git repository")
        switch mode & S_IFMT {
        case S_IFDIR:
            guard resolver.contains(gitEntry) else {
                throw MCPServerError.invalidPath("Refused: Git directory is outside the shared directory")
            }
            try validateGitConfigMetadata(gitDirectory: gitEntry)
        case S_IFREG:
            let attributes = try FileManager.default.attributesOfItem(atPath: gitEntry.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 64_000 else {
                throw MCPServerError.invalidPath("Refused: .git metadata file is too large to validate safely")
            }
            let text = try String(contentsOf: gitEntry, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.lowercased().hasPrefix("gitdir:") else {
                throw MCPServerError.invalidPath("Refused: unsupported .git metadata file")
            }
            let pathText = String(text.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pathText.isEmpty else {
                throw MCPServerError.invalidPath("Refused: invalid .git metadata file")
            }
            let target = pathText.hasPrefix("/")
                ? URL(fileURLWithPath: pathText)
                : repo.appendingPathComponent(pathText)
            guard resolver.contains(target) else {
                throw MCPServerError.invalidPath("Refused: Git directory is outside the shared directory")
            }
            try validateGitConfigMetadata(gitDirectory: target)
        default:
            throw MCPServerError.invalidPath("Refused: .git must be a directory or a regular gitdir metadata file")
        }
    }

    private func validateGitConfigMetadata(gitDirectory: URL) throws {
        guard resolver.contains(gitDirectory) else {
            throw MCPServerError.invalidPath("Refused: Git directory is outside the shared directory")
        }

        var commonDirectory = gitDirectory
        let commonDirFile = gitDirectory.appendingPathComponent("commondir")
        if FileManager.default.fileExists(atPath: commonDirFile.path) {
            guard resolver.contains(commonDirFile) else {
                throw MCPServerError.invalidPath("Refused: Git commondir metadata is outside the shared directory")
            }
            let mode = try fileModeWithoutFollowingSymlink(commonDirFile, missingMessage: "Missing Git commondir metadata")
            guard mode & S_IFMT == S_IFREG else {
                throw MCPServerError.invalidPath("Refused: Git commondir metadata must be a regular file")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: commonDirFile.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
            guard size <= 64_000 else {
                throw MCPServerError.invalidPath("Refused: Git commondir metadata is too large to validate safely")
            }
            let pathText = try String(contentsOf: commonDirFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pathText.isEmpty else {
                throw MCPServerError.invalidPath("Refused: Git commondir metadata is empty")
            }
            commonDirectory = pathText.hasPrefix("/")
                ? URL(fileURLWithPath: pathText)
                : gitDirectory.appendingPathComponent(pathText)
            guard resolver.contains(commonDirectory) else {
                throw MCPServerError.invalidPath("Refused: Git common directory is outside the shared directory")
            }
        }

        for configFile in [commonDirectory.appendingPathComponent("config"), gitDirectory.appendingPathComponent("config.worktree")] {
            guard FileManager.default.fileExists(atPath: configFile.path) else { continue }
            guard resolver.contains(configFile) else {
                throw MCPServerError.invalidPath("Refused: Git config metadata is outside the shared directory")
            }
            let mode = try fileModeWithoutFollowingSymlink(configFile, missingMessage: "Missing Git config metadata")
            guard mode & S_IFMT == S_IFREG else {
                throw MCPServerError.invalidPath("Refused: Git config metadata must be a regular file")
            }
        }
    }

    private func ensureNoRepositoryConfigIncludes(repo: URL) throws {
        guard !enableCommands else { return }
        let localConfig = try runGit(
            repo: repo,
            arguments: ["config", "--local", "--no-includes", "--list"],
            outputLimitBytes: maxGitSafetyOutputBytes
        )
        try ensureCompleteGitSafetyOutput(localConfig, operation: "Git config include scan")
        for line in localConfig.split(whereSeparator: { $0.isNewline }) {
            let key = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?.lowercased() ?? ""
            if key == "include.path" || (key.hasPrefix("includeif.") && key.hasSuffix(".path")) {
                throw MCPServerError.operationFailed(
                    "Git repository config includes are not allowed while command execution is disabled"
                )
            }
        }
    }

    private func validateGitAlternates(objectDirectory: URL) throws {
        let alternatesFile = objectDirectory.appendingPathComponent("info/alternates")
        guard FileManager.default.fileExists(atPath: alternatesFile.path) else { return }
        guard resolver.contains(alternatesFile) else {
            throw MCPServerError.invalidPath("Refused: Git alternates metadata is outside the shared directory")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: alternatesFile.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 1_000_000 else {
            throw MCPServerError.invalidPath("Refused: Git alternates file is too large to validate safely")
        }
        let text = try String(contentsOf: alternatesFile, encoding: .utf8)
        for rawLine in text.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard !line.hasPrefix("\"") else {
                throw MCPServerError.invalidPath("Refused: quoted Git alternate object paths are not supported safely")
            }
            let alternate = line.hasPrefix("/")
                ? URL(fileURLWithPath: line)
                : objectDirectory.appendingPathComponent(line)
            guard resolver.contains(alternate) else {
                throw MCPServerError.invalidPath("Refused: Git alternate object directory is outside the shared directory")
            }
        }
    }

    private func gitStatus(repoPath: String) throws -> String {
        let repo = try gitRepo(repoPath)
        var arguments = ["status", "--short"]
        if !enableCommands { arguments.append("--ignore-submodules=all") }
        let out = try runGit(repo: repo, arguments: arguments)
        return out.isEmpty ? "(working tree clean)" : out
    }

    private func gitLog(repoPath: String, count: Int) throws -> String {
        return try runGit(repo: gitRepo(repoPath), arguments: ["log", "--oneline", "-n", String(max(1, min(count, 50)))])
    }

    private func gitDiff(repoPath: String, paths: String) throws -> String {
        let repo = try gitRepo(repoPath)
        var args = ["diff"]
        if !enableCommands {
            args += ["--no-ext-diff", "--no-textconv", "--ignore-submodules=all"]
        }
        if !paths.isEmpty {
            args.append("--")
            args.append(contentsOf: try gitPathspecs(paths, repo: repo))
        }
        return try runGit(repo: repo, arguments: args)
    }

    private func gitAdd(repoPath: String, paths: String) throws -> String {
        let repo = try gitRepo(repoPath)
        let requestedPaths = paths.isEmpty ? "." : paths
        let pathspecs = try gitPathspecs(requestedPaths, repo: repo)
        try ensureGitAddDoesNotRunFilters(repo: repo, pathspecs: pathspecs)
        var args = ["add", "--"]
        args.append(contentsOf: pathspecs)
        _ = try runGit(repo: repo, arguments: args)
        return "Staged: \(requestedPaths)"
    }

    private func gitCommit(repoPath: String, message: String) throws -> String {
        var args: [String] = []
        if !gitUserName.isEmpty { args += ["-c", "user.name=\(gitUserName)"] }
        if !gitUserEmail.isEmpty { args += ["-c", "user.email=\(gitUserEmail)"] }
        args.append("commit")
        if !enableCommands { args.append("--no-gpg-sign") }
        args += ["-m", message]
        return try runGit(repo: gitRepo(repoPath), arguments: args)
    }

    private func gitPush(repoPath: String) throws -> String {
        let repo = try gitRepo(repoPath)
        try ensureSafeGitPushConfiguration(repo: repo)
        var args = ["push"]
        if !enableCommands {
            args += ["--no-verify", "--no-signed", "--no-recurse-submodules", "--receive-pack=git-receive-pack"]
        }
        return try runGit(repo: repo, arguments: args)
    }

    private func runGit(
        repo: URL,
        arguments: [String],
        outputLimitBytes: Int = maxToolProcessOutputBytes,
        trimOutput: Bool = true
    ) throws -> String {
        gitSlots.wait()
        defer { gitSlots.signal() }

        var environment = sanitizedGitEnvironment()
        environment["GIT_TERMINAL_PROMPT"] = "0"
        if !enableCommands {
            environment["GIT_ASKPASS"] = "/usr/bin/false"
            environment["SSH_ASKPASS"] = "/usr/bin/false"
            environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -F /dev/null -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none"
            environment["GIT_PAGER"] = "cat"
        }
        let result = try ProcessRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", repo.path, "--no-pager"] + safeGitConfigurationArguments() + arguments,
            environment: environment,
            timeoutSeconds: 120,
            outputLimitBytes: outputLimitBytes
        )
        if result.timedOut {
            throw MCPServerError.operationFailed("git command timed out after 120 seconds")
        }
        guard result.exitCode == 0 else {
            throw MCPServerError.operationFailed(
                result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? (result.stdout.isEmpty ? "git command failed" : result.stdout)
                    : result.stderr
            )
        }
        return trimOutput
            ? result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            : result.stdout
    }

    private func sanitizedGitEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let exactKeys = [
            "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_INDEX_FILE", "GIT_GRAFT_FILE",
            "GIT_SHALLOW_FILE", "GIT_NAMESPACE", "GIT_PREFIX", "GIT_EXEC_PATH",
            "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT", "GIT_CEILING_DIRECTORIES",
            "GIT_DISCOVERY_ACROSS_FILESYSTEM", "GIT_EXTERNAL_DIFF",
        ]
        for key in exactKeys { environment.removeValue(forKey: key) }
        for key in Array(environment.keys) where
            key.hasPrefix("GIT_CONFIG_KEY_") || key.hasPrefix("GIT_CONFIG_VALUE_") || key.hasPrefix("GIT_TRACE") {
            environment.removeValue(forKey: key)
        }
        return environment
    }

    private func safeGitConfigurationArguments() -> [String] {
        guard !enableCommands else { return [] }
        return [
            "-c", "core.hooksPath=/dev/null",
            "-c", "core.fsmonitor=false",
            "-c", "core.attributesFile=/dev/null",
            "-c", "core.excludesFile=/dev/null",
            "-c", "core.askPass=/usr/bin/false",
            "-c", "core.sshCommand=/usr/bin/ssh -F /dev/null -o BatchMode=yes -o ProxyCommand=none -o ProxyJump=none",
            "-c", "credential.helper=",
            "-c", "protocol.allow=never",
            "-c", "protocol.file.allow=never",
            "-c", "protocol.http.allow=always",
            "-c", "protocol.https.allow=always",
            "-c", "protocol.ssh.allow=always",
        ]
    }

    private func ensureGitAddDoesNotRunFilters(repo: URL, pathspecs: [String]) throws {
        guard !enableCommands else { return }
        let listed = try runGit(
            repo: repo,
            arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"] + pathspecs,
            outputLimitBytes: maxGitSafetyOutputBytes,
            trimOutput: false
        )
        try ensureCompleteGitSafetyOutput(listed, operation: "git_add path scan")
        let paths = listed.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        try validateEmbeddedGitRepositories(paths: paths, repo: repo)

        var index = 0
        while index < paths.count {
            let end = min(index + 128, paths.count)
            let batch = Array(paths[index..<end])
            let attributes = try runGit(
                repo: repo,
                arguments: ["check-attr", "-z", "filter", "--"] + batch,
                outputLimitBytes: maxGitSafetyOutputBytes,
                trimOutput: false
            )
            try ensureCompleteGitSafetyOutput(attributes, operation: "git_add attribute scan")
            let fields = attributes.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            guard fields.count.isMultiple(of: 3) else {
                throw MCPServerError.operationFailed("Could not validate Git content filters safely")
            }
            for offset in stride(from: 0, to: fields.count, by: 3) {
                let value = fields[offset + 2]
                if value != "unspecified" && value != "unset" {
                    throw MCPServerError.operationFailed(
                        "git_add refused because \(fields[offset]) uses Git content filter '\(value)' while command execution is disabled"
                    )
                }
            }
            index = end
        }
    }

    private func validateEmbeddedGitRepositories(paths: [String], repo: URL) throws {
        for rawPath in paths {
            let relativePath = rawPath.hasSuffix("/") ? String(rawPath.dropLast()) : rawPath
            guard !relativePath.isEmpty else { continue }
            let candidate = repo.appendingPathComponent(relativePath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let gitEntry = candidate.appendingPathComponent(".git")
            guard FileManager.default.fileExists(atPath: gitEntry.path) else { continue }
            let sharedRootRelativePath = self.relativePath(for: candidate)
            guard !sharedRootRelativePath.isEmpty else {
                throw MCPServerError.invalidPath("Could not validate embedded Git repository path safely")
            }
            _ = try gitRepo(sharedRootRelativePath)
        }
    }

    private func ensureSafeGitPushConfiguration(repo: URL) throws {
        guard !enableCommands else { return }
        let localConfig = try runGit(
            repo: repo,
            arguments: ["config", "--local", "--includes", "--list"],
            outputLimitBytes: maxGitSafetyOutputBytes
        )
        try ensureCompleteGitSafetyOutput(localConfig, operation: "git_push config scan")
        let unsafeHTTPFileSettingSuffixes = [
            "cookiefile", "sslcert", "sslkey", "sslcainfo", "sslcapath", "pinnedpubkey",
            "proxysslcert", "proxysslkey", "proxysslcainfo",
        ]
        for line in localConfig.split(whereSeparator: { $0.isNewline }) {
            let key = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).first?.lowercased() ?? ""
            if key.hasPrefix("credential.") && key.hasSuffix(".helper") {
                throw MCPServerError.operationFailed(
                    "git_push refused a repository-local credential helper while command execution is disabled"
                )
            }
            if key.hasPrefix("http."), unsafeHTTPFileSettingSuffixes.contains(where: {
                key == "http.\($0)" || key.hasSuffix(".\($0)")
            }) {
                throw MCPServerError.operationFailed(
                    "git_push refused repository-controlled HTTP file setting '\(key)' while command execution is disabled"
                )
            }
        }
    }

    private func ensureCompleteGitSafetyOutput(_ value: String, operation: String) throws {
        if value.contains("[...truncated "), value.hasSuffix(" bytes...]") {
            throw MCPServerError.operationFailed("\(operation) exceeded the safety scan limit")
        }
    }

    private func formatProcessResult(_ result: ProcessResult) -> String {
        var sections = ["exit_code: \(result.exitCode)"]
        let stdout = result.stdout.trimmingCharacters(in: .newlines)
        let stderr = result.stderr.trimmingCharacters(in: .newlines)
        if !stdout.isEmpty { sections.append("stdout:\n\(stdout)") }
        if !stderr.isEmpty { sections.append("stderr:\n\(stderr)") }
        if stdout.isEmpty && stderr.isEmpty { sections.append("(no output)") }
        return sections.joined(separator: "\n\n")
    }

    private func preferredShell() -> String {
        let configured = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        if FileManager.default.isExecutableFile(atPath: configured) { return configured }
        return "/bin/sh"
    }

    private func gitPathspecs(_ value: String, repo: URL) throws -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let exactPath = repo.appendingPathComponent(trimmed).standardizedFileURL
        if (exactPath.path == repo.path || exactPath.path.hasPrefix(repo.path + "/")),
           FileManager.default.fileExists(atPath: exactPath.path) {
            return [trimmed]
        }
        return try shellWords(trimmed)
    }

    private func shellWords(_ value: String) throws -> [String] {
        enum Quote { case single, double }

        var words: [String] = []
        var current = ""
        var quote: Quote?
        var escaping = false
        var tokenStarted = false

        for character in value {
            if escaping {
                current.append(character)
                escaping = false
                tokenStarted = true
                continue
            }

            if character == "\\", quote != .single {
                escaping = true
                tokenStarted = true
                continue
            }
            if character == "'", quote != .double {
                quote = quote == .single ? nil : .single
                tokenStarted = true
                continue
            }
            if character == "\"", quote != .single {
                quote = quote == .double ? nil : .double
                tokenStarted = true
                continue
            }
            if character.isWhitespace, quote == nil {
                if tokenStarted {
                    words.append(current)
                    current = ""
                    tokenStarted = false
                }
                continue
            }

            current.append(character)
            tokenStarted = true
        }

        guard quote == nil else {
            throw MCPServerError.invalidArguments("Unterminated quote in Git paths")
        }
        if escaping { current.append("\\") }
        if tokenStarted { words.append(current) }
        return words
    }

    private func requiredString(_ arguments: [String: Any], _ key: String) throws -> String {
        guard let value = arguments[key] as? String else {
            throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)")
        }
        return value
    }

    private func integerArgument(_ arguments: [String: Any], _ key: String) -> Int? {
        guard let value = arguments[key] as? NSNumber,
              CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        let integer = value.int64Value
        guard NSNumber(value: integer).compare(value) == .orderedSame else { return nil }
        return Int(exactly: integer)
    }

    private func requiredInt(_ arguments: [String: Any], _ key: String) throws -> Int {
        guard let value = integerArgument(arguments, key) else {
            throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)")
        }
        return value
    }

    private func string(_ arguments: [String: Any], _ key: String, default defaultValue: String) -> String {
        arguments[key] as? String ?? defaultValue
    }

    private func bool(_ arguments: [String: Any], _ key: String, default defaultValue: Bool) -> Bool {
        guard let value = arguments[key] as? NSNumber,
              CFGetTypeID(value) == CFBooleanGetTypeID() else { return defaultValue }
        return value.boolValue
    }

    private func int(_ arguments: [String: Any], _ key: String, default defaultValue: Int) -> Int {
        integerArgument(arguments, key) ?? defaultValue
    }

    private func stringProperty(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    private func stringOutput(_ value: String) -> LocalToolCallOutput {
        LocalToolCallOutput(
            content: [["type": "text", "text": value]],
            structuredContent: ["result": value]
        )
    }

    private func stringArrayOutput(_ values: [String], truncated: Bool) -> LocalToolCallOutput {
        LocalToolCallOutput(
            content: values.map { ["type": "text", "text": $0] },
            structuredContent: [
                "result": values,
                "truncated": truncated,
            ]
        )
    }

    private func objectOutput(_ value: [String: Any]) -> LocalToolCallOutput {
        LocalToolCallOutput(
            content: [["type": "text", "text": jsonText(value)]],
            structuredContent: value
        )
    }

    private func validateArguments(_ arguments: [String: Any], for toolName: String) throws {
        guard let definition = toolDefinitions.first(where: { $0["name"] as? String == toolName }),
              let schema = definition["inputSchema"] as? [String: Any],
              let properties = schema["properties"] as? [String: Any] else {
            throw MCPServerError.invalidArguments("Invalid tool definition: \(toolName)")
        }
        let required = Set(schema["required"] as? [String] ?? [])
        let allowed = Set(properties.keys)
        let unknown = Set(arguments.keys).subtracting(allowed)
        if let key = unknown.sorted().first {
            throw MCPServerError.invalidArguments("Unexpected argument: \(key)")
        }
        for key in required where arguments[key] == nil {
            throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)")
        }
        for (key, value) in arguments {
            guard let property = properties[key] as? [String: Any], let type = property["type"] as? String else { continue }
            switch type {
            case "string":
                guard value is String else { throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)") }
            case "boolean":
                guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                    throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)")
                }
            case "integer":
                guard let integer = integerArgument(arguments, key) else {
                    throw MCPServerError.invalidArguments("Missing or invalid argument: \(key)")
                }
                if let minimum = property["minimum"] as? NSNumber, integer < minimum.intValue {
                    throw MCPServerError.invalidArguments("Argument \(key) must be >= \(minimum.intValue)")
                }
                if let maximum = property["maximum"] as? NSNumber, integer > maximum.intValue {
                    throw MCPServerError.invalidArguments("Argument \(key) must be <= \(maximum.intValue)")
                }
            default:
                break
            }
        }
    }

    private func readFileRangeOutputSchema() -> [String: Any] {
        [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "start_line": ["type": "integer"],
                "end_line": ["type": "integer"],
                "requested_end_line": ["type": "integer"],
                "total_lines": ["type": "integer"],
                "has_before": ["type": "boolean"],
                "has_after": ["type": "boolean"],
                "truncated": ["type": "boolean"],
                "content": ["type": "string"],
            ],
            "required": ["path", "start_line", "end_line", "requested_end_line", "total_lines", "has_before", "has_after", "truncated", "content"],
            "additionalProperties": false,
        ]
    }

    private func searchContentOutputSchema() -> [String: Any] {
        let matchSchema: [String: Any] = [
            "type": "object",
            "properties": [
                "path": ["type": "string"],
                "line": ["type": "integer"],
                "preview_start_line": ["type": "integer"],
                "preview_end_line": ["type": "integer"],
                "preview": ["type": "string"],
            ],
            "required": ["path", "line", "preview_start_line", "preview_end_line", "preview"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "query": ["type": "string"],
                "path": ["type": "string"],
                "case_sensitive": ["type": "boolean"],
                "matches": ["type": "array", "items": matchSchema],
                "truncated": ["type": "boolean"],
                "visited_entries": ["type": "integer"],
                "files_scanned": ["type": "integer"],
                "bytes_scanned": ["type": "integer"],
            ],
            "required": ["query", "path", "case_sensitive", "matches", "truncated", "visited_entries", "files_scanned", "bytes_scanned"],
            "additionalProperties": false,
        ]
    }

    private func outputSchema(for output: LocalToolOutputShape) -> [String: Any] {
        switch output {
        case .string:
            return [
                "type": "object",
                "properties": ["result": ["type": "string"]],
                "required": ["result"],
                "additionalProperties": false,
            ]
        case .stringArray:
            return [
                "type": "object",
                "properties": [
                    "result": ["type": "array", "items": ["type": "string"]],
                    "truncated": ["type": "boolean"],
                ],
                "required": ["result", "truncated"],
                "additionalProperties": false,
            ]
        case let .object(schema):
            return schema
        }
    }

    private func tool(
        name: String,
        description: String,
        properties: [String: Any],
        required: [String],
        readOnly: Bool,
        destructive: Bool = false,
        openWorld: Bool = false,
        output: LocalToolOutputShape = .string
    ) -> [String: Any] {
        [
            "name": name,
            "description": description,
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
            "outputSchema": outputSchema(for: output),
            "annotations": [
                "readOnlyHint": readOnly,
                "destructiveHint": destructive,
                "openWorldHint": openWorld,
            ],
        ]
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private enum HTTPRequestParseResult {
    case incomplete
    case request(HTTPRequest)
    case failure(status: Int, message: String)
}

final class LocalMCPServer {
    private let port: UInt16
    private let localAuthToken: String
    private let tools: LocalTools
    private let skills: CodexSkillRegistry
    private let log: (String) -> Void
    private let listenerQueue = DispatchQueue(label: "com.filemcp.http-listener", qos: .userInitiated)
    private let workQueue = DispatchQueue(label: "com.filemcp.http-workers", qos: .userInitiated, attributes: .concurrent)
    private var listener: NWListener?
    private let stateLock = NSLock()
    private var ready = false

    init(
        port: UInt16,
        allowedDirectory: String,
        gitUserName: String,
        gitUserEmail: String,
        enableCommands: Bool,
        localAuthToken: String,
        log: @escaping (String) -> Void
    ) throws {
        guard localAuthToken.utf8.count >= 32 else {
            throw MCPServerError.invalidArguments("Local MCP authentication token is too short")
        }
        self.port = port
        self.localAuthToken = localAuthToken
        self.log = log
        let resolver = try SafePathResolver(rootPath: allowedDirectory)
        self.tools = LocalTools(
            resolver: resolver,
            gitUserName: gitUserName,
            gitUserEmail: gitUserEmail,
            enableCommands: enableCommands
        )
        self.skills = try CodexSkillRegistry(rootPath: allowedDirectory, log: log)
    }

    var isReady: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return ready
    }

    func start(timeoutSeconds: TimeInterval = 5) throws {
        guard port > 0, let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw MCPServerError.invalidArguments("Invalid port: \(port)")
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = false
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        self.listener = listener

        let semaphore = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateLock.lock()
                self?.ready = true
                self?.stateLock.unlock()
                semaphore.signal()
            case let .failed(error):
                startError = error
                semaphore.signal()
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: listenerQueue)

        if semaphore.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            stop()
            throw MCPServerError.operationFailed("MCP server did not start on 127.0.0.1:\(port)")
        }
        if let startError {
            stop()
            throw MCPServerError.operationFailed("Cannot listen on port \(port): \(startError.localizedDescription)")
        }
        log("[MCP] Server listening on http://127.0.0.1:\(port)/mcp\n")
        skills.refresh()
    }

    func stop() {
        listener?.cancel()
        listener = nil
        stateLock.lock()
        ready = false
        stateLock.unlock()
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: listenerQueue)
        receiveRequest(on: connection, accumulated: Data())
    }

    private func receiveRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            switch self.parseHTTPRequest(buffer) {
            case let .request(request):
                self.workQueue.async {
                    let response = self.process(request)
                    self.send(response, on: connection)
                }
                return
            case let .failure(status, message):
                self.send(
                    self.httpResponse(status: status, body: Data(message.utf8), contentType: "text/plain"),
                    on: connection
                )
                return
            case .incomplete:
                break
            }

            if buffer.count > maxHTTPRequestHeaderBytes + maxHTTPRequestBodyBytes {
                self.send(self.httpResponse(status: 413, body: Data("Payload too large".utf8), contentType: "text/plain"), on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receiveRequest(on: connection, accumulated: buffer)
        }
    }

    private func parseHTTPRequest(_ data: Data) -> HTTPRequestParseResult {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else {
            return data.count > maxHTTPRequestHeaderBytes
                ? .failure(status: 431, message: "Request headers too large")
                : .incomplete
        }
        guard headerRange.lowerBound <= maxHTTPRequestHeaderBytes else {
            return .failure(status: 431, message: "Request headers too large")
        }

        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(status: 400, message: "Malformed request headers")
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .failure(status: 400, message: "Malformed request line")
        }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[2] == "HTTP/1.1" || parts[2] == "HTTP/1.0" else {
            return .failure(status: 400, message: "Malformed request line")
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else {
                return .failure(status: 400, message: "Malformed request header")
            }
            let rawKey = String(line[..<colon])
            let trimmedKey = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = trimmedKey.lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard rawKey == trimmedKey, isValidHTTPHeaderName(key), isValidHTTPHeaderValue(value) else {
                return .failure(status: 400, message: "Malformed request header")
            }
            if singleValueHTTPRequestHeaders.contains(key), headers[key] != nil {
                return .failure(status: 400, message: "Duplicate \(key) header")
            }
            headers[key] = value
        }

        if headers["transfer-encoding"] != nil {
            return .failure(status: 400, message: "Transfer-Encoding is not supported")
        }
        guard let host = headers["host"], !host.isEmpty else {
            return .failure(status: 400, message: "Missing Host header")
        }
        guard isAllowedHost(host) else {
            return .failure(status: 403, message: "Forbidden host")
        }
        if let origin = headers["origin"], !isAllowedOrigin(origin) {
            return .failure(status: 403, message: "Forbidden origin")
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard !rawContentLength.isEmpty,
                  rawContentLength.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  let parsed = Int(rawContentLength) else {
                return .failure(status: 400, message: "Invalid Content-Length header")
            }
            guard parsed <= maxHTTPRequestBodyBytes else {
                return .failure(status: 413, message: "Payload too large")
            }
            contentLength = parsed
        } else {
            contentLength = 0
        }

        let method = parts[0].uppercased()
        let path = parts[1].split(separator: "?", maxSplits: 1).first.map(String.init) ?? parts[1]
        let isUnauthenticatedOAuthDiscovery = method == "GET"
            && contentLength == 0
            && unauthenticatedOAuthDiscoveryPaths.contains(path)
        if !isUnauthenticatedOAuthDiscovery {
            guard let providedToken = headers[fileMCPLocalAuthHeaderKey],
                  constantTimeEquals(providedToken, localAuthToken) else {
                return .failure(status: 401, message: "Unauthorized")
            }
        }

        let bodyStart = headerRange.upperBound
        let availableBodyBytes = data.count - bodyStart
        guard availableBodyBytes >= contentLength else { return .incomplete }
        guard availableBodyBytes == contentLength else {
            return .failure(status: 400, message: "Unexpected bytes after request body")
        }
        let bodyEnd = bodyStart + contentLength
        let body = data.subdata(in: bodyStart..<bodyEnd)
        return .request(HTTPRequest(method: method, path: path, headers: headers, body: body))
    }

    private func isValidHTTPHeaderName(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        let allowedPunctuation = Set("!#$%&'*+-.^_`|~".utf8)
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) ||
            allowedPunctuation.contains(byte)
        }
    }

    private func isValidHTTPHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte == 9 || (byte >= 32 && byte != 127)
        }
    }

    private func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for index in left.indices {
            difference |= left[index] ^ right[index]
        }
        return difference == 0
    }

    private func process(_ request: HTTPRequest) -> Data {
        if request.method == "OPTIONS" {
            return httpResponse(status: 204, body: Data(), contentType: "text/plain")
        }
        guard request.path == "/mcp" else {
            return httpResponse(status: 404, body: Data("Not found".utf8), contentType: "text/plain")
        }
        if request.method == "GET" || request.method == "DELETE" {
            return httpResponse(status: 405, body: Data("Method not allowed".utf8), contentType: "text/plain")
        }
        guard request.method == "POST" else {
            return httpResponse(status: 405, body: Data("Method not allowed".utf8), contentType: "text/plain")
        }
        guard isJSONContentType(request.headers["content-type"]) else {
            return httpResponse(status: 415, body: Data("Content-Type must be application/json".utf8), contentType: "text/plain")
        }

        do {
            let object = try JSONSerialization.jsonObject(with: request.body)
            guard let message = object as? [String: Any], message["jsonrpc"] as? String == "2.0" else {
                return jsonRPCError(id: NSNull(), code: -32600, message: "Invalid Request", status: 400)
            }
            guard let method = message["method"] as? String else {
                return jsonRPCError(id: message["id"] ?? NSNull(), code: -32600, message: "Invalid Request", status: 400)
            }

            let id = message["id"] ?? NSNull()
            let headerVersion = request.headers["mcp-protocol-version"]
            let headerSignalsModern = headerVersion.map { !mcpLegacySupportedVersions.contains($0) } ?? false
            let params: [String: Any]
            if let rawParams = message["params"] {
                guard let typedParams = rawParams as? [String: Any] else {
                    return jsonRPCError(
                        id: id,
                        code: -32602,
                        message: "Invalid params: expected an object",
                        status: headerSignalsModern ? 400 : 200
                    )
                }
                params = typedParams
            } else {
                params = [:]
            }
            let meta = params["_meta"] as? [String: Any]
            let bodyVersion = meta?["io.modelcontextprotocol/protocolVersion"] as? String
            let bodySignalsModern = bodyVersion.map { !mcpLegacySupportedVersions.contains($0) } ?? false
            let modernIntent = headerSignalsModern || bodySignalsModern

            if modernIntent,
               let headerVersion,
               let bodyVersion,
               headerVersion != bodyVersion {
                return headerMismatch(
                    id: id,
                    message: "MCP-Protocol-Version header '\(headerVersion)' does not match body protocol version '\(bodyVersion)'"
                )
            }

            if let headerVersion,
               headerVersion != mcpModernProtocolVersion,
               !mcpLegacySupportedVersions.contains(headerVersion) {
                return unsupportedProtocolVersion(id: id, requested: headerVersion)
            }

            if modernIntent {
                if let validationError = validateModernRequest(
                    request: request,
                    method: method,
                    params: params,
                    id: id
                ) {
                    return validationError
                }

                if message["id"] == nil {
                    return httpResponse(status: 202, body: Data(), contentType: "application/json")
                }
                return processModernRequest(id: id, method: method, params: params)
            }

            if message["id"] == nil {
                return httpResponse(status: 202, body: Data(), contentType: "application/json")
            }
            return processLegacyRequest(id: id, method: method, params: params)
        } catch {
            return jsonRPCError(id: NSNull(), code: -32700, message: "Parse error", status: 400)
        }
    }

    private func allToolDefinitions() -> [[String: Any]] {
        tools.toolDefinitions + skills.toolDefinitions
    }

    private func processLegacyRequest(id: Any, method: String, params: [String: Any]) -> Data {
        switch method {
        case "initialize":
            let requestedVersion = params["protocolVersion"] as? String ?? mcpProtocolFallback
            let negotiatedVersion = mcpLegacySupportedVersions.contains(requestedVersion)
                ? requestedVersion
                : mcpLatestLegacyProtocolVersion
            return jsonRPCResult(id: id, result: [
                "protocolVersion": negotiatedVersion,
                "capabilities": serverCapabilities(),
                "serverInfo": serverInfo(),
            ])
        case "ping":
            return jsonRPCResult(id: id, result: [:])
        case "tools/list":
            return jsonRPCResult(id: id, result: ["tools": allToolDefinitions()])
        case "tools/call":
            return callTool(id: id, params: params, modern: false)
        default:
            return jsonRPCError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func processModernRequest(id: Any, method: String, params: [String: Any]) -> Data {
        switch method {
        case "server/discover":
            var result = modernCompleteResult([
                "supportedVersions": [mcpModernProtocolVersion],
                "capabilities": serverCapabilities(),
                "instructions": "Read and manage files, Git repositories, Codex project skills, and optionally local commands inside the configured shared directory. When a user message begins with '/<skill-name>', call load_codex_skill with that exact name before answering and follow the returned SKILL.md instructions.",
            ])
            addCacheMetadata(to: &result, ttlMs: 60_000)
            return jsonRPCResult(id: id, result: result)
        case "ping":
            return jsonRPCResult(id: id, result: modernCompleteResult([:]))
        case "tools/list":
            var result = modernCompleteResult(["tools": allToolDefinitions()])
            addCacheMetadata(to: &result, ttlMs: 30_000)
            return jsonRPCResult(id: id, result: result)
        case "tools/call":
            return callTool(id: id, params: params, modern: true)
        default:
            return jsonRPCError(
                id: id,
                code: -32601,
                message: "Method not found: \(method)",
                status: 404
            )
        }
    }

    private func callTool(id: Any, params: [String: Any], modern: Bool) -> Data {
        guard let toolName = params["name"] as? String else {
            return jsonRPCError(
                id: id,
                code: -32602,
                message: "Missing tool name",
                status: modern ? 400 : 200
            )
        }
        guard tools.hasTool(named: toolName) || skills.hasTool(named: toolName) else {
            return jsonRPCError(id: id, code: -32602, message: "Unknown tool: \(toolName)")
        }
        let arguments: [String: Any]
        if let rawArguments = params["arguments"] {
            guard let typedArguments = rawArguments as? [String: Any] else {
                var result: [String: Any] = [
                    "content": [["type": "text", "text": "Invalid arguments: expected an object"]],
                    "isError": true,
                ]
                if modern { result = modernCompleteResult(result) }
                return jsonRPCResult(id: id, result: result)
            }
            arguments = typedArguments
        } else {
            arguments = [:]
        }
        do {
            let content: [[String: Any]]
            let structuredContent: [String: Any]
            if skills.hasTool(named: toolName) {
                let output = try skills.call(name: toolName, arguments: arguments)
                content = output.content
                structuredContent = output.structuredContent
            } else {
                let output = try tools.call(name: toolName, arguments: arguments)
                content = output.content
                structuredContent = output.structuredContent
            }
            var result: [String: Any] = [
                "content": content,
                "structuredContent": structuredContent,
                "isError": false,
            ]
            if modern { result = modernCompleteResult(result) }
            return jsonRPCResult(id: id, result: result)
        } catch {
            if skills.hasTool(named: toolName) {
                log("[Skills] ERROR: \(error.localizedDescription)\n")
            }
            var result: [String: Any] = [
                "content": [["type": "text", "text": error.localizedDescription]],
                "isError": true,
            ]
            if modern { result = modernCompleteResult(result) }
            return jsonRPCResult(id: id, result: result)
        }
    }

    private func validateModernRequest(
        request: HTTPRequest,
        method: String,
        params: [String: Any],
        id: Any
    ) -> Data? {
        guard let headerVersion = request.headers["mcp-protocol-version"] else {
            return headerMismatch(id: id, message: "Missing required MCP-Protocol-Version header")
        }
        guard headerVersion == mcpModernProtocolVersion else {
            if mcpLegacySupportedVersions.contains(headerVersion) {
                return headerMismatch(
                    id: id,
                    message: "MCP-Protocol-Version header does not match the modern request metadata"
                )
            }
            return unsupportedProtocolVersion(id: id, requested: headerVersion)
        }

        guard let meta = params["_meta"] as? [String: Any] else {
            return jsonRPCError(id: id, code: -32602, message: "Missing required params._meta", status: 400)
        }
        guard let bodyVersion = meta["io.modelcontextprotocol/protocolVersion"] as? String else {
            return jsonRPCError(id: id, code: -32602, message: "Missing required _meta.io.modelcontextprotocol/protocolVersion", status: 400)
        }
        guard bodyVersion == mcpModernProtocolVersion else {
            if bodyVersion == headerVersion { return unsupportedProtocolVersion(id: id, requested: bodyVersion) }
            return headerMismatch(
                id: id,
                message: "MCP-Protocol-Version header '\(headerVersion)' does not match body protocol version '\(bodyVersion)'"
            )
        }
        guard meta["io.modelcontextprotocol/clientCapabilities"] is [String: Any] else {
            return jsonRPCError(id: id, code: -32602, message: "Missing required _meta.io.modelcontextprotocol/clientCapabilities", status: 400)
        }
        if let clientInfo = meta["io.modelcontextprotocol/clientInfo"] {
            guard let implementation = clientInfo as? [String: Any],
                  implementation["name"] is String,
                  implementation["version"] is String else {
                return jsonRPCError(id: id, code: -32602, message: "Invalid _meta.io.modelcontextprotocol/clientInfo", status: 400)
            }
        }

        guard let methodHeader = request.headers["mcp-method"] else {
            return headerMismatch(id: id, message: "Missing required Mcp-Method header")
        }
        guard methodHeader == method else {
            return headerMismatch(
                id: id,
                message: "Mcp-Method header '\(methodHeader)' does not match body method '\(method)'"
            )
        }

        if method == "tools/call" {
            guard let toolName = params["name"] as? String else {
                return jsonRPCError(id: id, code: -32602, message: "Missing tool name", status: 400)
            }
            guard let encodedName = request.headers["mcp-name"] else {
                return headerMismatch(id: id, message: "Missing required Mcp-Name header")
            }
            guard let decodedName = decodeHeaderValue(encodedName) else {
                return headerMismatch(id: id, message: "Malformed Mcp-Name header")
            }
            guard decodedName == toolName else {
                return headerMismatch(
                    id: id,
                    message: "Mcp-Name header value '\(decodedName)' does not match body value '\(toolName)'"
                )
            }
        }
        return nil
    }

    private func modernCompleteResult(_ fields: [String: Any]) -> [String: Any] {
        var result = fields
        result["resultType"] = "complete"
        result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo()]
        return result
    }

    private func addCacheMetadata(to result: inout [String: Any], ttlMs: Int) {
        result["ttlMs"] = ttlMs
        result["cacheScope"] = "private"
    }

    private func serverInfo() -> [String: Any] {
        ["name": mcpServerName, "version": mcpServerVersion]
    }

    private func serverCapabilities() -> [String: Any] {
        ["tools": ["listChanged": false]]
    }

    private func isAllowedHost(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return false }

        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else { return false }
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart..<closingBracket])
            let remainder = String(trimmed[trimmed.index(after: closingBracket)...])
            guard remainder.isEmpty || (remainder.hasPrefix(":") && isValidHTTPPort(remainder.dropFirst())) else { return false }
            return host == "::1"
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 1 || (parts.count == 2 && isValidHTTPPort(parts[1])) else { return false }
        let host = String(parts[0])
        return host == "localhost" || host == "127.0.0.1"
    }

    private func isValidHTTPPort<S: StringProtocol>(_ value: S) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let port = UInt32(value) else { return false }
        return port <= 65_535
    }

    private func isJSONContentType(_ value: String?) -> Bool {
        guard let value else { return false }
        let mediaType = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mediaType == "application/json"
    }

    private func isAllowedOrigin(_ origin: String) -> Bool {
        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil else {
            return false
        }

        if (scheme == "http" || scheme == "https"),
           host == "localhost" || host == "127.0.0.1" || host == "::1" {
            return components.port.map { (0...65_535).contains($0) } ?? true
        }
        if scheme == "https", host == "chatgpt.com" || host.hasSuffix(".chatgpt.com") {
            return components.port == nil || components.port == 443
        }
        return false
    }

    private func decodeHeaderValue(_ value: String) -> String? {
        let prefix = "=?base64?"
        let suffix = "?="
        if value.hasPrefix(prefix), value.hasSuffix(suffix) {
            let start = value.index(value.startIndex, offsetBy: prefix.count)
            let end = value.index(value.endIndex, offsetBy: -suffix.count)
            let payload = String(value[start..<end])
            guard let data = Data(base64Encoded: payload) else { return nil }
            return String(data: data, encoding: .utf8)
        }

        guard value.unicodeScalars.allSatisfy({ scalar in
            scalar.value == 9 || (scalar.value >= 32 && scalar.value <= 126)
        }) else { return nil }
        return value
    }

    private func headerMismatch(id: Any, message: String) -> Data {
        jsonRPCError(id: id, code: -32020, message: "Header mismatch: \(message)", status: 400)
    }

    private func unsupportedProtocolVersion(id: Any, requested: String) -> Data {
        jsonRPCError(
            id: id,
            code: -32022,
            message: "Unsupported protocol version: \(requested)",
            data: ["supported": mcpAllSupportedVersions, "requested": requested],
            status: 400
        )
    }

    private func jsonRPCResult(id: Any, result: Any) -> Data {
        jsonResponse(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func jsonRPCError(
        id: Any,
        code: Int,
        message: String,
        data: Any? = nil,
        status: Int = 200
    ) -> Data {
        var error: [String: Any] = ["code": code, "message": message]
        if let data { error["data"] = data }
        return jsonResponse(["jsonrpc": "2.0", "id": id, "error": error], status: status)
    }

    private func jsonResponse(_ object: Any, status: Int = 200) -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: object, options: [])) ?? Data("{}".utf8)
        return httpResponse(status: status, body: body, contentType: "application/json")
    }

    private func httpResponse(status: Int, body: Data, contentType: String) -> Data {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 202: reason = "Accepted"
        case 204: reason = "No Content"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 405: reason = "Method Not Allowed"
        case 413: reason = "Payload Too Large"
        case 415: reason = "Unsupported Media Type"
        case 431: reason = "Request Header Fields Too Large"
        default: reason = "Error"
        }
        let header = "HTTP/1.1 \(status) \(reason)\r\n" +
            "Content-Type: \(contentType)\r\n" +
            "Content-Length: \(body.count)\r\n" +
            "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        return response
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

struct CodexSkillToolOutput {
    let content: [[String: Any]]
    let structuredContent: [String: Any]
}

private struct CodexSkillInfo {
    let name: String
    let description: String
    let skillFile: String
}

private enum CodexSkillError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case let .invalid(message): return message } }
}

final class CodexSkillRegistry {
    static let maxSkillBytes = 256 * 1024
    private let root: URL
    private let rootPath: String
    private let log: (String) -> Void
    private let lock = NSLock()
    private var skills: [CodexSkillInfo] = []

    init(rootPath: String, log: @escaping (String) -> Void) throws {
        let expanded = NSString(string: rootPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        root = url.resolvingSymlinksInPath().standardizedFileURL
        self.rootPath = root.path
        self.log = log
    }

    var toolDefinitions: [[String: Any]] {
        [
            [
                "name": "list_codex_skills",
                "description": "List Codex project skills discovered under .agents/skills in the current shared workspace. If the user's message starts with '/<skill-name>', use this list when needed to resolve the requested skill before answering.",
                "inputSchema": ["type": "object", "properties": [:], "required": [], "additionalProperties": false],
                "outputSchema": ["type": "object", "additionalProperties": true],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ],
            [
                "name": "load_codex_skill",
                "description": "Load a Codex Agent Skill from .agents/skills/<name>/SKILL.md in the current shared workspace. IMPORTANT: when the user's message starts with '/<skill-name>', call this tool with <skill-name> before answering, then follow the returned SKILL.md instructions for the current task. The name is a skill identifier, not a path.",
                "inputSchema": [
                    "type": "object",
                    "properties": ["name": ["type": "string", "description": "Exact skill directory name under .agents/skills, for example speckit-analyze."]],
                    "required": ["name"],
                    "additionalProperties": false,
                ],
                "outputSchema": ["type": "object", "additionalProperties": true],
                "annotations": ["readOnlyHint": true, "destructiveHint": false, "openWorldHint": false],
            ],
        ]
    }

    func hasTool(named name: String) -> Bool { name == "list_codex_skills" || name == "load_codex_skill" }

    @discardableResult
    func refresh() -> Int {
        log("[Skills] Scanning .agents/skills...\n")
        var found: [CodexSkillInfo] = []
        let fileManager = FileManager.default
        let skillsRoot: URL
        do { skillsRoot = try resolve(".agents/skills") }
        catch {
            setSkills([])
            log("[Skills] Scan failed: \(error.localizedDescription)\n")
            return 0
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: skillsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            setSkills([])
            log("[Skills] No Codex skills found in .agents/skills.\n")
            return 0
        }
        let directories: [URL]
        do {
            directories = try fileManager.contentsOfDirectory(
                at: skillsRoot,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
            ).sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
        } catch {
            setSkills([])
            log("[Skills] Scan failed: \(error.localizedDescription)\n")
            return 0
        }
        for directory in directories {
            let name = directory.lastPathComponent
            guard Self.validSkillName(name) else {
                log("[Skills] Ignoring invalid skill directory name: \(name)\n")
                continue
            }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true, contains(directory) else {
                    log("[Skills] Refused unsafe skill directory: \(name)\n")
                    continue
                }
                let relative = ".agents/skills/\(name)/SKILL.md"
                let skillURL = try resolve(relative)
                let skillValues = try skillURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard skillValues.isRegularFile == true, skillValues.isSymbolicLink != true else { continue }
                let size = skillValues.fileSize ?? 0
                guard size <= Self.maxSkillBytes else {
                    log("[Skills] Ignoring oversized SKILL.md: \(name) (\(size) bytes)\n")
                    continue
                }
                let text = try Self.readUTF8(skillURL)
                let metadata = Self.parseFrontmatter(text)
                if let frontmatterName = metadata.name, frontmatterName != name {
                    log("[Skills] Ignoring \(name): frontmatter name '\(frontmatterName)' does not match directory name.\n")
                    continue
                }
                found.append(CodexSkillInfo(name: name, description: metadata.description ?? "", skillFile: relative))
                log("[Skills] Found: \(name)\n")
            } catch {
                log("[Skills] Invalid SKILL.md for \(name): \(error.localizedDescription)\n")
            }
        }
        setSkills(found)
        log("[Skills] Loaded \(found.count) Codex skill\(found.count == 1 ? "" : "s").\n")
        return found.count
    }

    func call(name: String, arguments: [String: Any]) throws -> CodexSkillToolOutput {
        switch name {
        case "list_codex_skills":
            guard arguments.isEmpty else { throw CodexSkillError.invalid("Unexpected argument") }
            return objectOutput(listSkills())
        case "load_codex_skill":
            guard arguments.count == 1, let skillName = arguments["name"] as? String else { throw CodexSkillError.invalid("Missing or invalid argument: name") }
            return objectOutput(try loadSkill(skillName))
        default:
            throw CodexSkillError.invalid("Unknown skill tool: \(name)")
        }
    }

    private func listSkills() -> [String: Any] {
        let snapshot = getSkills()
        return ["skills": snapshot.map { ["name": $0.name, "description": $0.description, "skill_file": $0.skillFile] }, "count": snapshot.count]
    }

    private func loadSkill(_ name: String) throws -> [String: Any] {
        guard Self.validSkillName(name) else { throw CodexSkillError.invalid("Invalid Codex skill name") }
        var skill = getSkills().first { $0.name == name }
        if skill == nil {
            refresh()
            skill = getSkills().first { $0.name == name }
        }
        guard let skill else { throw CodexSkillError.invalid("Codex skill not found: \(name)") }
        let skillURL = try resolve(skill.skillFile)
        let values = try skillURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CodexSkillError.invalid("Codex skill not found: \(name)") }
        guard (values.fileSize ?? 0) <= Self.maxSkillBytes else { throw CodexSkillError.invalid("SKILL.md is larger than the 256 KB skill limit") }
        let instructions = try Self.readUTF8(skillURL)
        log("[Skills] Loading skill: \(name)\n")
        log("[Skills] Loaded: \(skill.skillFile)\n")
        return [
            "name": skill.name,
            "description": skill.description,
            "skill_directory": ".agents/skills/\(skill.name)",
            "skill_file": skill.skillFile,
            "instructions": instructions,
        ]
    }

    private func objectOutput(_ value: [String: Any]) -> CodexSkillToolOutput {
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return CodexSkillToolOutput(content: [["type": "text", "text": text]], structuredContent: value)
    }

    private func resolve(_ relativePath: String) throws -> URL {
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let canonical = canonicalizeExistingAncestor(of: candidate)
        guard containsCanonicalPath(canonical.path) else { throw CodexSkillError.invalid("Refused: path is outside the shared directory") }
        return canonical
    }
    private func contains(_ url: URL) -> Bool { containsCanonicalPath(canonicalizeExistingAncestor(of: url.standardizedFileURL).path) }
    private func containsCanonicalPath(_ path: String) -> Bool { path == rootPath || path.hasPrefix(rootPath + "/") }
    private func canonicalizeExistingAncestor(of url: URL) -> URL {
        var ancestor = url
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            if parent.path == ancestor.path { break }
            suffix.insert(ancestor.lastPathComponent, at: 0)
            ancestor = parent
        }
        var resolved = ancestor.resolvingSymlinksInPath().standardizedFileURL
        for component in suffix { resolved.appendPathComponent(component) }
        return resolved.standardizedFileURL
    }
    private func setSkills(_ value: [CodexSkillInfo]) { lock.lock(); skills = value; lock.unlock() }
    private func getSkills() -> [CodexSkillInfo] { lock.lock(); defer { lock.unlock() }; return skills }

    private static func validSkillName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 128 else { return false }
        guard let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first) else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || ".-_".unicodeScalars.contains($0) }
    }
    private static func readUTF8(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        guard data.count <= maxSkillBytes else { throw CodexSkillError.invalid("SKILL.md is larger than the 256 KB skill limit") }
        guard let text = String(data: data, encoding: .utf8) else { throw CodexSkillError.invalid("SKILL.md must be valid UTF-8") }
        return text
    }
    private static func parseFrontmatter(_ text: String) -> (name: String?, description: String?) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard normalized.hasPrefix("---\n"), let range = normalized.range(of: "\n---\n", range: normalized.index(normalized.startIndex, offsetBy: 4)..<normalized.endIndex) else { return (nil, nil) }
        let body = normalized[normalized.index(normalized.startIndex, offsetBy: 4)..<range.lowerBound]
        var name: String?; var description: String?
        for raw in body.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let colon = raw.firstIndex(of: ":") else { continue }
            let key = raw[..<colon].trimmingCharacters(in: .whitespaces)
            var value = raw[raw.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) { value = String(value.dropFirst().dropLast()) }
            if key == "name" { name = value }
            else if key == "description" { description = value }
        }
        return (name, description)
    }
}
