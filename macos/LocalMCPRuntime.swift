import Foundation
import Darwin
import Security

struct LocalMCPConfiguration {
    let tunnelID: String
    let apiKey: String
    let profile: String
    let port: UInt16
    let allowedDirectory: String
    let healthAddress: String
    let gitUserName: String
    let gitUserEmail: String
    let enableCommands: Bool
}

enum LocalMCPRuntimeState: Equatable {
    case stopped
    case starting
    case running
    case stopping
    case failed(String)
}

private final class ProfileLock {
    private let path: String
    private var descriptor: Int32 = -1

    init(profile: String) {
        let digest = profile.utf8.reduce(UInt64(1469598103934665603)) { hash, byte in
            (hash ^ UInt64(byte)) &* 1099511628211
        }
        // Keep the pre-rebrand lock namespace so FileMCP and older builds cannot use the same profile concurrently.
        let directory = (NSTemporaryDirectory() as NSString).appendingPathComponent("local-files-mcp-locks")
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        path = (directory as NSString).appendingPathComponent(String(format: "%016llx.lock", digest))
    }

    func acquire() throws {
        guard descriptor < 0 else { return }
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            throw lockError("Could not open the profile lock", code: errno)
        }

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(fd)
            if code == EWOULDBLOCK || code == EAGAIN {
                throw NSError(
                    domain: "FileMCP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "This tunnel profile is already in use by another FileMCP instance."]
                )
            }
            throw lockError("Could not acquire the profile lock", code: code)
        }

        _ = fchmod(fd, S_IRUSR | S_IWUSR)
        _ = ftruncate(fd, 0)
        let text = String(getpid())
        _ = text.withCString { pointer in
            write(fd, pointer, strlen(pointer))
        }
        descriptor = fd
    }

    func release() {
        guard descriptor >= 0 else { return }
        let fd = descriptor
        descriptor = -1
        _ = flock(fd, LOCK_UN)
        close(fd)
    }

    private func lockError(_ prefix: String, code: Int32) -> NSError {
        NSError(
            domain: "FileMCP",
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(prefix): \(String(cString: strerror(code)))"]
        )
    }

    deinit {
        release()
    }
}

final class LocalMCPRuntime {
    private let queue = DispatchQueue(label: "com.filemcp.runtime", qos: .userInitiated)
    private let queueSpecificKey = DispatchSpecificKey<Void>()
    private let stateLock = NSLock()
    private let stopRequestLock = NSLock()
    private var _state: LocalMCPRuntimeState = .stopped
    private var server: LocalMCPServer?
    private var tunnelProcess: ManagedProcess?
    private var profileLock: ProfileLock?
    private var requestedStop = false
    private let profileDirectoryOverride: URL?

    var onStateChange: ((LocalMCPRuntimeState) -> Void)?
    var onLog: ((String) -> Void)?

    init(profileDirectory: URL? = nil) {
        profileDirectoryOverride = profileDirectory
        queue.setSpecific(key: queueSpecificKey, value: ())
    }

    var state: LocalMCPRuntimeState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    func start(_ configuration: LocalMCPConfiguration) {
        queue.async { [weak self] in
            self?.startOnQueue(configuration)
        }
    }

    func stop() {
        setStopRequested(true)
        queue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .stopped:
                self.setStopRequested(false)
                return
            case .stopping:
                return
            default:
                break
            }
            self.setState(.stopping)
            self.tunnelProcess?.stop()
            if self.tunnelProcess == nil {
                self.finishStop()
            }
        }
    }

    func shutdownImmediately() {
        setStopRequested(true)
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            shutdownOnQueue()
        } else {
            queue.sync { shutdownOnQueue() }
        }
    }

    private func shutdownOnQueue() {
        tunnelProcess?.stopSynchronously()
        server?.stop()
        server = nil
        profileLock?.release()
        profileLock = nil

        if tunnelProcess == nil {
            setStopRequested(false)
            setState(.stopped)
        }
    }

    private func startOnQueue(_ configuration: LocalMCPConfiguration) {
        guard state == .stopped || isFailedState(state) else { return }
        if isStopRequested {
            setStopRequested(false)
            return
        }
        setState(.starting)

        do {
            let healthAddress = try validateConfiguration(configuration)
            let lock = ProfileLock(profile: configuration.profile)
            try lock.acquire()
            profileLock = lock

            let localAuthToken = try makeLocalAuthToken()
            let server = try LocalMCPServer(
                port: configuration.port,
                allowedDirectory: configuration.allowedDirectory,
                gitUserName: configuration.gitUserName,
                gitUserEmail: configuration.gitUserEmail,
                enableCommands: configuration.enableCommands,
                localAuthToken: localAuthToken,
                log: { [weak self] text in self?.emitLog(text) }
            )
            try server.start()
            self.server = server

            let tunnelClient = try tunnelClientPath()
            let profileDirectory = try tunnelProfileDirectory()
            var environment = tunnelClientEnvironment(
                apiKey: configuration.apiKey,
                localAuthToken: localAuthToken
            )
            let localAuthHeader = "\(fileMCPLocalAuthHeaderName): env:FILEMCP_LOCAL_AUTH_TOKEN"
            environment["MCP_EXTRA_HEADERS"] = localAuthHeader
            environment["MCP_DISCOVERY_EXTRA_HEADERS"] = localAuthHeader
            let sensitiveValues = [configuration.apiKey, localAuthToken].filter { !$0.isEmpty }

            let initArguments = [
                "init",
                "--sample", "sample_mcp_remote_no_auth",
                "--profile", configuration.profile,
                "--profile-dir", profileDirectory,
                "--force",
                "--tunnel-id", configuration.tunnelID,
                "--mcp-server-url", "http://127.0.0.1:\(configuration.port)/mcp",
                "--health-listen-addr", healthAddress,
            ]
            emitLog("Configuring Secure MCP Tunnel…\n")
            let initResult = try ProcessRunner.run(
                executable: tunnelClient,
                arguments: initArguments,
                environment: environment,
                timeoutSeconds: 30,
                outputLimitBytes: 250_000,
                shouldCancel: { [weak self] in self?.isStopRequested ?? true }
            )
            if isStopRequested {
                finishStop()
                return
            }
            try requireSuccess(initResult, operation: "tunnel-client init", sensitiveValues: sensitiveValues)

            emitLog("Checking tunnel configuration…\n")
            let doctorResult = try ProcessRunner.run(
                executable: tunnelClient,
                arguments: [
                    "doctor",
                    "--profile", configuration.profile,
                    "--profile-dir", profileDirectory,
                    "--health-listen-addr", healthAddress,
                    "--explain",
                ],
                environment: environment,
                timeoutSeconds: 30,
                outputLimitBytes: 250_000,
                shouldCancel: { [weak self] in self?.isStopRequested ?? true }
            )
            if isStopRequested {
                finishStop()
                return
            }
            try requireSuccess(doctorResult, operation: "tunnel-client doctor", sensitiveValues: sensitiveValues)

            let managed = try ProcessRunner.startManaged(
                executable: tunnelClient,
                arguments: [
                    "run",
                    "--profile", configuration.profile,
                    "--profile-dir", profileDirectory,
                    "--health-listen-addr", healthAddress,
                ],
                environment: environment,
                onOutput: { [weak self] text in
                    guard let self else { return }
                    self.emitLog(self.redactSensitiveValues(text, sensitiveValues: sensitiveValues))
                },
                onExit: { [weak self] exitCode in
                    self?.queue.async {
                        self?.tunnelDidExit(exitCode: exitCode)
                    }
                }
            )
            tunnelProcess = managed
            setState(.running)
            emitLog("OpenAI Secure MCP Tunnel started. Command execution: \(configuration.enableCommands ? "enabled" : "disabled").\n")
        } catch {
            if isStopRequested {
                finishStop()
                return
            }
            server?.stop()
            server = nil
            tunnelProcess = nil
            profileLock?.release()
            profileLock = nil
            setState(.failed(error.localizedDescription))
            emitLog("ERROR: \(error.localizedDescription)\n")
        }
    }

    private func tunnelDidExit(exitCode: Int32) {
        tunnelProcess = nil
        server?.stop()
        server = nil
        profileLock?.release()
        profileLock = nil

        if isStopRequested {
            setStopRequested(false)
            setState(.stopped)
            emitLog("Tunnel stopped.\n")
        } else if exitCode == 0 {
            setState(.stopped)
            emitLog("Tunnel stopped.\n")
        } else {
            let message = "Tunnel stopped unexpectedly (exit status \(exitCode))."
            setState(.failed(message))
            emitLog(message + "\n")
        }
    }

    private func finishStop() {
        server?.stop()
        server = nil
        tunnelProcess = nil
        profileLock?.release()
        profileLock = nil
        setStopRequested(false)
        setState(.stopped)
        emitLog("Tunnel stopped.\n")
    }

    private var isStopRequested: Bool {
        stopRequestLock.lock()
        defer { stopRequestLock.unlock() }
        return requestedStop
    }

    private func setStopRequested(_ value: Bool) {
        stopRequestLock.lock()
        requestedStop = value
        stopRequestLock.unlock()
    }

    private func validateConfiguration(_ configuration: LocalMCPConfiguration) throws -> String {
        let requiredValues = [
            ("Tunnel ID", configuration.tunnelID),
            ("Runtime API key", configuration.apiKey),
            ("Profile", configuration.profile),
            ("Shared directory", configuration.allowedDirectory),
        ]
        for (label, value) in requiredValues where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(label) cannot be empty."]
            )
        }
        guard Self.isValidTunnelID(configuration.tunnelID) else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Tunnel ID must match tunnel_<32 lowercase letters or digits>."]
            )
        }
        guard Self.isValidProfileName(configuration.profile) else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Profile must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 128 characters)."]
            )
        }
        guard configuration.port > 0 else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MCP port must be between 1 and 65535."]
            )
        }
        guard let healthAddress = Self.normalizedHealthAddress(configuration.healthAddress) else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Health listener must use localhost, 127.0.0.1, or [::1] with a port from 0 to 65535."]
            )
        }
        return healthAddress
    }

    static func isValidTunnelID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("tunnel_".utf8)
        guard bytes.count == prefix.count + 32, bytes.starts(with: prefix) else { return false }
        return bytes.dropFirst(prefix.count).allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
        }
    }

    static func isValidProfileName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...128).contains(bytes.count), let first = bytes.first else { return false }
        func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) ||
            (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122)
        }
        guard isAlphaNumeric(first) else { return false }
        return bytes.dropFirst().allSatisfy { byte in
            isAlphaNumeric(byte) || byte == 46 || byte == 95 || byte == 45
        }
    }

    static func normalizedHealthAddress(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "127.0.0.1:0" }

        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else { return nil }
            let hostStart = trimmed.index(after: trimmed.startIndex)
            let host = String(trimmed[hostStart..<closingBracket]).lowercased()
            let remainder = trimmed[trimmed.index(after: closingBracket)...]
            guard host == "::1", remainder.first == ":", validHealthPort(String(remainder.dropFirst())) else { return nil }
            return "[::1]:\(remainder.dropFirst())"
        }

        let parts = trimmed.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let host = String(parts[0]).lowercased()
        guard host == "127.0.0.1" || host == "localhost", validHealthPort(String(parts[1])) else { return nil }
        return "\(host):\(parts[1])"
    }

    private static func validHealthPort(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let port = UInt32(value) else { return false }
        return port <= 65_535
    }

    private func requireSuccess(
        _ result: ProcessResult,
        operation: String,
        sensitiveValues: [String]
    ) throws {
        if result.timedOut {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(operation) timed out."]
            )
        }
        guard result.exitCode == 0 else {
            let detail = !result.stderr.isEmpty ? result.stderr : result.stdout
            let safeDetail = redactSensitiveValues(detail, sensitiveValues: sensitiveValues)
            throw NSError(
                domain: "FileMCP",
                code: Int(result.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(safeDetail)"]
            )
        }
        if !result.stdout.isEmpty {
            let safeOutput = redactSensitiveValues(result.stdout, sensitiveValues: sensitiveValues)
            emitLog(safeOutput + (safeOutput.hasSuffix("\n") ? "" : "\n"))
        }
        if !result.stderr.isEmpty {
            let safeOutput = redactSensitiveValues(result.stderr, sensitiveValues: sensitiveValues)
            emitLog(safeOutput + (safeOutput.hasSuffix("\n") ? "" : "\n"))
        }
    }

    private func redactSensitiveValues(_ text: String, sensitiveValues: [String]) -> String {
        sensitiveValues.reduce(text) { redacted, secret in
            guard !secret.isEmpty else { return redacted }
            return redacted.replacingOccurrences(of: secret, with: "[REDACTED]")
        }
    }

    private func tunnelClientEnvironment(apiKey: String, localAuthToken: String) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        let passThroughKeys = [
            "PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY",
            "http_proxy", "https_proxy", "all_proxy",
        ]
        var environment: [String: String] = [:]
        for key in passThroughKeys {
            if let value = inherited[key], !value.isEmpty { environment[key] = value }
        }
        for (key, value) in inherited where key.hasPrefix("MCP_TEST_") {
            environment[key] = value
        }

        var noProxyEntries = (inherited["NO_PROXY"] ?? inherited["no_proxy"] ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for loopback in ["127.0.0.1", "localhost", "::1"] where !noProxyEntries.contains(loopback) {
            noProxyEntries.append(loopback)
        }
        let noProxy = noProxyEntries.joined(separator: ",")
        environment["NO_PROXY"] = noProxy
        environment["no_proxy"] = noProxy
        environment["CONTROL_PLANE_API_KEY"] = apiKey
        environment["FILEMCP_LOCAL_AUTH_TOKEN"] = localAuthToken
        return environment
    }

    private func tunnelProfileDirectory() throws -> String {
        let directory: URL
        if let profileDirectoryOverride {
            directory = profileDirectoryOverride.standardizedFileURL
        } else {
            guard let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                throw NSError(
                    domain: "FileMCP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not locate the user Application Support directory."]
                )
            }
            directory = applicationSupport
                .appendingPathComponent("FileMCP", isDirectory: true)
                .appendingPathComponent("tunnel-profiles", isDirectory: true)
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        return directory.path
    }

    private func tunnelClientPath() throws -> String {
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        let sibling = executableURL.deletingLastPathComponent().appendingPathComponent("tunnel-client").path
        if FileManager.default.isExecutableFile(atPath: sibling) {
            return sibling
        }

        if let override = ProcessInfo.processInfo.environment["MCP_TUNNEL_CLIENT"],
           FileManager.default.isExecutableFile(atPath: override) {
            return override
        }

        throw NSError(
            domain: "FileMCP",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "tunnel-client was not found inside the app bundle."]
        )
    }

    private func makeLocalAuthToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let byteCount = bytes.count
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else {
            throw NSError(
                domain: "FileMCP",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Could not generate the local MCP authentication token (OSStatus \(status))."]
            )
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private func emitLog(_ text: String) {
        onLog?(text)
    }

    private func setState(_ state: LocalMCPRuntimeState) {
        stateLock.lock()
        _state = state
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    private func isFailedState(_ state: LocalMCPRuntimeState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}
