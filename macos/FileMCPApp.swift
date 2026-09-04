import AppKit
import Security

private let appName = "FileMCP"

private enum Layout {
    static let windowWidth: CGFloat = 440
    static let collapsedWindowHeight: CGFloat = 350
    static let expandedWindowHeight: CGFloat = 450
    static let footerHeight: CGFloat = 52
    static let contentWidth: CGFloat = 392
    static let labelWidth: CGFloat = 108
    static let fieldWidth: CGFloat = 276
    static let directoryFieldWidth: CGFloat = 224
    static let directoryButtonWidth: CGFloat = 44
    static let actionButtonHeight: CGFloat = 34
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
    static let enableCommands = "enableCommands"
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
    private let keychainAccount = "runtime-api-key"

    var hasSavedAPIKey: Bool {
        if let value = try? readKeychainAPIKey(), !value.isEmpty { return true }
        return legacyAPIKey != nil
    }

    func readAPIKey() throws -> String {
        if let value = try readKeychainAPIKey(), !value.isEmpty { return value }
        if let legacy = legacyAPIKey {
            try saveAPIKey(legacy)
            return legacy
        }
        throw NSError(domain: appName, code: 1, userInfo: [NSLocalizedDescriptionKey: "No API key is saved."])
    }

    func saveAPIKey(_ value: String) throws {
        guard !value.isEmpty else { return }
        guard let data = value.data(using: .utf8) else {
            throw NSError(domain: appName, code: 2, userInfo: [NSLocalizedDescriptionKey: "The API key is not valid UTF-8."])
        }
        let query = keychainQuery()
        let attributes: [CFString: Any] = [kSecValueData: data, kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var item = query
            item[kSecValueData] = data
            item[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw keychainError(operation: "save the API key", status: addStatus) }
        } else if updateStatus != errSecSuccess {
            throw keychainError(operation: "update the API key", status: updateStatus)
        }
        UserDefaults.standard.removeObject(forKey: ConfigKey.apiKey)
    }

    func deleteAPIKey() throws {
        let status = SecItemDelete(keychainQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(operation: "delete the API key", status: status) }
        UserDefaults.standard.removeObject(forKey: ConfigKey.apiKey)
    }

    private var legacyAPIKey: String? {
        guard let value = UserDefaults.standard.string(forKey: ConfigKey.apiKey), !value.isEmpty else { return nil }
        return value
    }

    private func readKeychainAPIKey() throws -> String? {
        var query = keychainQuery()
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(operation: "read the API key", status: status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw NSError(domain: appName, code: 3, userInfo: [NSLocalizedDescriptionKey: "The API key stored in Keychain is not valid UTF-8."])
        }
        return value
    }

    private func keychainQuery() -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: keychainService, kSecAttrAccount: keychainAccount]
    }

    private func keychainError(operation: String, status: OSStatus) -> NSError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: appName, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) in macOS Keychain: \(detail)"])
    }
}

private final class MainViewController: NSViewController, NSTabViewDelegate {
    private let storage = RuntimeStorage()
    private let runtime = LocalMCPRuntime()
    private var logBuffer = ""
    private var logFlushScheduled = false
    private let maxLogCharacters = 500_000

    private let tunnelIDField = NSTextField()
    private let apiKeyField = NSSecureTextField()
    private let profileField = NSTextField()
    private let portField = NSTextField()
    private let directoryField = NSTextField()
    private let healthAddressField = NSTextField()
    private let gitUserNameField = NSTextField()
    private let gitUserEmailField = NSTextField()
    private let enableCommandsCheckbox = NSButton(checkboxWithTitle: "Allow shell commands", target: nil, action: nil)
    private let logView = NSTextView()
    private let saveConnectionButton = LoadingButton(title: "Save connection", target: nil, action: nil)
    private let saveSettingsButton = LoadingButton(title: "Save settings", target: nil, action: nil)
    private let startButton = NSButton(title: "Connect", target: nil, action: nil)
    private let deleteKeyButton = NSButton(title: "Delete API key", target: nil, action: nil)
    private let quitButton = NSButton(title: "Quit FileMCP", target: nil, action: nil)
    private let advancedToggleButton = NSButton(title: "Advanced options", target: nil, action: nil)
    private let advancedSettingsGroup = NSStackView()
    private let apiKeyStatusLabel = NSTextField(labelWithString: "")
    private let tabs = NSTabView()

    override func loadView() { view = NSView() }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        loadConfiguration()
        configureRuntime()
    }

    deinit { shutdownForTermination() }

    private func buildUI() {
        configure(tunnelIDField, placeholder: "tunnel_...")
        configure(apiKeyField, placeholder: "sk-...")
        configure(profileField, placeholder: "filemcp")
        profileField.toolTip = "Starts with a letter or number; use only letters, numbers, '.', '_' or '-' (maximum 128 characters)."
        configure(portField, placeholder: "8008")
        configure(directoryField, placeholder: "Choose a shared directory")
        configure(healthAddressField, placeholder: "127.0.0.1:0")
        healthAddressField.toolTip = "Loopback-only tunnel-client health/admin listener. Use port 0 for an ephemeral port."
        configure(gitUserNameField, placeholder: "Git name for commits (optional)")
        configure(gitUserEmailField, placeholder: "Git email for commits (optional)")

        let chooseImage = NSImage(systemSymbolName: "folder", accessibilityDescription: "Choose directory")!
        let chooseButton = NSButton(image: chooseImage, target: self, action: #selector(chooseDirectory))
        chooseButton.bezelStyle = .rounded
        chooseButton.imagePosition = .imageOnly
        chooseButton.toolTip = "Choose directory"

        logView.isEditable = false
        logView.isSelectable = true
        logView.isVerticallyResizable = true
        logView.isHorizontallyResizable = true
        logView.autoresizingMask = [.width, .height]
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        logView.textColor = NSColor.white
        logView.insertionPointColor = NSColor.white
        logView.string = ""
        let logScroll = NSScrollView()
        logScroll.hasVerticalScroller = true
        logScroll.hasHorizontalScroller = true
        logScroll.autohidesScrollers = true
        logScroll.borderType = .bezelBorder
        logView.frame = logScroll.contentView.bounds
        logView.minSize = NSSize(width: 0, height: logScroll.contentSize.height)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        logView.textContainer?.widthTracksTextView = false
        logScroll.documentView = logView

        startButton.target = self
        startButton.action = #selector(startTunnel)
        startButton.keyEquivalent = "\r"
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

        quitButton.target = self
        quitButton.action = #selector(quitApp)
        quitButton.bezelStyle = .rounded
        quitButton.controlSize = .small
        quitButton.contentTintColor = .systemRed

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
            let labelView = NSTextField(labelWithString: label)
            labelView.font = .systemFont(ofSize: 11, weight: .medium)
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
            let labelView = NSTextField(labelWithString: label)
            labelView.font = .systemFont(ofSize: 11, weight: .medium)
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

        let connectionForm = NSStackView(views: [
            connectionField("Tunnel ID", tunnelIDField),
            connectionField("Runtime API key", apiKeyField),
        ])
        connectionForm.orientation = .vertical
        connectionForm.alignment = .leading
        connectionForm.spacing = 12

        let primaryActions = NSStackView(views: [saveConnectionButton, startButton])
        primaryActions.orientation = .horizontal
        primaryActions.alignment = .centerY
        primaryActions.distribution = .fillEqually
        primaryActions.spacing = 8
        primaryActions.translatesAutoresizingMaskIntoConstraints = false

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false

        let keyManagementRow = NSStackView(views: [apiKeyStatusLabel, deleteKeyButton])
        keyManagementRow.orientation = .horizontal
        keyManagementRow.alignment = .centerY
        keyManagementRow.spacing = 10
        keyManagementRow.translatesAutoresizingMaskIntoConstraints = false

        let connectionSpacer = NSView()
        connectionSpacer.translatesAutoresizingMaskIntoConstraints = false
        connectionSpacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        connectionSpacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        let connectionRoot = NSStackView(views: [
            connectionForm,
            primaryActions,
            divider,
            keyManagementRow,
            connectionSpacer,
        ])
        connectionRoot.orientation = .vertical
        connectionRoot.alignment = .leading
        connectionRoot.spacing = 12
        connectionRoot.setCustomSpacing(16, after: connectionForm)
        connectionRoot.setCustomSpacing(14, after: primaryActions)
        connectionRoot.setCustomSpacing(10, after: divider)
        connectionRoot.translatesAutoresizingMaskIntoConstraints = false

        let connectionPage = NSView()
        connectionPage.addSubview(connectionRoot)
        NSLayoutConstraint.activate([
            connectionRoot.leadingAnchor.constraint(equalTo: connectionPage.leadingAnchor, constant: 12),
            connectionRoot.trailingAnchor.constraint(equalTo: connectionPage.trailingAnchor, constant: -12),
            connectionRoot.topAnchor.constraint(equalTo: connectionPage.topAnchor, constant: 12),
            connectionRoot.bottomAnchor.constraint(equalTo: connectionPage.bottomAnchor, constant: -12),
            primaryActions.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            divider.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            keyManagementRow.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            saveConnectionButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),
            startButton.heightAnchor.constraint(equalToConstant: Layout.actionButtonHeight),
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
        [profileRow, portRow, healthRow, gitNameRow, gitEmailRow].forEach {
            advancedSettingsGroup.addArrangedSubview($0)
        }
        advancedSettingsGroup.isHidden = true
        advancedSettingsGroup.translatesAutoresizingMaskIntoConstraints = false

        let settingsForm = NSStackView(views: [
            directoryRow,
            enableCommandsCheckbox,
            commandWarning,
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

        let settingsPage = NSView()
        settingsPage.addSubview(settingsRoot)
        NSLayoutConstraint.activate([
            settingsRoot.leadingAnchor.constraint(equalTo: settingsPage.leadingAnchor, constant: 12),
            settingsRoot.trailingAnchor.constraint(equalTo: settingsPage.trailingAnchor, constant: -12),
            settingsRoot.topAnchor.constraint(equalTo: settingsPage.topAnchor, constant: 12),
            settingsRoot.bottomAnchor.constraint(lessThanOrEqualTo: settingsPage.bottomAnchor, constant: -10),
        ])

        logScroll.translatesAutoresizingMaskIntoConstraints = false
        logScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        logScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let logPage = NSView()
        logPage.addSubview(logScroll)
        NSLayoutConstraint.activate([
            logScroll.leadingAnchor.constraint(equalTo: logPage.leadingAnchor, constant: 12),
            logScroll.trailingAnchor.constraint(equalTo: logPage.trailingAnchor, constant: -12),
            logScroll.topAnchor.constraint(equalTo: logPage.topAnchor, constant: 12),
            logScroll.bottomAnchor.constraint(equalTo: logPage.bottomAnchor, constant: -12),
        ])

        tabs.tabViewType = .topTabsBezelBorder
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.delegate = self

        let configTab = NSTabViewItem(identifier: "config")
        configTab.label = "Connection"
        configTab.view = connectionPage

        let settingsTab = NSTabViewItem(identifier: "settings")
        settingsTab.label = "Settings"
        settingsTab.view = settingsPage

        let logTab = NSTabViewItem(identifier: "log")
        logTab.label = "Logs"
        logTab.view = logPage

        tabs.addTabViewItem(configTab)
        tabs.addTabViewItem(settingsTab)
        tabs.addTabViewItem(logTab)

        let footerDivider = NSBox()
        footerDivider.boxType = .separator
        footerDivider.translatesAutoresizingMaskIntoConstraints = false

        let quitHint = NSTextField(labelWithString: "Quit the app and stop the tunnel if it is running.")
        quitHint.font = .systemFont(ofSize: 10.5)
        quitHint.textColor = .secondaryLabelColor
        quitHint.setContentHuggingPriority(.defaultLow, for: .horizontal)
        quitHint.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let quitRow = NSStackView(views: [quitHint, quitButton])
        quitRow.orientation = .horizontal
        quitRow.alignment = .centerY
        quitRow.spacing = 10
        quitRow.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(footerDivider)
        footer.addSubview(quitRow)

        view.addSubview(tabs)
        view.addSubview(footer)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 10),
            tabs.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -10),
            tabs.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            tabs.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: Layout.footerHeight),
            footerDivider.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            footerDivider.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            footerDivider.topAnchor.constraint(equalTo: footer.topAnchor),
            quitRow.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 24),
            quitRow.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -24),
            quitRow.topAnchor.constraint(equalTo: footerDivider.bottomAnchor, constant: 9),
            saveSettingsButton.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            connectionRoot.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            settingsForm.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            tunnelIDField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
            apiKeyField.widthAnchor.constraint(equalToConstant: Layout.contentWidth),
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
        (field as? NSSecureTextField)?.usesSingleLineMode = true
    }

    private func loadConfiguration() {
        let defaults = UserDefaults.standard
        tunnelIDField.stringValue = defaults.string(forKey: ConfigKey.tunnelID) ?? ""
        apiKeyField.stringValue = ""
        updateAPIKeyPlaceholder()
        profileField.stringValue = defaults.string(forKey: ConfigKey.profile) ?? "filemcp"
        portField.stringValue = defaults.string(forKey: ConfigKey.port) ?? "8008"
        directoryField.stringValue = defaults.string(forKey: ConfigKey.allowedDirectory) ?? defaultDirectory()
        healthAddressField.stringValue = defaults.string(forKey: ConfigKey.healthAddress) ?? "127.0.0.1:0"
        gitUserNameField.stringValue = defaults.string(forKey: ConfigKey.gitUserName) ?? ""
        gitUserEmailField.stringValue = defaults.string(forKey: ConfigKey.gitUserEmail) ?? ""
        enableCommandsCheckbox.state = defaults.bool(forKey: ConfigKey.enableCommands) ? .on : .off
    }

    private func updateAPIKeyPlaceholder() {
        let hasSavedKey = storage.hasSavedAPIKey
        apiKeyField.placeholderString = hasSavedKey ? "Saved — leave blank to keep it" : "sk-..."
        apiKeyStatusLabel.stringValue = hasSavedKey ? "API key is saved in Keychain" : "No API key is saved"
        deleteKeyButton.isEnabled = hasSavedKey
    }

    private func defaultDirectory() -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents/FileMCP", isDirectory: true).path
    }

    private func saveConnectionConfiguration() {
        UserDefaults.standard.set(tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: ConfigKey.tunnelID)
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
        if panel.runModal() == .OK, let url = panel.url { directoryField.stringValue = url.path }
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
        guard validateConnectionConfiguration(requireAPIKey: true), validateSettingsConfiguration() else { return }
        do {
            let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedKey.isEmpty {
                try storage.saveAPIKey(typedKey)
                apiKeyField.stringValue = ""
                updateAPIKeyPlaceholder()
            }
            let apiKey = try storage.readAPIKey()
            saveAllConfiguration()
            guard let port = UInt16(portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                showError("The MCP port is invalid.")
                return
            }
            appendLog("[Runtime] Connect requested.\n")
            runtime.start(LocalMCPConfiguration(
                tunnelID: tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                apiKey: apiKey,
                profile: profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                port: port,
                allowedDirectory: directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                healthAddress: healthAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                gitUserName: gitUserNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                gitUserEmail: gitUserEmailField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                enableCommands: enableCommandsCheckbox.state == .on
            ))
        } catch { showError(error.localizedDescription) }
    }

    @objc private func saveConnectionOnly() {
        guard validateConnectionConfiguration(requireAPIKey: true) else { return }
        saveConnectionButton.setLoading(true)
        do {
            let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !typedKey.isEmpty {
                try storage.saveAPIKey(typedKey)
                apiKeyField.stringValue = ""
                updateAPIKeyPlaceholder()
            }
            saveConnectionConfiguration()
            appendLog("[Runtime] Connection settings saved.\n")
            if runtime.state != .stopped { appendLog("[Runtime] Changes will take effect the next time the tunnel starts.\n") }
            finishLoading(saveConnectionButton)
        } catch {
            saveConnectionButton.setLoading(false)
            showError(error.localizedDescription)
        }
    }

    @objc private func saveSettingsOnly() {
        guard validateSettingsConfiguration() else { return }
        saveSettingsButton.setLoading(true)
        saveSettingsConfiguration()
        appendLog("[Runtime] Settings saved.\n")
        if runtime.state != .stopped { appendLog("[Runtime] Changes will take effect the next time the tunnel starts.\n") }
        finishLoading(saveSettingsButton)
    }

    private func finishLoading(_ button: LoadingButton) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak button] in button?.setLoading(false) }
    }

    private func validateConnectionConfiguration(requireAPIKey: Bool) -> Bool {
        let tunnelID = tunnelIDField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let typedKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelID.isEmpty else { showError("Enter a Tunnel ID in the Connection tab."); return false }
        guard LocalMCPRuntime.isValidTunnelID(tunnelID) else { showError("Tunnel ID must match tunnel_<32 lowercase letters or digits>."); return false }
        if requireAPIKey && typedKey.isEmpty && !storage.hasSavedAPIKey { showError("Enter a Runtime API key in the Connection tab."); return false }
        return true
    }

    private func validateSettingsConfiguration() -> Bool {
        let profile = profileField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = directoryField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { tabs.selectTabViewItem(withIdentifier: "settings"); showError("Choose a shared directory."); return false }
        guard !profile.isEmpty else { tabs.selectTabViewItem(withIdentifier: "settings"); setAdvancedSettingsExpanded(true); showError("Profile cannot be empty."); return false }
        guard LocalMCPRuntime.isValidProfileName(profile) else { tabs.selectTabViewItem(withIdentifier: "settings"); setAdvancedSettingsExpanded(true); showError("Profile must start with a letter or number and contain only letters, numbers, '.', '_' or '-' (maximum 128 characters)."); return false }
        guard let portNumber = UInt16(port), portNumber > 0 else { tabs.selectTabViewItem(withIdentifier: "settings"); setAdvancedSettingsExpanded(true); showError("MCP port must be between 1 and 65535."); return false }
        let healthAddress = healthAddressField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalMCPRuntime.normalizedHealthAddress(healthAddress) != nil else { tabs.selectTabViewItem(withIdentifier: "settings"); setAdvancedSettingsExpanded(true); showError("Health listener must use localhost, 127.0.0.1, or [::1] with a port from 0 to 65535."); return false }
        return true
    }

    func showSettingsTab() { tabs.selectTabViewItem(withIdentifier: "settings") }
    func shutdownForTermination() { runtime.shutdownImmediately() }

    @objc private func deleteSavedKey() {
        do {
            try storage.deleteAPIKey()
            apiKeyField.stringValue = ""
            updateAPIKeyPlaceholder()
        } catch { showError(error.localizedDescription) }
    }

    @objc private func quitApp() { NSApp.terminate(nil) }
    @objc private func toggleAdvancedSettings() { setAdvancedSettingsExpanded(advancedSettingsGroup.isHidden) }

    private func setAdvancedSettingsExpanded(_ expanded: Bool) {
        advancedSettingsGroup.isHidden = !expanded
        advancedToggleButton.image = advancedChevron(expanded: expanded)
        let settingsSelected = tabs.selectedTabViewItem?.identifier as? String == "settings"
        resizeWindowForAdvancedSettings(expanded: expanded && settingsSelected)
    }

    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        let settingsSelected = tabViewItem?.identifier as? String == "settings"
        resizeWindowForAdvancedSettings(expanded: settingsSelected && !advancedSettingsGroup.isHidden)
        if tabViewItem?.identifier as? String == "log" { flushLogBuffer() }
    }

    private func resizeWindowForAdvancedSettings(expanded: Bool) {
        guard let window = view.window else { return }
        let targetContentHeight = expanded ? Layout.expandedWindowHeight : Layout.collapsedWindowHeight
        var contentRect = window.contentRect(forFrameRect: window.frame)
        guard abs(contentRect.height - targetContentHeight) > 0.5 else { return }
        let topEdge = window.frame.maxY
        contentRect.size.height = targetContentHeight
        var targetFrame = window.frameRect(forContentRect: contentRect)
        targetFrame.origin.x = window.frame.origin.x
        targetFrame.origin.y = topEdge - targetFrame.height
        window.setFrame(targetFrame, display: true, animate: true)
    }

    private func advancedChevron(expanded: Bool) -> NSImage? {
        NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right", accessibilityDescription: expanded ? "Collapse advanced options" : "Expand advanced options")
    }

    private func configureRuntime() {
        runtime.onLog = { [weak self] text in
            DispatchQueue.main.async { self?.appendLog(text) }
        }
        runtime.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updateRunButton(state: state)
                if case let .failed(message) = state { self?.showError(message) }
            }
        }
    }

    private func updateRunButton(state: LocalMCPRuntimeState) {
        switch state {
        case .stopped, .failed:
            startButton.title = "Connect"; startButton.bezelColor = .controlAccentColor; startButton.isEnabled = true
        case .starting:
            startButton.title = "Connecting…"; startButton.bezelColor = .controlAccentColor; startButton.isEnabled = false
        case .running:
            startButton.title = "Disconnect"; startButton.bezelColor = .systemRed; startButton.isEnabled = true
        case .stopping:
            startButton.title = "Disconnecting…"; startButton.bezelColor = .systemRed; startButton.isEnabled = false
        }
        startButton.contentTintColor = .white
    }

    private func appendLog(_ text: String) {
        logBuffer += text
        if logBuffer.count > maxLogCharacters {
            let overflow = logBuffer.count - maxLogCharacters
            let cut = logBuffer.index(logBuffer.startIndex, offsetBy: overflow)
            logBuffer = "[...older log truncated...]\n" + String(logBuffer[cut...])
        }
        guard !logFlushScheduled else { return }
        logFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.flushLogBuffer() }
    }

    private func flushLogBuffer() {
        logFlushScheduled = false
        logView.string = logBuffer
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.textColor = .white
        logView.scrollToEndOfDocument(nil)
        logView.needsDisplay = true
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = appName
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
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: Layout.collapsedWindowHeight),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = appName
        window.contentViewController = controller
        window.setContentSize(NSSize(width: Layout.windowWidth, height: Layout.collapsedWindowHeight))
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
        let aboutItem = NSMenuItem(title: "About FileMCP", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
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
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
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
        if !flag { showMainWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller?.shutdownForTermination()
    }
}
