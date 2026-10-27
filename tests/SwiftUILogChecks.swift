// Appended to FileMCPApp.swift by test_swift_ui.sh to exercise private UI log behavior.
extension MainViewController {
static func checkLogs() {
    let controller = MainViewController()
    controller.followLogsCheckbox.state = .off
    controller.appendLog("first\n")
    controller.flushLogBuffer()
    controller.logView.setSelectedRange(NSRange(location: 0, length: 5))
    controller.appendLog("second\n")
    controller.flushLogBuffer()
    precondition(controller.logView.string == "first\nsecond\n")
    precondition(controller.logView.selectedRange() == NSRange(location: 0, length: 5))
    controller.appendLog(String(repeating: "👨‍👩‍👧‍👦 tiếng Việt\n", count: 40_000))
    controller.flushLogBuffer()
    precondition(controller.logView.textStorage!.length <= 500_000)
    precondition(controller.logView.string.hasPrefix("[...older log truncated...]\n"))
    precondition(!controller.logView.string.contains("�"))
    controller.appendLog("pending")
    controller.clearLogs()
    controller.flushLogBuffer()
    precondition(controller.logView.string.isEmpty)
    precondition(!controller.activityEmptyLabel.isHidden && !controller.copyLogsButton.isEnabled)
    controller.appendLog("after clear")
    controller.flushLogBuffer()
    precondition(controller.logView.string == "after clear")
    precondition(controller.activityEmptyLabel.isHidden && controller.copyLogsButton.isEnabled)
    print("PASS: incremental append, selection preservation, Unicode truncation, bounded storage, clear pending output")
}

}
func runLogRegressionChecks() {
    MainViewController.checkLogs()
    MainViewController.checkInterface()
    MainViewController.checkCompactLayoutMatrix()
}

extension MainViewController {
    static func checkInterface() {
        let controller = MainViewController()
        controller.loadsSavedConfiguration = false
        _ = controller.view
        controller.cachedPathSecret = String(repeating: "a", count: 64)
        controller.cachedPairingSecret = String(repeating: "d", count: 64)
        controller.directoryField.stringValue = "/Users/demo/Projects/My workspace"
        controller.tunnelIDField.stringValue = "tunnel_0123456789abcdef0123456789abcdef"
        controller.profileField.stringValue = "filemcp"
        controller.portField.stringValue = "8008"
        controller.healthAddressField.stringValue = "127.0.0.1:0"
        controller.cloudflareHostnameField.stringValue = "mcp.example.com"
        controller.cloudflareTunnelNameField.stringValue = "my-workspace"
        precondition(controller.enableGitPushCheckbox.state == .off && controller.enableCodexHistoryCheckbox.state == .off)
        controller.updateWorkspaceSummary()
        precondition(controller.tabs.selectedTabViewItem?.identifier as? String == "overview")
        controller.navigation.selectedSegment = 2
        controller.navigate()
        precondition(controller.tabs.selectedTabViewItem?.identifier as? String == "config")
        controller.applyAppearance(false)
        precondition(controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        controller.toggleAppearance()
        precondition(controller.usesDarkAppearance && controller.themeButton.title == "Light")
        precondition(controller.view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        controller.toggleAppearance()
        precondition(!controller.usesDarkAppearance && controller.themeButton.title == "Dark")
        precondition(controller.overviewPermissionsLabel.stringValue.contains("Shell off"))
        controller.enableCommandsCheckbox.state = .on
        controller.workspaceOptionsChanged()
        precondition(controller.overviewPermissionsLabel.stringValue.contains("Shell on"))
        controller.enableCommandsCheckbox.state = .off
        controller.workspaceOptionsChanged()
        controller.providerPopup.selectItem(at: 0)
        controller.applyProviderSelection()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: 700),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: Layout.windowWidth, height: controller.preferredContentHeight))
        controller.view.layoutSubtreeIfNeeded()
        controller.updateWindowHeight()
        controller.view.layoutSubtreeIfNeeded()
        if let scroll = controller.connectionScrollView, let content = controller.connectionContent {
            let needed = ceil(content.fittingSize.height) + 24
            if controller.preferredContentHeight < ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000) - 80 {
                precondition(scroll.contentView.bounds.height + 1 >= needed,
                             "Connection should fit the credential management row without scrolling")
                let button = controller.deleteKeyButton.convert(controller.deleteKeyButton.bounds, to: scroll.contentView)
                precondition(scroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(button),
                             "Delete API key must be fully visible in the initial OpenAI layout")
            }
        }
        controller.showFeedback("A connection error that wraps across multiple lines. " + String(repeating: "Check the connection settings. ", count: 6), isError: true)
        controller.view.layoutSubtreeIfNeeded()
        if let scroll = controller.connectionScrollView,
           controller.preferredContentHeight < ((window.screen ?? NSScreen.main)?.visibleFrame.height ?? 1000) - 80 {
            let button = controller.deleteKeyButton.convert(controller.deleteKeyButton.bounds, to: scroll.contentView)
            precondition(scroll.contentView.bounds.insetBy(dx: -1, dy: -1).contains(button),
                         "Wrapping feedback must not hide credential controls")
        }
        controller.showFeedback("")
        controller.updateRunButton(state: .running)
        precondition(!controller.providerPopup.isEnabled && !controller.directoryField.isEnabled)
        precondition(!controller.chooseDirectoryButton.isEnabled && !controller.enableCommandsCheckbox.isEnabled)
        precondition(!controller.saveSettingsButton.isEnabled && !controller.cloudflareLoginButton.isEnabled)
        precondition(!controller.resetButton.isEnabled && controller.startButton.isEnabled)
        precondition(!controller.enableGitPushCheckbox.isEnabled && !controller.enableCodexHistoryCheckbox.isEnabled)
        for tab in ["overview", "settings", "log", "config"] {
            controller.tabs.selectTabViewItem(withIdentifier: tab)
            precondition(controller.navigation.selectedSegment == controller.tabs.indexOfTabViewItem(controller.tabs.selectedTabViewItem!), "Navigation follows programmatic tab selection")
            precondition(!controller.overviewChangeButton.isEnabled && controller.themeButton.isEnabled)
            precondition(!controller.startButton.isHiddenOrHasHiddenAncestor, "Connection action must be available on every tab")
        }
        controller.updateRunButton(state: .starting)
        precondition(controller.startButton.isEnabled && controller.startButton.title == "Cancel connection")
        controller.updateRunButton(state: .stopping)
        precondition(!controller.startButton.isEnabled)
        controller.updateRunButton(state: .stopped)
        precondition(controller.providerPopup.isEnabled && controller.directoryField.isEnabled)
        controller.cloudflareBusy = true
        controller.updateCloudflareActionStates()
        precondition(!controller.startButton.isEnabled && !controller.providerPopup.isEnabled && !controller.resetButton.isEnabled)
        controller.cloudflareBusy = false
        controller.updateCloudflareActionStates()
        controller.providerPopup.selectItem(at: 2)
        controller.applyProviderSelection()
        precondition(controller.allowCloudflareURLSecretCheckbox.state == .off)
        precondition(controller.fullMCPURL() == "https://mcp.example.com/mcp")
        let originalURL = controller.fullMCPURL()
        controller.updateRunButton(state: .running)
        precondition(!controller.cloudflareHostnameField.isEnabled && !controller.regenerateURLButton.isEnabled)
        precondition(controller.copyURLButton.isEnabled && controller.fullMCPURL() == originalURL)
        precondition(controller.connectionFormView?.isHidden == true && controller.connectionSaveView?.isHidden == true,
                     "An active connection should show a summary rather than disabled configuration fields")
        precondition(!controller.shareConnectionSection.isHidden && !controller.copyTokenButton.isHiddenOrHasHiddenAncestor,
                     "Endpoint and login-code actions remain visible while connected")
        controller.view.layoutSubtreeIfNeeded()
        precondition(controller.mcpURLField.bounds.width >= Layout.contentWidth - 30,
                     "The endpoint gets its own full-width row")

        precondition(!controller.mcpURLField.isSelectable, "A masked URL must not be copied as a broken connector URL")
        controller.updateRunButton(state: .failed("Sample connection error"))
        precondition(controller.connectionFormView?.isHidden == false, "Failed connections restore the editable form")
        controller.showFeedback("Sample connection error", isError: true)
        precondition(controller.providerPopup.isEnabled && !controller.viewLogsButton.isHidden)
        controller.showActivity()
        precondition(controller.tabs.selectedTabViewItem?.identifier as? String == "log")
        controller.showFeedback("")
        controller.tabs.selectTabViewItem(withIdentifier: "settings")
        if let screen = window.screen ?? NSScreen.main {
            let visible = screen.visibleFrame
            var frame = window.frame
            frame.origin.y = visible.minY
            window.setFrame(frame, display: false)
            controller.setAdvancedSettingsExpanded(true)
            precondition(window.frame.minY >= visible.minY - 1 && window.frame.maxY <= visible.maxY + 1,
                         "Expanding settings must keep the connection controls on screen")
        }

        print("PASS: connection controls across tabs, cancellation, configuration locking, account-operation isolation, URL stability and error recovery")
    }
}

extension MainViewController {
    static func previewInterface() -> NSWindow {
        let controller = MainViewController()
        controller.loadsSavedConfiguration = false
        _ = controller.view
        controller.cachedPathSecret = String(repeating: "a", count: 64)
        controller.cachedPairingSecret = String(repeating: "d", count: 64)
        controller.directoryField.stringValue = "/Users/demo/Projects/My workspace"
        controller.profileField.stringValue = "filemcp"
        controller.portField.stringValue = "8008"
        controller.healthAddressField.stringValue = "127.0.0.1:0"
        controller.cloudflareHostnameField.stringValue = "mcp.example.com"
        controller.cloudflareTunnelNameField.stringValue = "my-workspace"
        controller.cloudflareLoggedIn = true
        controller.knownCloudflareTunnelNames = ["my-workspace"]
        controller.cloudflareCLIStatusLabel.stringValue = "Logged in · 1 tunnel available on this Mac"
        controller.providerPopup.selectItem(at: 1)
        controller.applyProviderSelection()
        controller.updateWorkspaceSummary()
        controller.updateRunButton(state: .stopped)
        // Preview is isolated from credentials, Cloudflare and persistent settings.
        for button in [controller.startButton, controller.saveConnectionButton, controller.saveSettingsButton,
                       controller.resetButton, controller.deleteKeyButton, controller.deleteCloudflareTokenButton,
                       controller.cloudflareLoginButton, controller.cloudflareRefreshButton, controller.cloudflareCreateButton,
                       controller.cloudflareDeleteButton, controller.regenerateURLButton, controller.copyURLButton, controller.copyTokenButton,
                       controller.chooseDirectoryButton] {
            button.target = nil
            button.action = nil
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: controller.preferredContentHeight),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentViewController = controller
        window.setContentSize(NSSize(width: Layout.windowWidth, height: controller.preferredContentHeight))
        window.title = "FileMCP · UI Preview"
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

extension MainViewController {
    static func checkCompactLayoutMatrix() {
        let window = previewInterface()
        let controller = window.contentViewController as! MainViewController
        controller.directoryField.stringValue = "/Users/demo/" + String(repeating: "Thư mục có tên dài/", count: 15) + "workspace"
        controller.updateWorkspaceSummary()
        controller.tunnelIDField.stringValue = "tunnel_0123456789abcdef0123456789abcdef"
        let states: [LocalMCPRuntimeState] = [.stopped, .starting, .running, .stopping, .failed("A failed connection")]
        var cases = 0
        for dark in [false, true] {
            controller.applyAppearance(dark)
            for provider in 0...2 {
                controller.providerPopup.selectItem(at: provider)
                controller.applyProviderSelection()
                for state in states {
                    controller.updateRunButton(state: state)
                    for tab in ["overview", "settings", "config", "log"] {
                        controller.tabs.selectTabViewItem(withIdentifier: tab)
                        window.setContentSize(NSSize(width: Layout.windowWidth, height: controller.preferredContentHeight))
                        controller.view.layoutSubtreeIfNeeded()
                        let bounds = controller.view.bounds.insetBy(dx: -1, dy: -1)
                        for control in [controller.startButton, controller.themeButton, controller.navigation] {
                            let rect = control.convert(control.bounds, to: controller.view)
                            precondition(bounds.contains(rect), "Persistent control clipped: \(tab), provider \(provider), dark \(dark)")
                        }
                        let title = controller.startButton.attributedTitle
                        precondition(title.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .white,
                                     "Connection action must retain white text in every state and theme")
                        precondition(title.size().width <= controller.startButton.bounds.width - 16,
                                     "Connection action title must fit without clipping")
                        if let scroll = controller.tabs.selectedTabViewItem?.view as? NSScrollView,
                           let document = scroll.documentView {
                            precondition(document.bounds.width <= scroll.contentView.bounds.width + 1,
                                         "Horizontal overflow: \(tab), provider \(provider)")
                            if tab == "overview", let row = controller.overviewChangeButton.superview {
                                let action = controller.overviewChangeButton.convert(controller.overviewChangeButton.bounds, to: row)
                                precondition(abs(action.maxX - row.bounds.maxX) <= 2,
                                             "Workspace action must align with the trailing edge")
                            }
                            if tab == "overview", controller.preferredContentHeight == 600 {
                                precondition(document.fittingSize.height <= scroll.contentView.bounds.height + 1,
                                             "Compact overview must fit without scrolling on a normal screen")
                            }
                        }
                        cases += 1
                    }
                }
            }
        }
        controller.directoryField.stringValue = ""
        controller.updateWorkspaceSummary()
        precondition(controller.workspaceSummaryLabel.stringValue == "Choose a workspace")
        controller.portField.stringValue = "9009"
        controller.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: controller.portField))
        precondition(controller.overviewLocalLabel.stringValue.contains("9009"))
        window.orderOut(nil)
        print("PASS: \(cases) layout cases (2 appearances × 3 providers × 5 states × 4 tabs), long/empty paths, port summary and white action titles")
    }
}
