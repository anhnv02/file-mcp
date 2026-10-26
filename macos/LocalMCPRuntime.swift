import Foundation
import Darwin
import Security

enum TunnelProvider: String {
    case openAI = "openai"
    case cloudflare = "cloudflare"
}

struct LocalMCPConfiguration {
    var provider: TunnelProvider = .openAI
    let tunnelID: String
    let apiKey: String
    // Cloudflare provider only.
    var cloudflareToken: String = ""
    var cloudflareHostname: String = ""
    var cloudflarePathSecret: String = ""
    var allowCloudflareURLSecret: Bool = false
    var cloudflareOAuthState: Data? = nil
    var saveCloudflareOAuthState: ((Data) throws -> Void)? = nil
    let profile: String
    let port: UInt16
    let allowedDirectory: String
    let healthAddress: String
    let gitUserName: String
    let gitUserEmail: String
    let enableCommands: Bool
    var enableGitPush: Bool = false
    var enableCodexHistory: Bool = false
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
    private var sleepActivity: NSObjectProtocol?
    private var requestedStop = false
    private let recentOutputLock = NSLock()
    private var recentOutputLines: [String] = []
    private var cloudflaredTokenFile: String?
    private var tunnelAttempt = UUID()
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
        removeCloudflaredTokenFile()
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
        tunnelAttempt = UUID()
        setState(.starting)
        recentOutputLock.lock()
        recentOutputLines = []
        recentOutputLock.unlock()

        do {
            let healthAddress = try validateConfiguration(configuration)
            let lock = ProfileLock(profile: configuration.profile)
            try lock.acquire()
            profileLock = lock

            let localAuthToken = try makeLocalAuthToken()
            let isCloudflare = configuration.provider == .cloudflare
            let oauth: LocalMCPOAuthServer?
            if isCloudflare && !configuration.allowCloudflareURLSecret {
                let permissions = "Read, edit and delete files in the shared folder."
                    + (configuration.enableCommands ? " Run shell commands with your macOS user privileges." : " Shell commands are disabled.")
                    + (configuration.enableGitPush ? " Push code to configured remote servers." : "")
                    + (configuration.enableCodexHistory ? " Write conversations to Codex history outside the folder." : "")
                let policy = Self.canonicalWorkspacePath(configuration.allowedDirectory) + "|" + permissions
                oauth = try LocalMCPOAuthServer(issuer: "https://" + configuration.cloudflareHostname,
                    pairingSecret: configuration.cloudflarePathSecret, policy: policy, permissionDescription: permissions,
                    persistedState: configuration.cloudflareOAuthState, persist: configuration.saveCloudflareOAuthState)
            } else { oauth = nil }
            let server = try LocalMCPServer(
                port: configuration.port,
                allowedDirectory: configuration.allowedDirectory,
                gitUserName: configuration.gitUserName,
                gitUserEmail: configuration.gitUserEmail,
                enableCommands: configuration.enableCommands,
                enableGitPush: configuration.enableGitPush,
                enableCodexHistory: configuration.enableCodexHistory,
                localAuthToken: localAuthToken,
                publicHost: isCloudflare ? configuration.cloudflareHostname : nil,
                pathSecret: isCloudflare && configuration.allowCloudflareURLSecret ? configuration.cloudflarePathSecret : nil,
                oauth: oauth,
                log: { [weak self] text in self?.emitLog(text) }
            )
            try server.start()
            self.server = server

            if isCloudflare {
                try startCloudflared(configuration)
                return
            }

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
                sensitiveValues: sensitiveValues,
                onOutput: { [weak self] text in
                    guard let self else { return }
                    let safe = self.redactSensitiveValues(text, sensitiveValues: sensitiveValues)
                    self.recordOutput(safe)
                    self.emitLog(safe)
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
            removeCloudflaredTokenFile()
            profileLock?.release()
            profileLock = nil
            setState(.failed(error.localizedDescription))
            emitLog("ERROR: \(error.localizedDescription)\n")
        }
    }

    private func startCloudflared(_ configuration: LocalMCPConfiguration) throws {
        let cloudflared = try CloudflareCLI.locate()
        let isNamedTunnel = Self.isCloudflareTunnelName(configuration.cloudflareToken)
        let sensitiveValues = [
            isNamedTunnel ? "" : configuration.cloudflareToken, configuration.cloudflarePathSecret,
        ].filter { !$0.isEmpty }
        var environment = CloudflareCLI.environment()
        var arguments = ["tunnel", "--no-autoupdate"]
        if isNamedTunnel {
            // CLI-created (locally-managed) tunnel: ingress lives in a config file, credentials in ~/.cloudflared.
            let credentials = try CloudflareCLI.credentialsPath(tunnel: configuration.cloudflareToken, shouldCancel: { [weak self] in self?.isStopRequested ?? true })
            let configPath = try writeCloudflaredConfig(configuration)
            arguments += ["--config", configPath, "run", "--credentials-file", credentials, configuration.cloudflareToken]
        } else if CloudflareCLI.supportsTokenFile(cloudflared, shouldCancel: { [weak self] in self?.isStopRequested ?? true }) {
            // Neither argv nor the environment: both can be read back from a running process
            // (`ps -E`). The file is removed once the tunnel has connected.
            arguments += ["run", "--token-file", try writeCloudflaredTokenFile(configuration)]
        } else {
            emitLog("WARNING: this cloudflared does not support --token-file, so the tunnel token is passed in the process environment. Update cloudflared (brew upgrade cloudflared).\n")
            environment["TUNNEL_TOKEN"] = configuration.cloudflareToken
            arguments.append("run")
        }

        if isStopRequested {
            finishStop()
            return
        }
        let attempt = tunnelAttempt
        let connectionMonitor = CloudflareConnectionMonitor()
        emitLog("Starting Cloudflare Tunnel…\n")
        let managed = try ProcessRunner.startManaged(
            executable: cloudflared,
            arguments: arguments,
            environment: environment,
            sensitiveValues: sensitiveValues,
            onOutput: { [weak self] text in
                guard let self else { return }
                let safe = self.redactSensitiveValues(text, sensitiveValues: sensitiveValues)
                self.recordOutput(safe)
                self.emitLog(safe)
                if connectionMonitor.consume(text) {
                    self.queue.async {
                        guard self.tunnelAttempt == attempt, self.state == .starting, !self.isStopRequested else { return }
                        self.removeCloudflaredTokenFile()
                        self.setState(.running)
                        self.emitLog("Cloudflare Tunnel connected.\n")
                    }
                }
            },
            onExit: { [weak self] exitCode in
                self?.queue.async {
                    self?.tunnelDidExit(exitCode: exitCode)
                }
            }
        )
        tunnelProcess = managed
        emitLog("Waiting for Cloudflare to register the tunnel connection. Public hostname \(configuration.cloudflareHostname) must route to this tunnel and, for token tunnels, point at http://127.0.0.1:\(configuration.port) in the Cloudflare dashboard. Command execution: \(configuration.enableCommands ? "enabled" : "disabled").\n")
    }

    /// Tunnel tokens are long base64 blobs; anything short that looks like a name or UUID is a CLI tunnel.
    static func isCloudflareTunnelName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1...100).contains(bytes.count), let first = bytes.first else { return false }
        func isAlphaNumeric(_ byte: UInt8) -> Bool {
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122)
        }
        guard isAlphaNumeric(first) else { return false }
        return bytes.allSatisfy { isAlphaNumeric($0) || $0 == 46 || $0 == 95 || $0 == 45 }
    }

    private func writeCloudflaredConfig(_ configuration: LocalMCPConfiguration) throws -> String {
        let directory = try tunnelProfileDirectory()
        let path = (directory as NSString).appendingPathComponent("cloudflared-\(configuration.profile).yml")
        // Hostname, port and profile are validated before this point, so plain interpolation is safe.
        let config = """
        ingress:
          - hostname: \(configuration.cloudflareHostname)
            service: http://127.0.0.1:\(configuration.port)
          - service: http_status:404

        """
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(config.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not write the cloudflared config file."]
            )
        }
        return path
    }

    private func writeCloudflaredTokenFile(_ configuration: LocalMCPConfiguration) throws -> String {
        removeCloudflaredTokenFile()
        let directory = try tunnelProfileDirectory()
        let path = (directory as NSString).appendingPathComponent("cloudflared-\(configuration.profile).token")
        try? FileManager.default.removeItem(atPath: path)
        guard FileManager.default.createFile(
            atPath: path,
            contents: Data(configuration.cloudflareToken.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Could not write the cloudflared token file."]
            )
        }
        cloudflaredTokenFile = path
        return path
    }

    /// Runs on `queue`.
    private func removeCloudflaredTokenFile() {
        guard let path = cloudflaredTokenFile else { return }
        try? FileManager.default.removeItem(atPath: path)
        cloudflaredTokenFile = nil
    }

    private func recordOutput(_ text: String) {
        let lines = text.split(whereSeparator: { $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return }
        recentOutputLock.lock()
        recentOutputLines = Array((recentOutputLines + lines).suffix(5))
        recentOutputLock.unlock()
    }

    private func lastOutputLine() -> String? {
        recentOutputLock.lock()
        defer { recentOutputLock.unlock() }
        guard let line = recentOutputLines.last else { return nil }
        return String(line.prefix(300))
    }

    private func tunnelDidExit(exitCode: Int32) {
        tunnelProcess = nil
        removeCloudflaredTokenFile()
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
            var message = "Tunnel stopped unexpectedly (exit status \(exitCode))."
            if let detail = lastOutputLine() {
                message += " Last output: \(detail)"
            }
            setState(.failed(message))
            emitLog(message + "\n")
        }
    }

    private func finishStop() {
        removeCloudflaredTokenFile()
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
        let requiredValues: [(String, String)]
        switch configuration.provider {
        case .openAI:
            requiredValues = [
                ("Tunnel ID", configuration.tunnelID),
                ("Runtime API key", configuration.apiKey),
                ("Profile", configuration.profile),
                ("Shared directory", configuration.allowedDirectory),
            ]
        case .cloudflare:
            requiredValues = [
                ("Cloudflare tunnel token or name", configuration.cloudflareToken),
                ("Public hostname", configuration.cloudflareHostname),
                ("Profile", configuration.profile),
                ("Shared directory", configuration.allowedDirectory),
            ]
        }
        for (label, value) in requiredValues where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw NSError(
                domain: "FileMCP",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "\(label) cannot be empty."]
            )
        }
        if configuration.provider == .cloudflare {
            guard Self.isValidPublicHostname(configuration.cloudflareHostname) else {
                throw NSError(
                    domain: "FileMCP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Public hostname must be a bare hostname such as mcp.example.com (no scheme, port or path)."]
                )
            }
            guard configuration.cloudflarePathSecret.utf8.count >= 32,
                  configuration.cloudflarePathSecret.utf8.allSatisfy(LocalMCPServer.isURLSafeSecretByte) else {
                throw NSError(
                    domain: "FileMCP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The MCP connection credential is missing or too short. Reset it in the Connection tab."]
                )
            }
        } else if !Self.isValidTunnelID(configuration.tunnelID) {
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

    static func canonicalWorkspacePath(_ value: String) -> String {
        let expanded = (value as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func isValidTunnelID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        let prefix = Array("tunnel_".utf8)
        guard bytes.count == prefix.count + 32, bytes.starts(with: prefix) else { return false }
        return bytes.dropFirst(prefix.count).allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 122)
        }
    }

    static func isValidPublicHostname(_ value: String) -> Bool {
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard value.utf8.count <= 253, labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            let bytes = Array(label.utf8)
            guard (1...63).contains(bytes.count), bytes.first != 45, bytes.last != 45 else { return false }
            return bytes.allSatisfy { byte in
                (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) || byte == 45
            }
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
        var environment = Self.baseTunnelEnvironment()
        environment["CONTROL_PLANE_API_KEY"] = apiKey
        environment["FILEMCP_LOCAL_AUTH_TOKEN"] = localAuthToken
        return environment
    }

    static func baseTunnelEnvironment() -> [String: String] {
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
        return environment
    }

    static func defaultTunnelProfilesDirectory() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FileMCP", isDirectory: true)
            .appendingPathComponent("tunnel-profiles", isDirectory: true)
    }

    private func tunnelProfileDirectory() throws -> String {
        let directory: URL
        if let profileDirectoryOverride {
            directory = profileDirectoryOverride.standardizedFileURL
        } else {
            guard let defaultDirectory = Self.defaultTunnelProfilesDirectory() else {
                throw NSError(
                    domain: "FileMCP",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Could not locate the user Application Support directory."]
                )
            }
            directory = defaultDirectory
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
        updateSleepActivity(for: state)
        stateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.onStateChange?(state)
        }
    }

    // The tunnel polls the control plane, so idle system sleep (e.g. a locked screen)
    // takes it offline. Keep the system awake while connected; the display may still sleep.
    // Caller must hold stateLock.
    private func updateSleepActivity(for state: LocalMCPRuntimeState) {
        if state == .running {
            guard sleepActivity == nil else { return }
            sleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .userInitiated],
                reason: "FileMCP tunnel is connected"
            )
        } else if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
    }

    private func isFailedState(_ state: LocalMCPRuntimeState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

struct CloudflareTunnelInfo: Equatable {
    let id: String
    let name: String
}

/// Thin wrapper over the `cloudflared tunnel …` management commands used by the Connection tab.
enum CloudflareCLI {
    static func locate() throws -> String {
        let fileManager = FileManager.default
        let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        var candidates = [executableURL.deletingLastPathComponent().appendingPathComponent("cloudflared").path]
        if let override = ProcessInfo.processInfo.environment["MCP_CLOUDFLARED"] {
            candidates.append(override)
        }
        // GUI apps get a minimal PATH, so also look in the usual install locations.
        candidates += ["/opt/homebrew/bin/cloudflared", "/usr/local/bin/cloudflared"]
        if let path = ProcessInfo.processInfo.environment["PATH"] {
            // Relative entries (".", "bin") would resolve against the current directory.
            candidates += path.split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/cloudflared" }
        }
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return found
        }
        throw error("cloudflared was not found. Install it (brew install cloudflared) or set MCP_CLOUDFLARED to its path.")
    }

    /// `--token-file` arrived in newer cloudflared releases; older ones reject unknown flags.
    static func supportsTokenFile(_ executable: String, shouldCancel: (() -> Bool)? = nil) -> Bool {
        guard let result = try? ProcessRunner.run(
            executable: executable,
            arguments: ["tunnel", "run", "--help"],
            environment: LocalMCPRuntime.baseTunnelEnvironment(),
            timeoutSeconds: 10,
            outputLimitBytes: 250_000,
            shouldCancel: shouldCancel
        ) else { return false }
        return (result.stdout + result.stderr).contains("--token-file")
    }

    /// `cloudflared tunnel login` stores an origin certificate here; management commands need it.
    static func originCertPath() -> String? {
        if let custom = ProcessInfo.processInfo.environment["TUNNEL_ORIGIN_CERT"], !custom.isEmpty {
            return FileManager.default.fileExists(atPath: custom) ? custom : nil
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [".cloudflared", ".cloudflare-warp", "cloudflare-warp"]
            .map { home.appendingPathComponent($0).appendingPathComponent("cert.pem").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    static func isLoggedIn() -> Bool {
        originCertPath() != nil
    }

    /// Opens the browser authorization flow and blocks until it completes, is cancelled or times out.
    /// cloudflared refuses to overwrite an existing certificate, so switching accounts first moves the
    /// current one aside; it is restored if no new certificate is written. Returns the backup path, if any.
    @discardableResult
    static func login(replacingExisting: Bool = false, shouldCancel: (() -> Bool)? = nil) throws -> String? {
        guard let existing = originCertPath() else {
            try runLogin(shouldCancel: shouldCancel)
            return nil
        }
        guard replacingExisting else { return nil }

        let fileManager = FileManager.default
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(existing).bak-\(formatter.string(from: Date()))"
        var backup = stem
        var suffix = 2
        while fileManager.fileExists(atPath: backup) {
            backup = "\(stem)-\(suffix)"
            suffix += 1
        }
        try fileManager.moveItem(atPath: existing, toPath: backup)
        do {
            try runLogin(shouldCancel: shouldCancel)
        } catch {
            // Restore the previous login unless a new certificate took its place.
            if !fileManager.fileExists(atPath: existing) {
                try? fileManager.moveItem(atPath: backup, toPath: existing)
            }
            throw error
        }
        return backup
    }

    private static func runLogin(shouldCancel: (() -> Bool)?) throws {
        let output = try run(["tunnel", "login"], timeoutSeconds: 600, shouldCancel: shouldCancel)
        // cloudflared exits 0 without logging in when another certificate already exists.
        guard isLoggedIn(), !output.contains("existing certificate") else {
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw error("cloudflared did not save a login certificate." + (detail.isEmpty ? "" : " \(detail.suffix(400))"))
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        (error as? CocoaError)?.code == .userCancelled
    }

    static func listTunnels(shouldCancel: (() -> Bool)? = nil) throws -> [CloudflareTunnelInfo] {
        let output = try run(["tunnel", "list", "--output", "json"], timeoutSeconds: 30, shouldCancel: shouldCancel)
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "null" else { return [] }
        guard let data = trimmed.data(using: .utf8),
              let items = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw error("Could not parse the cloudflared tunnel list.")
        }
        return items.compactMap { item in
            guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
            return CloudflareTunnelInfo(id: id, name: name)
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    static func createTunnel(name: String) throws -> CloudflareTunnelInfo {
        guard LocalMCPRuntime.isCloudflareTunnelName(name) else {
            throw error("Tunnel name must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 100 characters).")
        }
        if try listTunnels().contains(where: { $0.name == name }) {
            throw error("A tunnel named \(name) already exists. Select it from the list instead.")
        }
        _ = try run(["tunnel", "create", name], timeoutSeconds: 60)
        guard let created = try listTunnels().first(where: { $0.name == name }) else {
            throw error("cloudflared reported success but the tunnel \(name) is not in the tunnel list.")
        }
        return created
    }

    /// Deletes the tunnel and its local credentials file. Does not touch DNS records.
    static func deleteTunnel(name: String) throws {
        guard LocalMCPRuntime.isCloudflareTunnelName(name) else {
            throw error("Invalid tunnel name.")
        }
        guard try listTunnels().contains(where: { $0.name == name }) else {
            throw error("No tunnel named \(name) exists in this Cloudflare account.")
        }
        // -f also clears stale connections that would otherwise block deletion.
        _ = try run(["tunnel", "delete", "-f", name], timeoutSeconds: 60)
    }

    static func routeDNS(tunnel: String, hostname: String) throws {
        guard LocalMCPRuntime.isValidPublicHostname(hostname) else {
            throw error("Public hostname must be a bare hostname such as mcp.example.com.")
        }
        _ = try run(["tunnel", "route", "dns", tunnel, hostname], timeoutSeconds: 60)
    }

    static func environment() -> [String: String] {
        var environment = LocalMCPRuntime.baseTunnelEnvironment()
        if let certificate = originCertPath() {
            environment["TUNNEL_ORIGIN_CERT"] = certificate
        } else if let custom = ProcessInfo.processInfo.environment["TUNNEL_ORIGIN_CERT"], !custom.isEmpty {
            // Login needs the destination even before the certificate exists.
            environment["TUNNEL_ORIGIN_CERT"] = custom
        }
        return environment
    }

    static func localCredentialsPath(for tunnel: CloudflareTunnelInfo) -> String? {
        guard let id = UUID(uuidString: tunnel.id)?.uuidString.lowercased() else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser
        var directories = [".cloudflared", ".cloudflare-warp", "cloudflare-warp"]
            .map { home.appendingPathComponent($0).path }
        if let certificate = originCertPath() {
            directories.insert((certificate as NSString).deletingLastPathComponent, at: 0)
        }
        return directories.map { ($0 as NSString).appendingPathComponent("\(id).json") }
            .first { FileManager.default.isReadableFile(atPath: $0) }
    }

    static func credentialsPath(tunnel reference: String, shouldCancel: (() -> Bool)? = nil) throws -> String {
        let tunnel: CloudflareTunnelInfo
        if UUID(uuidString: reference) != nil {
            // UUIDs can run with local credentials even without an account certificate.
            tunnel = CloudflareTunnelInfo(id: reference, name: reference)
        } else if let found = try listTunnels(shouldCancel: shouldCancel).first(where: { $0.name == reference }) {
            tunnel = found
        } else {
            throw error("No tunnel named \(reference) exists in this Cloudflare account.")
        }
        guard let path = localCredentialsPath(for: tunnel) else {
            throw error("Tunnel \(tunnel.name) has no local credentials on this Mac. Use the dashboard token provider, or select a tunnel created on this Mac.")
        }
        return path
    }

    private static func run(_ arguments: [String], timeoutSeconds: Int, shouldCancel: (() -> Bool)? = nil) throws -> String {
        let environment = environment()
        let result = try ProcessRunner.run(
            executable: try locate(),
            arguments: arguments,
            environment: environment,
            timeoutSeconds: timeoutSeconds,
            outputLimitBytes: 250_000,
            maxTimeoutSeconds: timeoutSeconds,
            shouldCancel: shouldCancel
        )
        let operation = "cloudflared " + arguments.prefix(arguments.first == "tunnel" ? 2 : 1).joined(separator: " ")
        if shouldCancel?() == true { throw CocoaError(.userCancelled) }
        if result.timedOut { throw error("\(operation) timed out.") }
        guard result.exitCode == 0 else {
            let detail = [result.stderr, result.stdout]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? "exit status \(result.exitCode)"
            throw error("\(operation) failed: \(String(detail.suffix(600)))")
        }
        return result.stdout
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "FileMCP", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// cloudflared output may split a registration message across pipe reads.
final class CloudflareConnectionMonitor {
    private let lock = NSLock()
    private var tail = ""
    private var connected = false

    func consume(_ text: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !connected else { return false }
        let combined = tail + text
        connected = combined.contains("Registered tunnel connection")
        tail = String(combined.suffix(64))
        return connected
    }
}
