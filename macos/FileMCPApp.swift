import AppKit
import Security

private let appName = "FileMCP"

private enum Layout {
    static let windowWidth: CGFloat = 560
    static let collapsedWindowHeight: CGFloat = 570
    static let expandedWindowHeight: CGFloat = 750
    static let openAIConnectionWindowHeight: CGFloat = 530
    static let cloudflareConnectionWindowHeight: CGFloat = 750
    static let cloudflareTokenConnectionWindowHeight: CGFloat = 675
    static let footerHeight: CGFloat = 84
    static let contentWidth: CGFloat = 512
    static let labelWidth: CGFloat = 120
    static let fieldWidth: CGFloat = 384
    static let directoryFieldWidth: CGFloat = 332
    static let directoryButtonWidth: CGFloat = 44
    static let actionButtonHeight: CGFloat = 34
}

private final class TopAlignedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private enum ConfigKey {
    static let tunnelID = "tunnelID"
    static let profile = "profile"
    static let port = "port"
    static let allowedDirectory = "allowedDirectory"
    static let healthAddress = "healthAddress"
    static let gitUserName = "gitUserName"
    static let gitUserEmail = "gitUserEmail"
    static let apiKey = "apiKey"
    static let provider = "tunnelProvider"
    static let cloudflareHostname = "cloudflareHostname"
    static let cloudflareTunnelSource = "cloudflareTunnelSource"
    static let enableCommands = "enableCommands"
    static let allowCloudflareURLSecret = "allowCloudflareURLSecret"
    static let enableGitPush = "enableGitPush"
    static let enableCodexHistory = "enableCodexHistory"
    static let publicShellCommandsAcknowledged = "publicShellCommandsAcknowledged"

    static let all = [
        tunnelID, profile, port, allowedDirectory, healthAddress, gitUserName, gitUserEmail,
        apiKey, provider, cloudflareHostname, cloudflareTunnelSource, enableCommands, enableGitPush, enableCodexHistory, allowCloudflareURLSecret, publicShellCommandsAcknowledged,
    ]
}

/// Set on the main thread, read from the background thread running a cancellable command.
private final class CancellationFlag {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

private final class LoadingButton: NSButton {
    private let loadingGradientLayer = CAGradientLayer()
    private let loadingBorderMaskLayer = CAShapeLayer()
    private var borderPerimeter: CGFloat = 1

    convenience init(title: String, target: Any?, action: Selector?) {
        self.init(frame: .zero)
        self.title = title
        self.target = target as AnyObject?
        self.action = action
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLoadingBorder()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureLoadingBorder()
    }

    override func layout() {
        super.layout()
        let borderRect = bounds.insetBy(dx: 1, dy: 1)
        let cornerRadius: CGFloat = 8
        let perimeter = 2 * (borderRect.width + borderRect.height - 4 * cornerRadius)
            + 2 * .pi * cornerRadius
        borderPerimeter = max(perimeter, 1)

        loadingGradientLayer.frame = bounds
        loadingBorderMaskLayer.frame = bounds
        loadingBorderMaskLayer.path = CGPath(
            roundedRect: borderRect,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )
        loadingBorderMaskLayer.lineDashPattern = [
            NSNumber(value: Double(borderPerimeter * 0.2)),
            NSNumber(value: Double(borderPerimeter * 0.3)),
        ]
    }

    func setLoading(_ loading: Bool) {
        isEnabled = !loading
        loadingGradientLayer.isHidden = !loading

        if loading {
            loadingBorderMaskLayer.lineDashPhase = 0
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = 0
            animation.toValue = -borderPerimeter
            animation.duration = 1.5
            animation.repeatCount = .infinity
            loadingBorderMaskLayer.add(animation, forKey: "loading-border")
        } else {
            loadingBorderMaskLayer.removeAnimation(forKey: "loading-border")
            loadingBorderMaskLayer.lineDashPhase = 0
        }
    }

    private func configureLoadingBorder() {
        wantsLayer = true
        loadingGradientLayer.colors = [
            NSColor.controlAccentColor.cgColor,
            NSColor.controlAccentColor.withAlphaComponent(0.35).cgColor,
        ]
        loadingGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        loadingGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        loadingGradientLayer.isHidden = true

        loadingBorderMaskLayer.fillColor = NSColor.clear.cgColor
        loadingBorderMaskLayer.strokeColor = NSColor.white.cgColor
        loadingBorderMaskLayer.lineWidth = 1
        loadingBorderMaskLayer.lineCap = .round
        loadingGradientLayer.mask = loadingBorderMaskLayer
        layer?.addSublayer(loadingGradientLayer)
    }
}

private final class RuntimeStorage {
    private let keychainService = Bundle.main.bundleIdentifier ?? "com.localfilesmcp.app"
    private let apiKeyAccount = "runtime-api-key"
    private let cloudflareTokenAccount = "cloudflare-tunnel-token"
    private let cloudflareSecretAccount = "cloudflare-path-secret"
    private let cloudflarePairingAccount = "cloudflare-pairing-secret"

    var hasSavedAPIKey: Bool {
        if let value = try? readSecret(apiKeyAccount), !value.isEmpty {
            return true
        }
        return legacyAPIKey != nil
    }

    func readAPIKey() throws -> String {
        if let value = try readSecret(apiKeyAccount), !value.isEmpty {
            return value
        }
        if let legacy = legacyAPIKey {
            try saveAPIKey(legacy)
            return legacy
        }
        throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "No API key is saved."])
    }

    func saveAPIKey(_ value: String) throws {
        try saveSecret(value, account: apiKeyAccount, label: "the API key")
        UserDefaults.standard.removeObject(forKey: ConfigKey.apiKey)
    }

    func deleteAPIKey() throws {
        try deleteSecret(apiKeyAccount, label: "the API key")
        UserDefaults.standard.removeObject(forKey: ConfigKey.apiKey)
    }

    func readCloudflareToken() throws -> String {
        guard let value = try readSecret(cloudflareTokenAccount), !value.isEmpty else {
            throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "No Cloudflare tunnel token is saved."])
        }
        return value
    }

    func saveCloudflareToken(_ value: String) throws {
        try saveSecret(value, account: cloudflareTokenAccount, label: "the Cloudflare tunnel token")
    }

    func deleteCloudflareToken() throws {
        try deleteSecret(cloudflareTokenAccount, label: "the Cloudflare tunnel token")
    }

    /// The secret embedded in the public MCP URL. Generated once and kept until the user regenerates it.
    func cloudflarePathSecret() throws -> String {
        if let value = try readSecret(cloudflareSecretAccount), value.utf8.count >= 32 {
            return value
        }
        return try regenerateCloudflarePathSecret()
    }

    @discardableResult
    func regenerateCloudflarePathSecret() throws -> String {
        try generateSecret(account: cloudflareSecretAccount, label: "the MCP URL secret")
    }

    func cloudflarePairingSecret() throws -> String {
        if let value = try readSecret(cloudflarePairingAccount), value.utf8.count >= 32 { return value }
        return try regenerateCloudflarePairingSecret()
    }

    func regenerateCloudflarePairingSecret() throws -> String {
        try generateSecret(account: cloudflarePairingAccount, label: "the OAuth login code")
    }

    func readCloudflareOAuthState(hostname: String) throws -> Data? {
        guard let value = try readSecret("cloudflare-oauth-state-" + hostname) else { return nil }
        guard let data = Data(base64Encoded: value) else {
            throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "Stored OAuth state is invalid. Reset the login code to revoke and clear it."])
        }
        return data
    }

    func saveCloudflareOAuthState(_ data: Data, hostname: String) throws {
        try saveSecret(data.base64EncodedString(), account: "cloudflare-oauth-state-" + hostname, label: "OAuth sessions")
    }

    private func generateSecret(account: String, label: String) throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let byteCount = bytes.count
        let status = bytes.withUnsafeMutableBytes { buffer -> Int32 in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, byteCount, baseAddress)
        }
        guard status == errSecSuccess else {
            throw keychainError(operation: "generate the MCP URL secret", status: status)
        }
        // Lowercase hex is URL-safe and passes the server's secret validation.
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        try saveSecret(secret, account: account, label: label)
        return secret
    }

    private var legacyAPIKey: String? {
        guard let value = UserDefaults.standard.string(forKey: ConfigKey.apiKey), !value.isEmpty else {
            return nil
        }
        return value
    }

    private func saveSecret(_ value: String, account: String, label: String) throws {
        guard !value.isEmpty else { return }
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: "\(label.prefix(1).uppercased() + label.dropFirst()) is not valid UTF-8."])
        }

        let query = keychainQuery(account)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw keychainError(operation: "save \(label)", status: addStatus)
            }
        } else if updateStatus != errSecSuccess {
            throw keychainError(operation: "update \(label)", status: updateStatus)
        }
    }

    private func deleteSecret(_ account: String, label: String) throws {
        let status = SecItemDelete(keychainQuery(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(operation: "delete \(label)", status: status)
        }
    }

    /// Removes every credential FileMCP has stored, including the legacy UserDefaults API key.
    func deleteAllSecrets() throws {
        let query: [CFString: Any] = [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(operation: "delete FileMCP credentials and OAuth sessions", status: status)
        }
    }

    private func readSecret(_ account: String) throws -> String? {
        var query = keychainQuery(account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw keychainError(operation: "read the stored secret", status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: "The secret stored in Keychain is not valid UTF-8."])
        }
        return value
    }

    private func keychainQuery(_ account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: keychainService,
            kSecAttrAccount: account,
        ]
    }

    private func keychainError(operation: String, status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: appName,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) in macOS Keychain: \(detail)"]
        )
    }
}

private final class MainViewController: NSViewController, NSTabViewDelegate, NSTextFieldDelegate, NSComboBoxDelegate {
    private let storage = RuntimeStorage()
    private let runtime = LocalMCPRuntime()
    private let logBuffer = NSMutableString()
    private var logFlushScheduled = false
    private let maxLogCharacters = 500_000
    private var loadsSavedConfiguration = true
    private var configurationIsEditable = true
    private var hasStoredAPIKey = false
    private var hasStoredCloudflareCredential = false
    private let connectionDetailLabel = NSTextField(labelWithString: "Choose a workspace, then connect.")
    private let connectionHelpLabel = NSTextField(wrappingLabelWithString: "")
    private let workspaceSummaryLabel = NSTextField(labelWithString: "Choose a workspace")
    private let workspaceAccessLabel = NSTextField(labelWithString: "File access")
    private let activityIndicator = NSProgressIndicator()
    private let chooseDirectoryButton = NSButton()
    private let feedbackLabel = NSTextField(wrappingLabelWithString: "")
    private let viewLogsButton = NSButton(title: "View activity", target: nil, action: nil)
    private var feedbackRevision = 0

    private let providerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tunnelIDField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let cloudflareTunnelNameField = NSComboBox()
    // Separate secure field so a pasted token is never shown in clear text.
    private let cloudflareTokenField = NSSecureTextField()
    private let cloudflareNameSection = NSStackView()
    private let cloudflareTokenSection = NSStackView()
    private let cloudflareRefreshButton = NSButton()
    private let cloudflareLoginButton = NSButton(title: "Log in to Cloudflare…", target: nil, action: nil)
    private let cloudflareCreateButton = NSButton(title: "Create tunnel + DNS", target: nil, action: nil)
    private let cloudflareDeleteButton = NSButton(title: "Delete tunnel…", target: nil, action: nil)
    private let cloudflareCLIStatusLabel = NSTextField(labelWithString: "")
    private var cloudflareLoggedIn = false
    private var cloudflareBusy = false
    private var cloudflareLoginCancellation: CancellationFlag?
    private var cachedPathSecret: String?
    private var cachedPairingSecret: String?
    private let allowCloudflareURLSecretCheckbox = NSButton(checkboxWithTitle: "Compatibility: use a secret in the MCP URL", target: nil, action: nil)
    private let copyTokenButton = NSButton(title: "Copy login code", target: nil, action: nil)
    private var mcpURLWidthConstraint: NSLayoutConstraint?
    private var knownCloudflareTunnelNames: [String] = []
    private let cloudflareHostnameField = NSTextField()
    private let mcpURLField = NSTextField()
    private let copyURLButton = NSButton()
    private let regenerateURLButton = NSButton()
    private let openAIGroup = NSStackView()
    private let cloudflareGroup = NSStackView()
    private let openAIKeyRow = NSStackView()
    private let cloudflareKeyRow = NSStackView()
    private let cloudflareTokenStatusLabel = NSTextField(labelWithString: "")
    private let deleteCloudflareTokenButton = NSButton(title: "Delete token", target: nil, action: nil)
    private let profileField = NSTextField()
    private let portField = NSTextField()
    private let directoryField = NSTextField()
    private let healthAddressField = NSTextField()
    private let gitUserNameField = NSTextField()
    private let gitUserEmailField = NSTextField()
    private let enableGitPushCheckbox = NSButton(checkboxWithTitle: "Allow Git push to remote servers", target: nil, action: nil)
    private let enableCodexHistoryCheckbox = NSButton(checkboxWithTitle: "Allow writing to Codex history", target: nil, action: nil)
    private let enableCommandsCheckbox = NSButton(checkboxWithTitle: "Allow shell commands", target: nil, action: nil)
    private let logView = NSTextView()
    private let activityEmptyLabel = NSTextField(wrappingLabelWithString: "No activity yet\nConnect to see tunnel status and MCP requests.")
    private let copyLogsButton = NSButton(title: "Copy logs", target: nil, action: nil)
    private let connectionStatusLabel = NSTextField(labelWithString: "Disconnected")
    private let followLogsCheckbox = NSButton(checkboxWithTitle: "Follow new logs", target: nil, action: nil)
    private let saveConnectionButton = LoadingButton(title: "Save connection", target: nil, action: nil)
    private let saveSettingsButton = LoadingButton(title: "Save workspace", target: nil, action: nil)
    private let startButton = NSButton(title: "Connect", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "Delete API key", target: nil, action: nil)
    private let resetButton = NSButton(title: "Reset all settings…", target: nil, action: nil)
    private let advancedToggleButton = NSButton(title: "Advanced options", target: nil, action: nil)
    private let advancedSettingsGroup = NSStackView()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private let tabs = NSTabView()
    private var connectionFormView: NSStackView?
    private var connectionSaveView: NSStackView?
    private var connectionKeyView: NSStackView?
    private var connectionDivider: NSBox?
    private let activeConnectionSummary = NSTextField(wrappingLabelWithString: "")
    private let shareConnectionSection = NSStackView()
    private let shareConnectionHelpLabel = NSTextField(wrappingLabelWithString: "")
    private var cloudflareAccountActions: NSStackView?
    private let cloudflareManagementGroup = NSStackView()
    private let cloudflareManagementToggle = NSButton(title: "Manage Cloudflare & compatibility", target: nil, action: nil)
    private var connectionContent: NSStackView?
    private var connectionScrollView: NSScrollView?

    override func loadView() {
        view = NSView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        if loadsSavedConfiguration {
            loadConfiguration()
            configureRuntime()
        }
    }

    deinit {
        shutdownForTermination()
    }

    private func buildUI() {
        configure(tunnelIDField, placeholder: "tunnel_...")
        configure(apiKeyField, placeholder: "sk-...")
        configure(cloudflareTunnelNameField, placeholder: "Pick a tunnel or type a new name")
        cloudflareTunnelNameField.completes = true
        cloudflareTunnelNameField.numberOfVisibleItems = 8
        cloudflareTunnelNameField.delegate = self
        cloudflareTunnelNameField.toolTip = "Tunnel in the Cloudflare account cloudflared is logged in to. Pick one, or type a new name and click Create."
        configure(cloudflareTokenField, placeholder: "eyJ…")
        cloudflareTokenField.toolTip = "Token of a remotely-managed tunnel (Cloudflare Zero Trust → Networks → Tunnels). Stored in Keychain."

        cloudflareRefreshButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh tunnel list")
        cloudflareRefreshButton.bezelStyle = .rounded
        cloudflareRefreshButton.imagePosition = .imageOnly
        cloudflareRefreshButton.toolTip = "Refresh the tunnel list from Cloudflare"
        cloudflareRefreshButton.target = self
        cloudflareRefreshButton.action = #selector(refreshCloudflareTunnelsAction)
        cloudflareRefreshButton.translatesAutoresizingMaskIntoConstraints = false
        for button in [cloudflareLoginButton, cloudflareCreateButton, cloudflareDeleteButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.target = self
        }
        cloudflareLoginButton.action = #selector(cloudflareLogin)
        cloudflareLoginButton.toolTip = "Opens your browser to authorize cloudflared for your Cloudflare account"
        cloudflareDeleteButton.action = #selector(deleteCloudflareTunnel)
        cloudflareDeleteButton.contentTintColor = .systemRed
        cloudflareDeleteButton.toolTip = "Delete the selected tunnel from your Cloudflare account"
        cloudflareCreateButton.action = #selector(createCloudflareTunnel)
        cloudflareCreateButton.toolTip = "Create a tunnel with the name above and add a DNS record for the public hostname"
        cloudflareCLIStatusLabel.font = .systemFont(ofSize: 10.5)
        cloudflareCLIStatusLabel.textColor = .secondaryLabelColor
        cloudflareCLIStatusLabel.lineBreakMode = .byTruncatingTail
        cloudflareCLIStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cloudflareCLIStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configure(cloudflareHostnameField, placeholder: "mcp.example.com")
        cloudflareHostnameField.toolTip = "Public hostname routed to this tunnel in the Cloudflare dashboard, pointing at http://127.0.0.1:<MCP port>."
        cloudflareHostnameField.delegate = self
        configure(mcpURLField, placeholder: "Enter a hostname to see the MCP URL")
        mcpURLField.isEditable = false
        mcpURLField.isSelectable = false
        mcpURLField.lineBreakMode = .byTruncatingMiddle
        mcpURLField.toolTip = "Add this endpoint to your MCP client. Use OAuth by default; compatibility URLs contain a secret."

        providerPopup.addItems(withTitles: [
            "OpenAI Secure MCP Tunnel",
            "Cloudflare Tunnel (log in with cloudflared)",
            "Cloudflare Tunnel (dashboard token)",
        ])
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.translatesAutoresizingMaskIntoConstraints = false

        copyURLButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy MCP URL")
        copyURLButton.bezelStyle = .rounded
        copyURLButton.title = "Copy URL"
        copyURLButton.imagePosition = .imageLeading
        copyURLButton.toolTip = "Copy the MCP endpoint URL. Compatibility mode includes a secret."
        copyURLButton.target = self
        copyURLButton.action = #selector(copyMCPURL)
        copyURLButton.translatesAutoresizingMaskIntoConstraints = false
        regenerateURLButton.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "Regenerate MCP URL secret")
        regenerateURLButton.bezelStyle = .rounded
        regenerateURLButton.imagePosition = .imageOnly
        regenerateURLButton.toolTip = "Generate a new URL secret. The previous URL stops working."
        regenerateURLButton.target = self
        regenerateURLButton.action = #selector(regenerateMCPURL)
        regenerateURLButton.translatesAutoresizingMaskIntoConstraints = false
        copyTokenButton.bezelStyle = .rounded
        copyTokenButton.target = self
        copyTokenButton.action = #selector(copyMCPToken)
        copyTokenButton.toolTip = "Copy the private login code from this Mac. Paste it only into your FileMCP OAuth authorization page."
        copyTokenButton.translatesAutoresizingMaskIntoConstraints = false
        allowCloudflareURLSecretCheckbox.target = self
        allowCloudflareURLSecretCheckbox.action = #selector(cloudflareURLSecretChanged)
        allowCloudflareURLSecretCheckbox.toolTip = "Off by default. URL secrets can be exposed in external proxy/client logs. Use only for clients requiring the old no-auth URL flow."
        configure(profileField, placeholder: "filemcp")
        profileField.toolTip = "Starts with a letter or number; use only letters, numbers, '.', '_' or '-' (maximum 128 characters)."
        configure(portField, placeholder: "8008")
        configure(directoryField, placeholder: "Choose a shared directory")
        configure(healthAddressField, placeholder: "127.0.0.1:0")
        healthAddressField.toolTip = "Loopback-only tunnel-client health/admin listener. Use port 0 for an ephemeral port."
        configure(gitUserNameField, placeholder: "Git name for commits (optional)")
        configure(gitUserEmailField, placeholder: "Git email for commits (optional)")

        let chooseImage = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")!
        let chooseButton = chooseDirectoryButton
        chooseButton.image = chooseImage
        chooseButton.target = self
        chooseButton.action = #selector(chooseDirectory)
        chooseButton.bezelStyle = .rounded
        chooseButton.imagePosition = .imageOnly
        chooseButton.toolTip = "Choose directory"

        logView.isEditable = false
        logView.isSelectable = true
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .textBackgroundColor
        logView.textColor = .textColor
        logView.insertionPointColor = .textColor
        logView.string = ""
        logView.textContainerInset = NSSize(width: 8, height: 8)
        logView.isAutomaticQuoteSubstitutionEnabled = false
        logView.isAutomaticSpellingCorrectionEnabled = false
        logView.setAccessibilityLabel("Runtime logs")
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.borderType = .bezelBorder
        logScroll.documentView = logView

        startButton.target = self
        startButton.action = #selector(startTunnel)
        startButton.keyEquivalent = "\r"
        startButton.toolTip = "Save your settings and connect to the selected workspace"
        startButton.bezelStyle = .rounded
        startButton.controlSize = .large
        updateRunButton(state: .stopped)

        saveConnectionButton.target = self
        saveConnectionButton.action = #selector(saveConnectionOnly)
        saveConnectionButton.bezelStyle = .rounded
        saveConnectionButton.controlSize = .large

        saveSettingsButton.target = self
        saveSettingsButton.action = #selector(saveSettingsOnly)
        saveSettingsButton.bezelStyle = .rounded

        deleteKeyButton.target = self
        deleteKeyButton.action = #selector(deleteSavedKey)
        deleteKeyButton.bezelStyle = .rounded
        deleteKeyButton.controlSize = .small
        deleteKeyButton.contentTintColor = .systemRed

        deleteCloudflareTokenButton.target = self
        deleteCloudflareTokenButton.action = #selector(deleteSavedKey)
        deleteCloudflareTokenButton.bezelStyle = .rounded
        deleteCloudflareTokenButton.controlSize = .small
        deleteCloudflareTokenButton.contentTintColor = .systemRed

        cloudflareTokenStatusLabel.font = .systemFont(ofSize: 10.5)
        cloudflareTokenStatusLabel.textColor = .secondaryLabelColor
        cloudflareTokenStatusLabel.lineBreakMode = .byTruncatingTail
        cloudflareTokenStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        cloudflareTokenStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        resetButton.target = self
        resetButton.action = #selector(resetAllSettings)
        resetButton.bezelStyle = .rounded
        resetButton.controlSize = .small
        resetButton.contentTintColor = .systemRed
        resetButton.toolTip = "Delete saved settings, API key, Cloudflare token and URL secret, and generated tunnel profiles"

        advancedToggleButton.target = self
        advancedToggleButton.action = #selector(toggleAdvancedSettings)
        advancedToggleButton.bezelStyle = .inline
        advancedToggleButton.isBordered = false
        advancedToggleButton.image = advancedChevron(expanded: false)
        advancedToggleButton.imagePosition = .imageLeading
        advancedToggleButton.contentTintColor = .secondaryLabelColor

        apiKeyStatusLabel.font = .systemFont(ofSize: 10.5)
        apiKeyStatusLabel.textColor = .secondaryLabelColor
        apiKeyStatusLabel.lineBreakMode = .byTruncatingTail
        apiKeyStatusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        apiKeyStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        func fieldRow(_ label: String, _ field: NSView) -> NSStackView {
            field.setAccessibilityLabel(label)
            let labelView = NSTextField(labelWithString: label)
            labelView.font = .systemFont(ofSize: 12, weight: .medium)
            labelView.alignment = .left
            labelView.cell?.alignment = .left
            labelView.textColor = .secondaryLabelColor
            labelView.setContentHuggingPriority(.required, for: .horizontal)
            labelView.setContentCompressionResistancePriority(.required, for: .horizontal)
            labelView.translatesAutoresizingMaskIntoConstraints = false
            labelView.widthAnchor.constraint(equalToConstant: Layout.labelWidth).isActive = true

            let row = NSStackView(views: [labelView, field])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            return row
        }

        func connectionField(_ label: String, _ field: NSView) -> NSStackView {
            field.setAccessibilityLabel(label)
            let labelView = NSTextField(labelWithString: label)
            labelView.font = .systemFont(ofSize: 12, weight: .medium)
            labelView.alignment = .left
            labelView.cell?.alignment = .left
            labelView.textColor = .secondaryLabelColor
            labelView.setContentHuggingPriority(.required, for: .vertical)
            labelView.setContentCompressionResistancePriority(.required, for: .vertical)

            let row = NSStackView(views: [labelView, field])
            row.orientation = .vertical
            row.alignment = .leading
            row.spacing = 5
            return row
        }

        let copySpacer = NSView()
        copySpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let mcpURLControls = NSStackView(views: [copyURLButton, copyTokenButton, copySpacer, regenerateURLButton])
        mcpURLControls.orientation = .horizontal
        mcpURLControls.alignment = .centerY
        mcpURLControls.spacing = 8
        mcpURLControls.detachesHiddenViews = true
        mcpURLWidthConstraint = mcpURLField.widthAnchor.constraint(equalToConstant: Layout.contentWidth - 28)
        mcpURLField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        mcpURLField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let shareTitle = NSTextField(labelWithString: "Connect an AI client")
        shareTitle.font = .systemFont(ofSize: 13, weight: .semibold)
        let shareHelp = shareConnectionHelpLabel
        shareHelp.font = .systemFont(ofSize: 11)
        shareHelp.textColor = .secondaryLabelColor
        shareHelp.preferredMaxLayoutWidth = Layout.contentWidth - 28
        for item in [shareTitle, mcpURLField, mcpURLControls, shareHelp] { shareConnectionSection.addArrangedSubview(item) }
        shareConnectionSection.orientation = .vertical
        shareConnectionSection.alignment = .leading
        shareConnectionSection.spacing = 10
        shareConnectionSection.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        shareConnectionSection.wantsLayer = true
        shareConnectionSection.layer?.cornerRadius = 10
        shareConnectionSection.isHidden = true
        shareConnectionSection.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true
        mcpURLControls.widthAnchor.constraint(equalToConstant: Layout.contentWidth - 28).isActive = true
        shareHelp.widthAnchor.constraint(equalToConstant: Layout.contentWidth - 28).isActive = true
        cloudflareManagementToggle.bezelStyle = .inline
        cloudflareManagementToggle.isBordered = false
        cloudflareManagementToggle.font = .systemFont(ofSize: 11)
        cloudflareManagementToggle.contentTintColor = .secondaryLabelColor
        cloudflareManagementToggle.image = advancedChevron(expanded: false)
        cloudflareManagementToggle.imagePosition = .imageLeading
        cloudflareManagementToggle.target = self
        cloudflareManagementToggle.action = #selector(toggleCloudflareManagement)

        let tunnelControls = NSStackView(views: [cloudflareTunnelNameField, cloudflareRefreshButton])
        tunnelControls.orientation = .horizontal
        tunnelControls.alignment = .centerY
        tunnelControls.spacing = 8
        let tunnelActions = NSStackView(views: [cloudflareLoginButton, cloudflareCreateButton, cloudflareDeleteButton])
        cloudflareAccountActions = tunnelActions
        tunnelActions.orientation = .horizontal
        tunnelActions.alignment = .centerY
        tunnelActions.spacing = 8
        for view in [connectionField("Tunnel", tunnelControls), cloudflareCLIStatusLabel] {
            cloudflareNameSection.addArrangedSubview(view)
        }
        for item in [tunnelActions, allowCloudflareURLSecretCheckbox] { cloudflareManagementGroup.addArrangedSubview(item) }
        cloudflareManagementGroup.orientation = .vertical
        cloudflareManagementGroup.alignment = .leading
        cloudflareManagementGroup.spacing = 10
        cloudflareManagementGroup.isHidden = true
        cloudflareNameSection.orientation = .vertical
        cloudflareNameSection.alignment = .leading
        cloudflareNameSection.spacing = 6
        cloudflareTokenSection.addArrangedSubview(connectionField("Tunnel token", cloudflareTokenField))
        cloudflareTokenSection.orientation = .vertical
        cloudflareTokenSection.alignment = .leading
        cloudflareTokenSection.isHidden = true

        for (group, views) in [
            (openAIGroup, [
                connectionField("Tunnel ID", tunnelIDField),
                connectionField("Runtime API key", apiKeyField),
            ]),
            (cloudflareGroup, [
                cloudflareNameSection,
                cloudflareTokenSection,
                connectionField("Public hostname", cloudflareHostnameField),
                cloudflareManagementToggle,
                cloudflareManagementGroup,
            ]),
        ] {
            views.forEach { group.addArrangedSubview($0) }
            group.orientation = .vertical
            group.alignment = .leading
            group.spacing = 12
            group.detachesHiddenViews = true
        }
        cloudflareGroup.isHidden = true

        let connectionForm = NSStackView(views: [
            connectionField("Provider", providerPopup),
            openAIGroup,
            cloudflareGroup,
        ])
        connectionFormView = connectionForm
        connectionForm.orientation = .vertical
        connectionForm.alignment = .leading
        connectionForm.spacing = 12
        connectionForm.detachesHiddenViews = true

        connectionHelpLabel.font = .systemFont(ofSize: 12)
        connectionHelpLabel.textColor = .secondaryLabelColor
        connectionHelpLabel.preferredMaxLayoutWidth = Layout.contentWidth
        connectionHelpLabel.stringValue = "Use the tunnel ID and API key supplied by your Secure MCP Tunnel. Connect saves your changes automatically."
        connectionHelpLabel.translatesAutoresizingMaskIntoConstraints = false
        let primaryActions = NSStackView(views: [saveConnectionButton])
        primaryActions.orientation = .horizontal
        primaryActions.alignment = .centerY
        primaryActions.distribution = .fillEqually
        primaryActions.spacing = 8
        primaryActions.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        for (row, views) in [
            (openAIKeyRow, [apiKeyStatusLabel, deleteKeyButton]),
            (cloudflareKeyRow, [cloudflareTokenStatusLabel, deleteCloudflareTokenButton]),
        ] {
            views.forEach { row.addArrangedSubview($0) }
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 10
            row.translatesAutoresizingMaskIntoConstraints = false
        }
        cloudflareKeyRow.isHidden = true
        let keyManagementRow = NSStackView(views: [openAIKeyRow, cloudflareKeyRow])
        keyManagementRow.orientation = .vertical
        keyManagementRow.alignment = .leading
        keyManagementRow.spacing = 0
        keyManagementRow.detachesHiddenViews = true
        keyManagementRow.translatesAutoresizingMaskIntoConstraints = false

        connectionSaveView = primaryActions
        connectionKeyView = keyManagementRow
        connectionDivider = divider
        activeConnectionSummary.font = .systemFont(ofSize: 13, weight: .medium)
        activeConnectionSummary.preferredMaxLayoutWidth = Layout.contentWidth
        activeConnectionSummary.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true
        activeConnectionSummary.isHidden = true
        let connectionRoot = NSStackView(views: [
            connectionHelpLabel,
            activeConnectionSummary,
            connectionForm,
            shareConnectionSection,
            primaryActions,
            divider,
            keyManagementRow,
        ])
        connectionRoot.orientation = .vertical
        connectionRoot.alignment = .leading
        connectionRoot.spacing = 16
        connectionRoot.detachesHiddenViews = true
        connectionRoot.setCustomSpacing(16, after: connectionForm)
        connectionRoot.setCustomSpacing(14, after: primaryActions)
        connectionRoot.setCustomSpacing(10, after: divider)
        connectionRoot.translatesAutoresizingMaskIntoConstraints = false
        connectionContent = connectionRoot

        let connectionPage = NSScrollView()
        connectionPage.hasVerticalScroller = true
        connectionPage.scrollerStyle = .overlay
        connectionPage.drawsBackground = false
        connectionScrollView = connectionPage
        let connectionDocument = TopAlignedDocumentView()
        connectionDocument.translatesAutoresizingMaskIntoConstraints = false
        connectionPage.documentView = connectionDocument
        connectionDocument.addSubview(connectionRoot)
        NSLayoutConstraint.activate([
            connectionDocument.widthAnchor.constraint(equalTo: connectionPage.contentView.widthAnchor),
            connectionRoot.leadingAnchor.constraint(equalTo: connectionDocument.leadingAnchor, constant: 12),
            connectionRoot.trailingAnchor.constraint(equalTo: connectionDocument.trailingAnchor, constant: -12),
            connectionRoot.topAnchor.constraint(equalTo: connectionDocument.topAnchor, constant: 12),
            connectionRoot.bottomAnchor.constraint(equalTo: connectionDocument.bottomAnchor, constant: -12),
            connectionHelpLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            primaryActions.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            divider.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            keyManagementRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            openAIKeyRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cloudflareKeyRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            providerPopup.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            copyURLButton.widthAnchor.constraint(equalToConstant: 100),
            regenerateURLButton.widthAnchor.constraint(equalToConstant: Layout.directoryButtonWidth),
            copyTokenButton.widthAnchor.constraint(equalToConstant: 120),
            mcpURLWidthConstraint!,
            saveConnectionButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),

        ])

        let directoryControls = NSStackView(views: [directoryField, chooseButton])
        directoryControls.orientation = .horizontal
        directoryControls.alignment = .centerY
        directoryControls.spacing = 8
        directoryField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        directoryField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        enableCommandsCheckbox.toolTip = "Allow FileMCP to run shell/CLI commands with the current macOS user's permissions."
        let commandWarning = NSTextField(wrappingLabelWithString: "Allows ChatGPT to run shell/CLI commands with the current macOS user's permissions. Enable only for workspaces you trust.")
        commandWarning.font = .systemFont(ofSize: 10)
        commandWarning.textColor = .secondaryLabelColor
        commandWarning.maximumNumberOfLines = 0
        commandWarning.preferredMaxLayoutWidth = Layout.contentWidth

        enableGitPushCheckbox.toolTip = "Allows sending repository contents to configured remotes. Existing SSH identities may be used. Disabled by default."
        enableCodexHistoryCheckbox.toolTip = "Allows creating conversations in your Codex history outside the shared folder. Disabled by default."
        for checkbox in [enableGitPushCheckbox, enableCodexHistoryCheckbox] {
            checkbox.target = self
            checkbox.action = #selector(workspaceOptionsChanged)
        }
        let extraPermissionsHelp = NSTextField(wrappingLabelWithString: "Git push sends code to remote servers. Codex history writes outside this folder. Both permissions are off by default.")
        extraPermissionsHelp.font = .systemFont(ofSize: 11)
        extraPermissionsHelp.textColor = .secondaryLabelColor
        extraPermissionsHelp.preferredMaxLayoutWidth = Layout.contentWidth
        extraPermissionsHelp.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true
        let profileRow = fieldRow("Profile", profileField)
        let portRow = fieldRow("MCP port", portField)
        let directoryRow = fieldRow("Shared directory", directoryControls)
        let healthRow = fieldRow("Health listener", healthAddressField)
        let gitNameRow = fieldRow("Git name", gitUserNameField)
        let gitEmailRow = fieldRow("Git email", gitUserEmailField)

        advancedSettingsGroup.orientation = .vertical
        advancedSettingsGroup.alignment = .leading
        advancedSettingsGroup.spacing = 8
        advancedSettingsGroup.detachesHiddenViews = true
        [profileRow, portRow, healthRow, gitNameRow, gitEmailRow, resetButton].forEach {
            advancedSettingsGroup.addArrangedSubview($0)
        }
        advancedSettingsGroup.isHidden = true
        advancedSettingsGroup.translatesAutoresizingMaskIntoConstraints = false

        let workspaceHelp = NSTextField(wrappingLabelWithString: "Choose the folder ChatGPT can work with. File tools can read, edit and delete files inside this folder.")
        workspaceHelp.font = .systemFont(ofSize: 12)
        workspaceHelp.textColor = .secondaryLabelColor
        workspaceHelp.preferredMaxLayoutWidth = Layout.contentWidth
        workspaceHelp.widthAnchor.constraint(equalToConstant: Layout.contentWidth).isActive = true
        directoryField.lineBreakMode = .byTruncatingMiddle
        directoryField.delegate = self
        enableCommandsCheckbox.target = self
        enableCommandsCheckbox.action = #selector(workspaceOptionsChanged)
        let settingsForm = NSStackView(views: [
            workspaceHelp,
            directoryRow,
            enableCommandsCheckbox,
            commandWarning,
            enableGitPushCheckbox,
            enableCodexHistoryCheckbox,
            extraPermissionsHelp,
            advancedToggleButton,
            advancedSettingsGroup,
        ])
        settingsForm.orientation = .vertical
        settingsForm.alignment = .leading
        settingsForm.spacing = 8
        settingsForm.setCustomSpacing(14, after: commandWarning)
        settingsForm.setCustomSpacing(10, after: advancedToggleButton)
        settingsForm.translatesAutoresizingMaskIntoConstraints = false

        let settingsRoot = NSStackView(views: [settingsForm, saveSettingsButton])
        settingsRoot.orientation = .vertical
        settingsRoot.alignment = .leading
        settingsRoot.spacing = 10
        settingsRoot.translatesAutoresizingMaskIntoConstraints = false

        let settingsPage = NSScrollView()
        settingsPage.hasVerticalScroller = true
        settingsPage.scrollerStyle = .overlay
        settingsPage.drawsBackground = false
        let settingsDocument = TopAlignedDocumentView()
        settingsDocument.translatesAutoresizingMaskIntoConstraints = false
        settingsPage.documentView = settingsDocument
        settingsDocument.addSubview(settingsRoot)
        NSLayoutConstraint.activate([
            settingsDocument.widthAnchor.constraint(equalTo: settingsPage.contentView.widthAnchor),
            settingsRoot.leadingAnchor.constraint(equalTo: settingsDocument.leadingAnchor, constant: 12),
            settingsRoot.trailingAnchor.constraint(equalTo: settingsDocument.trailingAnchor, constant: -12),
            settingsRoot.topAnchor.constraint(equalTo: settingsDocument.topAnchor, constant: 12),
            settingsRoot.bottomAnchor.constraint(equalTo: settingsDocument.bottomAnchor, constant: -12),
        ])

        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let logPage = NSView()
        followLogsCheckbox.state = .on
        followLogsCheckbox.target = self
        followLogsCheckbox.action = #selector(followLogsChanged)
        followLogsCheckbox.toolTip = "Scroll to new output. Turn off to read earlier logs."
        copyLogsButton.target = self
        copyLogsButton.action = #selector(copyLogs)
        copyLogsButton.isEnabled = false
        copyLogsButton.bezelStyle = .rounded
        copyLogsButton.toolTip = "Copy the displayed, redacted runtime logs"
        let clearLogsButton = NSButton(title: "Clear", target: self, action: #selector(clearLogs))
        clearLogsButton.bezelStyle = .rounded
        clearLogsButton.toolTip = "Clear displayed logs without stopping the connection"
        let logToolbar = NSStackView(views: [followLogsCheckbox, NSView(), copyLogsButton, clearLogsButton])
        logToolbar.orientation = .horizontal
        logToolbar.translatesAutoresizingMaskIntoConstraints = false
        logPage.addSubview(logToolbar)
        logPage.addSubview(logScroll)
        activityEmptyLabel.font = .systemFont(ofSize: 12)
        activityEmptyLabel.textColor = .secondaryLabelColor
        activityEmptyLabel.alignment = .center
        activityEmptyLabel.translatesAutoresizingMaskIntoConstraints = false
        logPage.addSubview(activityEmptyLabel)
        NSLayoutConstraint.activate([
            activityEmptyLabel.centerXAnchor.constraint(equalTo: logScroll.centerXAnchor),
            activityEmptyLabel.centerYAnchor.constraint(equalTo: logScroll.centerYAnchor),
            activityEmptyLabel.widthAnchor.constraint(lessThanOrEqualTo: logScroll.widthAnchor, constant: -32),
            logScroll.leadingAnchor.constraint(equalTo: logPage.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: logPage.trailingAnchor, constant: -12),
            logToolbar.leadingAnchor.constraint(equalTo: logPage.leadingAnchor, constant: 12),
            logToolbar.trailingAnchor.constraint(equalTo: logPage.trailingAnchor, constant: -12),
            logToolbar.topAnchor.constraint(equalTo: logPage.topAnchor, constant: 8),
            logScroll.topAnchor.constraint(equalTo: logToolbar.bottomAnchor, constant: 8),
            logScroll.bottomAnchor.constraint(equalTo: logPage.bottomAnchor, constant: -12),
        ])

        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.delegate = self

        let configTab = NSTabViewItem(identifier: "config")
        configTab.label = "Connection"
        configTab.view = connectionPage

        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Workspace"
        settingsTab.view = settingsPage

        let logTab = NSTabViewItem(identifier: "log")
        logTab.label = "Activity"
        logTab.view = logPage

        tabs.addTabViewItem(configTab)
        tabs.addTabViewItem(settingsTab)
        tabs.addTabViewItem(logTab)

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        connectionStatusLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        connectionDetailLabel.font = .systemFont(ofSize: 11)
        connectionDetailLabel.textColor = .secondaryLabelColor
        connectionDetailLabel.lineBreakMode = .byTruncatingMiddle
        connectionDetailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let statusText = NSStackView(views: [connectionStatusLabel, connectionDetailLabel])
        statusText.orientation = .vertical
        statusText.alignment = .leading
        statusText.spacing = 4
        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        let statusRow = NSStackView(views: [activityIndicator, statusText, NSView(), startButton])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 12
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerDivider)
        footer.addSubview(statusRow)

        let workspaceIcon = NSImageView()
        workspaceIcon.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Shared workspace")
        workspaceIcon.contentTintColor = .secondaryLabelColor
        workspaceIcon.translatesAutoresizingMaskIntoConstraints = false
        workspaceSummaryLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        workspaceSummaryLabel.textColor = .labelColor
        workspaceSummaryLabel.lineBreakMode = .byTruncatingMiddle
        workspaceSummaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        workspaceSummaryLabel.setAccessibilityLabel("Shared workspace")
        workspaceAccessLabel.font = .systemFont(ofSize: 11, weight: .medium)
        workspaceAccessLabel.textColor = .secondaryLabelColor
        workspaceAccessLabel.translatesAutoresizingMaskIntoConstraints = false
        workspaceAccessLabel.setContentHuggingPriority(.required, for: .horizontal)
        let accessBadge = NSBox()
        accessBadge.boxType = .custom
        accessBadge.titlePosition = .noTitle
        accessBadge.setContentHuggingPriority(.required, for: .horizontal)
        accessBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
        accessBadge.borderWidth = 0
        accessBadge.fillColor = .controlBackgroundColor
        accessBadge.cornerRadius = 6
        accessBadge.contentViewMargins = .zero
        accessBadge.translatesAutoresizingMaskIntoConstraints = false
        accessBadge.contentView!.addSubview(workspaceAccessLabel)
        NSLayoutConstraint.activate([
            workspaceIcon.widthAnchor.constraint(equalToConstant: 18),
            workspaceIcon.heightAnchor.constraint(equalToConstant: 18),
            workspaceAccessLabel.leadingAnchor.constraint(equalTo: accessBadge.contentView!.leadingAnchor, constant: 9),
            workspaceAccessLabel.trailingAnchor.constraint(equalTo: accessBadge.contentView!.trailingAnchor, constant: -9),
            workspaceAccessLabel.topAnchor.constraint(equalTo: accessBadge.contentView!.topAnchor, constant: 5),
            workspaceAccessLabel.bottomAnchor.constraint(equalTo: accessBadge.contentView!.bottomAnchor, constant: -5),
        ])
        let header = NSStackView(views: [workspaceIcon, workspaceSummaryLabel, NSView(), accessBadge])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10
        header.translatesAutoresizingMaskIntoConstraints = false
        feedbackLabel.font = .systemFont(ofSize: 12)
        feedbackLabel.maximumNumberOfLines = 3
        feedbackLabel.preferredMaxLayoutWidth = Layout.contentWidth - 110
        feedbackLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        viewLogsButton.bezelStyle = .inline
        viewLogsButton.target = self
        viewLogsButton.action = #selector(showActivity)
        viewLogsButton.isHidden = true
        let feedbackRow = NSStackView(views: [feedbackLabel, NSView(), viewLogsButton])
        feedbackRow.orientation = .horizontal
        feedbackRow.alignment = .centerY
        feedbackRow.spacing = 8
        feedbackRow.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(feedbackRow)
        view.addSubview(tabs)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 16),
            tabs.bottomAnchor.constraint(equalTo: feedbackRow.topAnchor, constant: -8),
            feedbackRow.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            feedbackRow.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            feedbackRow.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
            feedbackRow.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),

            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Layout.footerHeight),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            statusRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            statusRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            statusRow.centerYAnchor.constraint(equalTo: footer.centerYAnchor),
            statusText.widthAnchor.constraint(lessThanOrEqualToConstant: Layout.contentWidth - 160),
            startButton.widthAnchor.constraint(equalToConstant: 140),
            startButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),

            saveSettingsButton.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            connectionRoot.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            settingsForm.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            tunnelIDField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            apiKeyField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cloudflareTunnelNameField.widthAnchor.constraint(equalToConstant: Layout.contentWidth - Layout.directoryButtonWidth - 8),
            cloudflareRefreshButton.widthAnchor.constraint(equalToConstant: Layout.directoryButtonWidth),
            cloudflareTokenField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cloudflareCLIStatusLabel.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            cloudflareHostnameField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            profileField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            portField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            directoryField.widthAnchor.constraint(equalToConstant: Layout.directoryFieldWidth),
            chooseButton.widthAnchor.constraint(equalToConstant: Layout.directoryButtonWidth),
            healthAddressField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            gitUserNameField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
            gitUserEmailField.widthAnchor.constraint(equalToConstant: Layout.fieldWidth),
        ])
    }

    private func configure(_ field: NSTextField, placeholder: String) {
        field.placeholderString = placeholder
        field.controlSize = .regular
        field.isEditable = true
        field.isSelectable = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = .systemFont(ofSize: 13)
        field.setAccessibilityLabel(placeholder)
        (field as? NSSecureTextField)?.usesSingleLineMode = true
    }

    private func loadConfiguration() {
        let defaults = UserDefaults.standard
        tunnelIDField.stringValue = defaults.string(forKey: ConfigKey.tunnelID) ?? ""
        apiKeyField.stringValue = ""
        updateAPIKeyPlaceholder()
        cloudflareHostnameField.stringValue = defaults.string(forKey: ConfigKey.cloudflareHostname) ?? ""
        allowCloudflareURLSecretCheckbox.state = defaults.bool(forKey: ConfigKey.allowCloudflareURLSecret) ? .on : .off
        cloudflareTunnelNameField.stringValue = ""
        cloudflareTokenField.stringValue = ""
        updateCloudflareCredentialStatus()
        // A saved tunnel name isn't secret, so show it; a saved token stays hidden.
        let savedTunnel = (try? storage.readCloudflareToken()) ?? ""
        let savedTunnelIsName = LocalMCPRuntime.isCloudflareTunnelName(savedTunnel)
        if savedTunnelIsName {
            cloudflareTunnelNameField.stringValue = savedTunnel
        }
        let savedProvider = TunnelProvider(rawValue: defaults.string(forKey: ConfigKey.provider) ?? "") ?? .openAI
        let usesToken = defaults.string(forKey: ConfigKey.cloudflareTunnelSource).map { $0 == "token" }
            ?? (!savedTunnel.isEmpty && !savedTunnelIsName)
        providerPopup.selectItem(at: savedProvider == .openAI ? 0 : (usesToken ? 2 : 1))
        applyProviderSelection()
        profileField.stringValue = defaults.string(forKey: ConfigKey.profile) ?? "filemcp"
        portField.stringValue = defaults.string(forKey: ConfigKey.port) ?? "8008"
        directoryField.stringValue = defaults.string(forKey: ConfigKey.allowedDirectory) ?? defaultDirectory()
        healthAddressField.stringValue = defaults.string(forKey: ConfigKey.healthAddress) ?? "127.0.0.1:0"
        gitUserNameField.stringValue = defaults.string(forKey: ConfigKey.gitUserName) ?? ""
        gitUserEmailField.stringValue = defaults.string(forKey: ConfigKey.gitUserEmail) ?? ""
        enableCommandsCheckbox.state = defaults.bool(forKey: ConfigKey.enableCommands) ? .on : .off
        enableGitPushCheckbox.state = defaults.bool(forKey: ConfigKey.enableGitPush) ? .on : .off
        enableCodexHistoryCheckbox.state = defaults.bool(forKey: ConfigKey.enableCodexHistory) ? .on : .off
        updateWorkspaceSummary()
    }

    private func updateAPIKeyPlaceholder() {
        let hasSavedKey = storage.hasSavedAPIKey
        hasStoredAPIKey = hasSavedKey
        apiKeyField.placeholderString = hasSavedKey
            ? "Saved — leave blank to keep it"
            : "sk-..."
        apiKeyStatusLabel.stringValue = hasSavedKey
            ? "API key is saved in Keychain"
            : "No API key is saved"
        deleteKeyButton.isEnabled = hasSavedKey
    }

    private func updateCloudflareCredentialStatus() {
        let saved = (try? storage.readCloudflareToken()) ?? ""
        hasStoredCloudflareCredential = !saved.isEmpty
        let savedName = LocalMCPRuntime.isCloudflareTunnelName(saved) ? saved : nil
        let hasSavedToken = !saved.isEmpty && savedName == nil
        cloudflareTokenField.placeholderString = hasSavedToken ? "Saved — leave blank to keep it" : "eyJ…"
        if let savedName {
            cloudflareTokenStatusLabel.stringValue = "Tunnel “\(savedName)” is saved"
        } else {
            cloudflareTokenStatusLabel.stringValue = hasSavedToken
                ? "Tunnel token is saved in Keychain"
                : "No tunnel is saved"
        }
        deleteCloudflareTokenButton.title = savedName == nil ? "Delete token" : "Forget tunnel"
        deleteCloudflareTokenButton.isEnabled = !saved.isEmpty
    }

    private var selectedProvider: TunnelProvider {
        providerPopup.indexOfSelectedItem == 0 ? .openAI : .cloudflare
    }

    /// Cloudflare with a dashboard token instead of a tunnel in the logged-in account.
    private var usesCloudflareToken: Bool {
        providerPopup.indexOfSelectedItem == 2
    }

    @objc private func providerChanged() {
        applyProviderSelection()
    }

    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field's text updates after this callback fires.
        DispatchQueue.main.async { [weak self] in self?.updateCloudflareActionStates() }
    }

    func controlTextDidChange(_ notification: Notification) {
        let source = notification.object as? NSTextField
        if source === cloudflareHostnameField {
            updateMCPURLDisplay()
        } else if source === cloudflareTunnelNameField {
            updateCloudflareActionStates()
        } else if source === directoryField {
            updateWorkspaceSummary()
        }
    }

    private func applyProviderSelection() {
        let cloudflare = selectedProvider == .cloudflare
        openAIGroup.isHidden = cloudflare
        openAIKeyRow.isHidden = cloudflare
        cloudflareGroup.isHidden = !cloudflare
        cloudflareKeyRow.isHidden = !cloudflare
        cloudflareNameSection.isHidden = usesCloudflareToken
        cloudflareTokenSection.isHidden = !usesCloudflareToken
        cloudflareAccountActions?.isHidden = usesCloudflareToken
        connectionHelpLabel.stringValue = cloudflare
            ? "Choose a tunnel and hostname to share this workspace."
            : "Enter your Secure MCP Tunnel details. Connect saves changes automatically."
        shareConnectionSection.isHidden = !cloudflare
        if cloudflare {
            updateMCPURLDisplay()
            if loadsSavedConfiguration && !usesCloudflareToken {
                refreshCloudflareTunnels()
            }
        }
        updateConnectionPresentation()
        updateWindowHeight()
    }

    @objc private func toggleCloudflareManagement() {
        cloudflareManagementGroup.isHidden.toggle()
        cloudflareManagementToggle.image = advancedChevron(expanded: !cloudflareManagementGroup.isHidden)
        updateWindowHeight()
    }

    private func updateConnectionPresentation() {
        let active = !configurationIsEditable
        connectionFormView?.isHidden = active
        connectionSaveView?.isHidden = active
        connectionKeyView?.isHidden = active
        connectionDivider?.isHidden = active
        connectionHelpLabel.isHidden = active
        activeConnectionSummary.isHidden = !active
        let provider = selectedProvider == .cloudflare ? "Cloudflare Tunnel" : "Secure MCP Tunnel"
        let detail = selectedProvider == .cloudflare
            ? (usesCloudflareToken ? normalizedCloudflareHostname() : cloudflareTunnelNameField.stringValue)
            : tunnelIDField.stringValue
        activeConnectionSummary.stringValue = "\(provider) · \(detail)\nDisconnect to edit connection settings."
        shareConnectionSection.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        view.layoutSubtreeIfNeeded()
    }

    private func normalizedCloudflareHostname() -> String {
        cloudflareHostnameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Cached so typing a hostname does not hit Keychain on every keystroke.
    private func pathSecret() throws -> String {
        if let cachedPathSecret { return cachedPathSecret }
        let secret = try storage.cloudflarePathSecret()
        cachedPathSecret = secret
        return secret
    }

    private func connectionSecret() throws -> String {
        if allowCloudflareURLSecretCheckbox.state == .on { return try pathSecret() }
        if let cachedPairingSecret { return cachedPairingSecret }
        let token = try storage.cloudflarePairingSecret()
        cachedPairingSecret = token
        return token
    }

    @objc private func cloudflareURLSecretChanged() {
        if allowCloudflareURLSecretCheckbox.state == .on {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Use a secret URL for authentication?"
            alert.informativeText = "Anyone with the URL can access the enabled MCP tools. External clients or proxies may log this URL. Use this compatibility mode only if your client cannot send a Bearer token."
            alert.addButton(withTitle: "Use secret URL")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { allowCloudflareURLSecretCheckbox.state = .off }
        }
        applyProviderSelection()
    }

    @objc private func copyMCPToken() {
        guard allowCloudflareURLSecretCheckbox.state == .off, let token = try? connectionSecret() else { return }
        copyConnectionValue(token, message: "Login code copied. Paste it only into your FileMCP authorization page.")
    }

    private func fullMCPURL() -> String? {
        let hostname = normalizedCloudflareHostname()
        guard LocalMCPRuntime.isValidPublicHostname(hostname) else { return nil }
        if allowCloudflareURLSecretCheckbox.state == .off { return "https://\(hostname)/mcp" }
        guard let secret = try? pathSecret() else { return nil }
        return "https://\(hostname)/mcp/\(secret)"
    }

    private func updateMCPURLDisplay() {
        let hostname = normalizedCloudflareHostname()
        let valid = LocalMCPRuntime.isValidPublicHostname(hostname)
        // Show the URL with the secret masked; Copy puts the full URL on the pasteboard.
        if valid {
            do {
                let secret = try connectionSecret()
                mcpURLField.stringValue = allowCloudflareURLSecretCheckbox.state == .on
                    ? "https://\(hostname)/mcp/\(secret.prefix(4))••••••••"
                    : "https://\(hostname)/mcp"
            } catch {
                mcpURLField.stringValue = "Could not read the URL secret: \(error.localizedDescription)"
            }
        } else {
            mcpURLField.stringValue = ""
        }
        let usesURLSecret = allowCloudflareURLSecretCheckbox.state == .on
        shareConnectionHelpLabel.stringValue = usesURLSecret
            ? "Compatibility mode: anyone with this URL can access the enabled tools. Keep it private."
            : "Add this URL in ChatGPT with OAuth. When prompted, paste the login code from this app."
        copyTokenButton.isHidden = usesURLSecret
        copyTokenButton.isEnabled = valid && cachedPairingSecret != nil
        mcpURLWidthConstraint?.constant = Layout.contentWidth - 28
        copyURLButton.isEnabled = valid && (usesURLSecret ? cachedPathSecret != nil : cachedPairingSecret != nil)
        updateCloudflareActionStates()
    }

    @objc private func copyMCPURL() {
        guard let url = fullMCPURL() else {
            showError("Enter a valid public hostname first.")
            return
        }
        copyConnectionValue(url, message: "MCP URL copied. The clipboard clears in 2 minutes.")
    }

    private func copyConnectionValue(_ value: String, message: String) {
        // The concealed marker asks clipboard managers not to record the secret, and the
        // URL is cleared after a while unless something else has been copied since.
        let pasteboard = NSPasteboard.general
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        pasteboard.declareTypes([.string, concealed], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealed)
        let changeCount = pasteboard.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) {
            if pasteboard.changeCount == changeCount { pasteboard.clearContents() }
        }
        appendLog("Connection value copied to the clipboard; automatic clearing is enabled.\n")
        showFeedback(message)
    }

    private func updateCloudflareActionStates() {
        if configurationIsEditable {
            providerPopup.isEnabled = !cloudflareBusy
            startButton.isEnabled = !cloudflareBusy
            saveConnectionButton.isEnabled = !cloudflareBusy
            resetButton.isEnabled = !cloudflareBusy
        }
        allowCloudflareURLSecretCheckbox.isEnabled = configurationIsEditable && !cloudflareBusy
        cloudflareTunnelNameField.isEnabled = configurationIsEditable && !cloudflareBusy
        cloudflareHostnameField.isEnabled = configurationIsEditable && !cloudflareBusy
        let name = cloudflareTunnelNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostnameValid = LocalMCPRuntime.isValidPublicHostname(normalizedCloudflareHostname())
        let canCreate = cloudflareLoggedIn
            && !cloudflareBusy
            && configurationIsEditable
            && LocalMCPRuntime.isCloudflareTunnelName(name)
            && !knownCloudflareTunnelNames.contains(name)
            && hostnameValid
        cloudflareCreateButton.isEnabled = canCreate
        let loginInProgress = cloudflareLoginCancellation != nil
        cloudflareLoginButton.isEnabled = configurationIsEditable && (!cloudflareBusy || loginInProgress)
        cloudflareRefreshButton.isEnabled = configurationIsEditable && !cloudflareBusy
        cloudflareLoginButton.title = loginInProgress
            ? "Cancel login"
            : (cloudflareLoggedIn ? "Switch account…" : "Log in to Cloudflare…")
        cloudflareDeleteButton.isEnabled = cloudflareLoggedIn
            && !cloudflareBusy
            && configurationIsEditable
            && knownCloudflareTunnelNames.contains(name)
        // A running server keeps accepting the secret it started with, so rotating
        // while connected would leave the old URL live.
        regenerateURLButton.isEnabled = hostnameValid && configurationIsEditable && !cloudflareBusy
        regenerateURLButton.toolTip = configurationIsEditable
            ? (allowCloudflareURLSecretCheckbox.state == .on ? "Reset the secret URL. The previous URL stops working." : "Reset the login code and revoke all OAuth sessions for this hostname.")
            : "Disconnect before resetting the connection credential."
    }

    @objc private func refreshCloudflareTunnelsAction() {
        refreshCloudflareTunnels()
    }

    private func refreshCloudflareTunnels() {
        // Another cloudflared operation is running; its completion refreshes the list.
        guard !cloudflareBusy else { return }
        cloudflareLoggedIn = CloudflareCLI.isLoggedIn()
        guard cloudflareLoggedIn else {
            knownCloudflareTunnelNames = []
            cloudflareTunnelNameField.removeAllItems()
            cloudflareCLIStatusLabel.stringValue = "Not logged in to Cloudflare. Log in to list or create tunnels."
            updateCloudflareActionStates()
            return
        }
        cloudflareBusy = true
        cloudflareCLIStatusLabel.stringValue = "Loading tunnels…"
        updateCloudflareActionStates()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CloudflareCLI.listTunnels() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudflareBusy = false
                switch result {
                case let .success(tunnels):
                    self.knownCloudflareTunnelNames = tunnels.map(\.name)
                    let selectedName = self.cloudflareTunnelNameField.stringValue
                    self.cloudflareTunnelNameField.removeAllItems()
                    self.cloudflareTunnelNameField.addItems(withObjectValues: self.knownCloudflareTunnelNames)
                    self.cloudflareTunnelNameField.stringValue = selectedName
                    let missingCredentials = tunnels.filter { CloudflareCLI.localCredentialsPath(for: $0) == nil }.count
                    self.cloudflareCLIStatusLabel.stringValue = tunnels.isEmpty
                        ? "Logged in · no tunnels yet. Type a name and click Create."
                        : "Logged in · \(tunnels.count) tunnels · \(missingCredentials) without local credentials"
                    self.cloudflareCLIStatusLabel.toolTip = "Tunnels without local credentials require the dashboard token provider. Connect checks credentials before starting."
                case let .failure(error):
                    self.cloudflareCLIStatusLabel.stringValue = error.localizedDescription
                }
                self.updateCloudflareActionStates()
            }
        }
    }

    @objc private func cloudflareLogin() {
        if let cloudflareLoginCancellation {
            cloudflareLoginCancellation.cancel()
            cloudflareCLIStatusLabel.stringValue = "Cancelling login…"
            return
        }
        let switching = cloudflareLoggedIn
        if switching {
            let alert = NSAlert()
            alert.messageText = "Log in to a different Cloudflare account?"
            alert.informativeText = "cloudflared keeps one login certificate. FileMCP renames the current one to a .bak file before opening the browser, and puts it back if the new login does not finish."
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        let cancellation = CancellationFlag()
        cloudflareLoginCancellation = cancellation
        cloudflareBusy = true
        updateCloudflareActionStates()
        cloudflareCLIStatusLabel.stringValue = "Waiting for you to authorize in the browser…"
        appendLog("Opening Cloudflare login in your browser…\n")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try CloudflareCLI.login(replacingExisting: switching, shouldCancel: { cancellation.isCancelled })
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudflareBusy = false
                self.cloudflareLoginCancellation = nil
                switch result {
                case let .success(backup):
                    self.appendLog("Cloudflare login completed.\n")
                    if let backup {
                        self.appendLog("The previous login certificate was kept at \(backup). Delete it if you no longer need that account.\n")
                    }
                case let .failure(error) where CloudflareCLI.isCancellation(error):
                    self.appendLog("Cloudflare login cancelled.\n")
                case let .failure(error):
                    self.showError(error.localizedDescription)
                }
                self.refreshCloudflareTunnels()
            }
        }
    }

    @objc private func createCloudflareTunnel() {
        let name = cloudflareTunnelNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let hostname = normalizedCloudflareHostname()
        let alert = NSAlert()
        alert.messageText = "Create Cloudflare tunnel “\(name)”?"
        alert.informativeText = "This creates a tunnel named \(name) in your Cloudflare account and adds a DNS CNAME record for \(hostname) pointing to it."
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        cloudflareBusy = true
        updateCloudflareActionStates()
        cloudflareCLIStatusLabel.stringValue = "Creating tunnel…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var created = false
            let result = Result<Void, Error> {
                try CloudflareCLI.createTunnel(name: name)
                created = true
                try CloudflareCLI.routeDNS(tunnel: name, hostname: hostname)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudflareBusy = false
                switch result {
                case .success:
                    self.appendLog("Created Cloudflare tunnel \(name) and routed \(hostname) to it.\n")
                case let .failure(error):
                    let prefix = created ? "Tunnel \(name) was created, but routing DNS failed: " : ""
                    self.showError(prefix + error.localizedDescription)
                }
                self.refreshCloudflareTunnels()
            }
        }
    }

    @objc private func deleteCloudflareTunnel() {
        let name = cloudflareTunnelNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isRuntimeIdle else {
            showError("Disconnect before deleting a tunnel.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Delete Cloudflare tunnel “\(name)”?"
        alert.informativeText = "The tunnel is permanently deleted from your Cloudflare account, along with its local credentials file. Hostnames routed to it stop working. DNS records are not removed — delete them in the Cloudflare dashboard (DNS) if you no longer need them."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        cloudflareBusy = true
        updateCloudflareActionStates()
        cloudflareCLIStatusLabel.stringValue = "Deleting tunnel…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try CloudflareCLI.deleteTunnel(name: name) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.cloudflareBusy = false
                switch result {
                case .success:
                    self.appendLog("Deleted Cloudflare tunnel \(name). Remove its DNS record in the Cloudflare dashboard if no longer needed.\n")
                    // Forget the saved reference if it pointed at the deleted tunnel.
                    if let saved = try? self.storage.readCloudflareToken(), saved == name {
                        try? self.storage.deleteCloudflareToken()
                        self.updateCloudflareCredentialStatus()
                    }
                    self.cloudflareTunnelNameField.stringValue = ""
                case let .failure(error):
                    self.showError(error.localizedDescription)
                }
                self.refreshCloudflareTunnels()
            }
        }
    }

    @objc private func regenerateMCPURL() {
        guard isRuntimeIdle else {
            showError("Disconnect before resetting the connection credential.")
            return
        }
        let alert = NSAlert()
        let usesURLSecret = allowCloudflareURLSecretCheckbox.state == .on
        alert.messageText = usesURLSecret ? "Regenerate the MCP URL secret?" : "Reset the OAuth login code and sessions?"
        alert.informativeText = usesURLSecret
            ? "The current URL stops working. Update your client with the new URL."
            : "All OAuth sessions for this hostname will be revoked. Use the new login code to reconnect your client."
        alert.addButton(withTitle: "Regenerate")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            if usesURLSecret { cachedPathSecret = try storage.regenerateCloudflarePathSecret() }
            else {
                cachedPairingSecret = try storage.regenerateCloudflarePairingSecret()
            }
            updateMCPURLDisplay()
            appendLog("Connection credential reset. Reconnect your client.\n")
        } catch {
            showError(error.localizedDescription)
        }
    }

    /// With Cloudflare the MCP URL is public, so shell access is one leaked URL away from remote code execution.
    private func confirmPublicShellCommands() -> Bool {
        let defaults = UserDefaults.standard
        guard selectedProvider == .cloudflare,
              enableCommandsCheckbox.state == .on,
              !defaults.bool(forKey: ConfigKey.publicShellCommandsAcknowledged) else {
            return true
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Allow shell commands on a public URL?"
        alert.informativeText = "With Cloudflare Tunnel, anyone who has the MCP credential can run commands as your macOS user, not just read the shared directory. Keep the URL private, or turn off “Allow shell commands” in Workspace."
        alert.addButton(withTitle: "Connect anyway")
        alert.addButton(withTitle: "Cancel")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don’t ask again"
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        if alert.suppressionButton?.state == .on {
            defaults.set(true, forKey: ConfigKey.publicShellCommandsAcknowledged)
        }
        return true
    }

    private func defaultDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/FileMCP", isDirectory: true).path
    }

    private func saveConnectionConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.tunnelID)
        defaults.set(selectedProvider.rawValue, forKey: ConfigKey.provider)
        defaults.set(normalizedCloudflareHostname(), forKey: ConfigKey.cloudflareHostname)
        defaults.set(allowCloudflareURLSecretCheckbox.state == .on, forKey: ConfigKey.allowCloudflareURLSecret)
        defaults.set(usesCloudflareToken ? "token" : "name", forKey: ConfigKey.cloudflareTunnelSource)
    }

    private func persistTypedSecrets() throws {
        let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typedKey.isEmpty {
            try storage.saveAPIKey(typedKey)
            apiKeyField.stringValue = ""
            updateAPIKeyPlaceholder()
        }
        // Only the visible Cloudflare field is saved; it replaces whichever tunnel was saved before.
        guard selectedProvider == .cloudflare else { return }
        let field: NSTextField = usesCloudflareToken ? cloudflareTokenField : cloudflareTunnelNameField
        let typed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return }
        try storage.saveCloudflareToken(typed)
        if usesCloudflareToken {
            cloudflareTokenField.stringValue = ""
        }
        updateCloudflareCredentialStatus()
    }

    private func saveSettingsConfiguration() {
        let defaults = UserDefaults.standard
        defaults.set(profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.profile)
        defaults.set(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.port)
        defaults.set(directoryField.stringValue, forKey: ConfigKey.allowedDirectory)
        defaults.set(healthAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.healthAddress)
        defaults.set(gitUserNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.gitUserName)
        defaults.set(gitUserEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.gitUserEmail)
        defaults.set(enableCommandsCheckbox.state == .on, forKey: ConfigKey.enableCommands)
        defaults.set(enableGitPushCheckbox.state == .on, forKey: ConfigKey.enableGitPush)
        defaults.set(enableCodexHistoryCheckbox.state == .on, forKey: ConfigKey.enableCodexHistory)
    }

    private func saveAllConfiguration() {
        saveConnectionConfiguration()
        saveSettingsConfiguration()
    }

    @objc private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose directory"
        if panel.runModal() == .OK, let url = panel.url {
            directoryField.stringValue = url.path
            updateWorkspaceSummary()
        }
    }

    @objc private func startTunnel() {
        switch runtime.state {
        case .running, .starting:
            runtime.stop()
            return
        case .stopping:
            return
        case .stopped, .failed:
            break
        }

        guard !cloudflareBusy else {
            showFeedback("Finish the Cloudflare account operation before connecting.", isError: true)
            return
        }
        guard validateConnectionConfiguration(requireAPIKey: true),
              validateSettingsConfiguration(),
              confirmPublicShellCommands() else {
            return
        }

        do {
            try persistTypedSecrets()
            let provider = selectedProvider
            let apiKey = provider == .openAI ? try storage.readAPIKey() : ""
            let cloudflareToken = provider == .cloudflare ? try storage.readCloudflareToken() : ""
            let cloudflareSecret = provider == .cloudflare ? try connectionSecret() : ""
            saveAllConfiguration()
            updateWorkspaceSummary()
            showFeedback("")
            updateMCPURLDisplay()
            guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                showError("The MCP port is invalid.")
                return
            }

            let hostname = normalizedCloudflareHostname()
            let usesOAuth = provider == .cloudflare && allowCloudflareURLSecretCheckbox.state == .off
            let oauthState = usesOAuth ? try storage.readCloudflareOAuthState(hostname: hostname) : nil
            let saveOAuthState: ((Data) throws -> Void)? = usesOAuth ? { [storage] data in
                try storage.saveCloudflareOAuthState(data, hostname: hostname)
            } : nil
            runtime.start(LocalMCPConfiguration(
                provider: provider,
                tunnelID: tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey,
                cloudflareToken: cloudflareToken,
                cloudflareHostname: normalizedCloudflareHostname(),
                cloudflarePathSecret: cloudflareSecret,
                allowCloudflareURLSecret: allowCloudflareURLSecretCheckbox.state == .on,
                cloudflareOAuthState: oauthState,
                saveCloudflareOAuthState: saveOAuthState,
                profile: profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                allowedDirectory: directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                healthAddress: healthAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                gitUserName: gitUserNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                gitUserEmail: gitUserEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                enableCommands: enableCommandsCheckbox.state == .on,
                enableGitPush: enableGitPushCheckbox.state == .on,
                enableCodexHistory: enableCodexHistoryCheckbox.state == .on
            ))
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func saveConnectionOnly() {
        guard validateConnectionConfiguration(requireAPIKey: true) else {
            return
        }

        saveConnectionButton.setLoading(true)
        do {
            try persistTypedSecrets()
            saveConnectionConfiguration()
            updateMCPURLDisplay()
            appendLog("Connection settings saved.\n")
            if runtime.state != .stopped {
                appendLog("Changes will take effect the next time the tunnel starts.\n")
            }
            finishLoading(saveConnectionButton)
        } catch {
            saveConnectionButton.setLoading(false)
            showError(error.localizedDescription)
        }
    }

    @objc private func saveSettingsOnly() {
        guard validateSettingsConfiguration() else {
            return
        }

        saveSettingsButton.setLoading(true)
        saveSettingsConfiguration()
        appendLog("Settings saved.\n")
        if runtime.state != .stopped {
            appendLog("Changes will take effect the next time the tunnel starts.\n")
        }
        finishLoading(saveSettingsButton)
    }

    private func finishLoading(_ button: LoadingButton) {
        showFeedback("Changes saved. Connect uses the latest settings.")
        let originalTitle = button.title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self, weak button] in
            guard let self, self.configurationIsEditable else { return }
            button?.setLoading(false)
            button?.title = "Saved"
            button?.isEnabled = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self, weak button] in
                button?.title = originalTitle
                button?.isEnabled = self?.configurationIsEditable == true
            }
        }
    }

    private func validateConnectionConfiguration(requireAPIKey: Bool) -> Bool {
        if selectedProvider == .cloudflare {
            let saved = (try? storage.readCloudflareToken()) ?? ""
            if usesCloudflareToken {
                let typedToken = cloudflareTokenField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typedToken.isEmpty, LocalMCPRuntime.isCloudflareTunnelName(typedToken) {
                    showError("That looks like a tunnel name, not a token. To use a named tunnel, set Provider to “Cloudflare Tunnel (log in with cloudflared)”.")
                    return false
                }
                if requireAPIKey && typedToken.isEmpty && (saved.isEmpty || LocalMCPRuntime.isCloudflareTunnelName(saved)) {
                    showError("Paste the tunnel token from Cloudflare Zero Trust (Networks → Tunnels) in the Connection tab.")
                    return false
                }
            } else {
                let typedName = cloudflareTunnelNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typedName.isEmpty, !LocalMCPRuntime.isCloudflareTunnelName(typedName) {
                    showError("Tunnel names start with a letter or number and use only letters, numbers, '.', '_' or '-'. To use a token, set Provider to “Cloudflare Tunnel (dashboard token)”.")
                    return false
                }
                if requireAPIKey && typedName.isEmpty && !LocalMCPRuntime.isCloudflareTunnelName(saved) {
                    showError("Pick or create a tunnel in the Connection tab.")
                    return false
                }
            }
            guard LocalMCPRuntime.isValidPublicHostname(normalizedCloudflareHostname()) else {
                showError("Enter the public hostname routed to the tunnel, such as mcp.example.com (no scheme, port or path).")
                return false
            }
            return true
        }
        let tunnelID = tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelID.isEmpty else {
            showError("Enter a Tunnel ID in the Connection tab.")
            return false
        }
        guard LocalMCPRuntime.isValidTunnelID(tunnelID) else {
            showError("Tunnel ID must match tunnel_<32 lowercase letters or digits>.")
            return false
        }
        if requireAPIKey && typedKey.isEmpty && !storage.hasSavedAPIKey {
            showError("Enter a Runtime API key in the Connection tab.")
            return false
        }
        return true
    }

    private func validateSettingsConfiguration() -> Bool {
        let profile = profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !directory.isEmpty else {
            tabs.selectTabViewItem(withIdentifier: "settings")
            showError("Choose a shared directory.")
            return false
        }
        guard !profile.isEmpty else {
            tabs.selectTabViewItem(withIdentifier: "settings")
            setAdvancedSettingsExpanded(true)
            showError("Profile cannot be empty.")
            return false
        }
        guard LocalMCPRuntime.isValidProfileName(profile) else {
            tabs.selectTabViewItem(withIdentifier: "settings")
            setAdvancedSettingsExpanded(true)
            showError("Profile must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 128 characters).")
            return false
        }
        guard let portNumber = UInt16(port), portNumber > 0 else {
            tabs.selectTabViewItem(withIdentifier: "settings")
            setAdvancedSettingsExpanded(true)
            showError("MCP port must be between 1 and 65535.")
            return false
        }
        let healthAddress = healthAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalMCPRuntime.normalizedHealthAddress(healthAddress) != nil else {
            tabs.selectTabViewItem(withIdentifier: "settings")
            setAdvancedSettingsExpanded(true)
            showError("Health listener must use localhost, 127.0.0.1, or [::1] with a port from 0 to 65535.")
            return false
        }
        return true
    }

    func showSettingsTab() {
        tabs.selectTabViewItem(withIdentifier: "settings")
    }

    func shutdownForTermination() {
        cloudflareLoginCancellation?.cancel()
        runtime.shutdownImmediately()
    }

    @objc private func deleteSavedKey() {
        do {
            if selectedProvider == .cloudflare {
                try storage.deleteCloudflareToken()
                cloudflareTunnelNameField.stringValue = ""
                cloudflareTokenField.stringValue = ""
                updateCloudflareCredentialStatus()
                updateCloudflareActionStates()
            } else {
                try storage.deleteAPIKey()
                apiKeyField.stringValue = ""
                updateAPIKeyPlaceholder()
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func resetAllSettings() {
        guard isRuntimeIdle && !cloudflareBusy else {
            showError("Disconnect and finish any Cloudflare account operation before resetting settings.")
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset all FileMCP settings?"
        alert.informativeText = "This deletes saved settings, API keys, Cloudflare credentials, login codes and OAuth sessions from Keychain, and generated tunnel profiles. Existing clients must reconnect. Your Cloudflare tunnel itself is not touched."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try storage.deleteAllSecrets()
            cachedPathSecret = nil
            cachedPairingSecret = nil
            let defaults = UserDefaults.standard
            ConfigKey.all.forEach { defaults.removeObject(forKey: $0) }
            if let profiles = LocalMCPRuntime.defaultTunnelProfilesDirectory(),
               FileManager.default.fileExists(atPath: profiles.path) {
                try FileManager.default.removeItem(at: profiles)
            }
            loadConfiguration()
            appendLog("All settings were reset.\n")
        } catch {
            showError(error.localizedDescription)
        }
    }

    private var isFailedRuntimeState: Bool {
        if case .failed = runtime.state { return true }
        return false
    }

    private var isRuntimeIdle: Bool {
        runtime.state == .stopped || isFailedRuntimeState
    }

    @objc private func toggleAdvancedSettings() {
        setAdvancedSettingsExpanded(advancedSettingsGroup.isHidden)
    }

    private func setAdvancedSettingsExpanded(_ expanded: Bool) {
        advancedSettingsGroup.isHidden = !expanded
        advancedToggleButton.image = advancedChevron(expanded: expanded)
        updateWindowHeight()
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        updateWindowHeight()
    }

    var preferredContentHeight: CGFloat {
        let screenHeight = (view.window?.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000
        return min(desiredContentHeight, max(360, screenHeight - 80))
    }

    private var desiredContentHeight: CGFloat {
        switch tabs.selectedTabViewItem?.identifier as? String {
        case "config":
            let minimum: CGFloat = !configurationIsEditable ? (selectedProvider == .cloudflare ? 500 : 360)
                : (selectedProvider == .openAI ? Layout.openAIConnectionWindowHeight : 640)
            guard let content = connectionContent else { return minimum }
            let contentHeight = ceil(content.fittingSize.height) + 24
            // Measure the space outside the viewport, including the header, tab strip,
            // feedback and fixed footer. Before attachment, reserve that same chrome.
            let viewportHeight = connectionScrollView?.contentView.bounds.height ?? 0
            let chrome = viewportHeight > 0 && view.bounds.height > viewportHeight
                ? view.bounds.height - viewportHeight : 232
            return max(minimum, ceil(contentHeight + chrome))
        case "settings":
            return advancedSettingsGroup.isHidden
                ? Layout.collapsedWindowHeight
                : Layout.expandedWindowHeight
        default:
            return 600
        }
    }

    private func updateWindowHeight() {
        guard let window = view.window else { return }

        let targetContentHeight = preferredContentHeight
        var contentRect = window.contentRect(forFrameRect: window.frame)
        guard abs(contentRect.height - targetContentHeight) > 0.5 else { return }

        let topEdge = window.frame.maxY
        contentRect.size.height = targetContentHeight
        var targetFrame = window.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = topEdge - targetFrame.height
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            targetFrame.origin.y = max(visible.minY, min(targetFrame.origin.y, visible.maxY - targetFrame.height))
            targetFrame.origin.x = max(visible.minX, min(targetFrame.origin.x, visible.maxX - targetFrame.width))
        }
        window.setFrame(targetFrame, display: true, animate: true)
    }

    private func advancedChevron(expanded: Bool) -> NSImage? {
        NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: expanded ? "Collapse advanced options" : "Expand advanced options"
        )
    }

    private func configureRuntime() {
        runtime.onLog = { [weak self] text in
            DispatchQueue.main.async {
                self?.appendLog(text)
            }
        }
        runtime.onStateChange = { [weak self] state in
            self?.updateRunButton(state: state)
            self?.updateCloudflareActionStates()
            if case let .failed(message) = state {
                self?.showFeedback(message, isError: true)
            }
        }
    }

    private func updateRunButton(state: LocalMCPRuntimeState) {
        switch state {
        case .stopped, .failed:
            startButton.title = "Connect"
            startButton.bezelColor = .controlAccentColor
            startButton.isEnabled = true
        case .starting:
            startButton.title = "Cancel connection"
            startButton.bezelColor = .controlAccentColor
            startButton.isEnabled = true
        case .running:
            startButton.title = "Disconnect"
            startButton.bezelColor = .systemRed
            startButton.isEnabled = true
        case .stopping:
            startButton.title = "Disconnecting…"
            startButton.bezelColor = .systemRed
            startButton.isEnabled = false
        }
        switch state {
        case .stopped:
            connectionStatusLabel.stringValue = "Disconnected"
            connectionStatusLabel.textColor = .secondaryLabelColor
        case .starting:
            connectionStatusLabel.stringValue = "Connecting…"
            connectionStatusLabel.textColor = .secondaryLabelColor
        case .running:
            connectionStatusLabel.stringValue = "Connected"
            connectionStatusLabel.textColor = .systemGreen
        case .stopping:
            connectionStatusLabel.stringValue = "Disconnecting…"
            connectionStatusLabel.textColor = .secondaryLabelColor
        case .failed:
            connectionStatusLabel.stringValue = "Connection failed"
            connectionStatusLabel.textColor = .systemRed
        }
        startButton.contentTintColor = .white
        updateInteractionState(state)
    }

    private func updateInteractionState(_ state: LocalMCPRuntimeState) {
        switch state {
        case .stopped, .failed: configurationIsEditable = true
        default: configurationIsEditable = false
        }
        for field in [tunnelIDField, apiKeyField, cloudflareTunnelNameField, cloudflareTokenField,
                      cloudflareHostnameField, profileField, portField, directoryField,
                      healthAddressField, gitUserNameField, gitUserEmailField] {
            field.isEnabled = configurationIsEditable
        }
        allowCloudflareURLSecretCheckbox.isEnabled = configurationIsEditable && !cloudflareBusy
        providerPopup.isEnabled = configurationIsEditable && !cloudflareBusy
        chooseDirectoryButton.isEnabled = configurationIsEditable
        enableCommandsCheckbox.isEnabled = configurationIsEditable
        enableGitPushCheckbox.isEnabled = configurationIsEditable
        enableCodexHistoryCheckbox.isEnabled = configurationIsEditable
        saveConnectionButton.setLoading(false)
        saveSettingsButton.setLoading(false)
        saveConnectionButton.isEnabled = configurationIsEditable && !cloudflareBusy
        saveSettingsButton.isEnabled = configurationIsEditable
        resetButton.isEnabled = configurationIsEditable && !cloudflareBusy
        deleteKeyButton.isEnabled = configurationIsEditable && hasStoredAPIKey
        deleteCloudflareTokenButton.isEnabled = configurationIsEditable && hasStoredCloudflareCredential
        switch state {
        case .starting:
            activityIndicator.startAnimation(nil)
            connectionDetailLabel.stringValue = "Starting the tunnel. You can cancel at any time."
        case .stopping:
            activityIndicator.startAnimation(nil)
            connectionDetailLabel.stringValue = "Stopping the tunnel and local server…"
        case .running:
            activityIndicator.stopAnimation(nil)
            connectionDetailLabel.stringValue = "Your workspace is shared. Disconnect stops access."
        case .failed:
            activityIndicator.stopAnimation(nil)
            connectionDetailLabel.stringValue = "Review the error or open Activity, then retry."
        case .stopped:
            activityIndicator.stopAnimation(nil)
            connectionDetailLabel.stringValue = "Connect saves your settings automatically."
        }
        startButton.toolTip = configurationIsEditable
            ? "Save your settings and connect to the selected workspace"
            : "Stop sharing the current workspace"
        updateCloudflareActionStates()
        updateConnectionPresentation()
        updateWindowHeight()
    }

    @objc private func workspaceOptionsChanged() { updateWorkspaceSummary() }

    private func updateWorkspaceSummary() {
        let path = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = (path as NSString).lastPathComponent
        let access = enableCommandsCheckbox.state == .on ? "Files + shell commands" : "Read & write files"
        let extras = [enableGitPushCheckbox.state == .on ? "Git push" : "", enableCodexHistoryCheckbox.state == .on ? "Codex history" : ""].filter { !$0.isEmpty }
        let permissionSummary = ([access] + extras).joined(separator: " + ")
        workspaceSummaryLabel.stringValue = path.isEmpty ? "Choose a workspace" : (folder.isEmpty ? path : folder)
        workspaceSummaryLabel.toolTip = path.isEmpty ? "Choose a folder in the Workspace tab" : (path + "\n" + permissionSummary)
        workspaceAccessLabel.stringValue = enableCommandsCheckbox.state == .on ? "Shell enabled" : (extras.isEmpty ? "File access" : "Extended access")
        workspaceAccessLabel.textColor = enableCommandsCheckbox.state == .on ? .systemOrange : .secondaryLabelColor
        workspaceAccessLabel.toolTip = permissionSummary
        directoryField.toolTip = path
    }

    private func showFeedback(_ message: String, isError: Bool = false) {
        feedbackRevision += 1
        let revision = feedbackRevision
        feedbackLabel.stringValue = message
        feedbackLabel.textColor = isError ? .systemRed : .secondaryLabelColor
        feedbackLabel.toolTip = message
        viewLogsButton.isHidden = !isError
        view.layoutSubtreeIfNeeded()
        updateWindowHeight()
        if !isError && !message.isEmpty {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
                guard let self, self.feedbackRevision == revision else { return }
                self.feedbackLabel.stringValue = ""
                self.view.layoutSubtreeIfNeeded()
                self.updateWindowHeight()
            }
        }
    }

    @objc private func showActivity() { tabs.selectTabViewItem(withIdentifier: "log") }

    @objc private func copyLogs() {
        flushLogBuffer()
        guard !logView.string.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(logView.string, forType: .string)
        showFeedback("Runtime logs copied.")
    }

    // Bound pending output separately from the displayed text. Only new output is
    // appended during normal updates, avoiding a full text layout every 150 ms.
    private func appendLog(_ text: String) {
        guard !text.isEmpty else { return }
        activityEmptyLabel.isHidden = true
        copyLogsButton.isEnabled = true
        logBuffer.append(text)
        trimLog(logBuffer)
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.flushLogBuffer()
        }
    }

    private func trimLog(_ text: NSMutableString) {
        guard text.length > maxLogCharacters else { return }
        let marker = "[...older log truncated...]\n"
        let overflow = text.length - maxLogCharacters + (marker as NSString).length
        let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: 0, length: overflow))
        text.replaceCharacters(in: range, with: marker)
    }

    private func flushLogBuffer() {
        logFlushScheduled = false
        guard logBuffer.length > 0, let storage = logView.textStorage else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.textColor,
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular),
        ]
        storage.beginEditing()
        storage.append(NSAttributedString(string: logBuffer as String, attributes: attributes))
        trimLog(storage.mutableString)
        storage.endEditing()
        logBuffer.setString("")
        if followLogsCheckbox.state == .on {
            logView.scrollToEndOfDocument(nil)
        }
    }

    @objc private func followLogsChanged() {
        if followLogsCheckbox.state == .on { logView.scrollToEndOfDocument(nil) }
    }

    @objc private func clearLogs() {
        logBuffer.setString("")
        logView.string = ""
        activityEmptyLabel.isHidden = false
        copyLogsButton.isEnabled = false
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Check your settings"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var controller: MainViewController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let controller = MainViewController()
        self.controller = controller

        _ = controller.view
        let initialHeight = controller.preferredContentHeight
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: initialHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.contentViewController = controller
        window.setContentSize(NSSize(width: Layout.windowWidth, height: initialHeight))
        window.isReleasedWhenClosed = false
        window.center()
        self.window = window

        configureMainMenu()
        showMainWindow()
    }

    @objc private func showMainWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettingsWindow() {
        showMainWindow()
        controller?.showSettingsTab()
    }

    private func configureMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem(title: appName, action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: appName)
        let aboutItem = NSMenuItem(
            title: "About FileMCP",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        aboutItem.target = NSApp
        appMenu.addItem(aboutItem)

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        servicesItem.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        appMenu.addItem(servicesItem)
        appMenu.addItem(.separator())

        let hideItem = NSMenuItem(title: "Hide FileMCP", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        hideItem.target = NSApp
        appMenu.addItem(hideItem)

        let hideOthersItem = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthersItem.target = NSApp
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)

        let showAllItem = NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        showAllItem.target = NSApp
        appMenu.addItem(showAllItem)
        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit FileMCP", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        let editMenuItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(.separator())
        let frontItem = NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        frontItem.target = NSApp
        windowMenu.addItem(frontItem)
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showMainWindow()
        }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdownForTermination()
    }
}
