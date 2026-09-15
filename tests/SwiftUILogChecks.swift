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
    controller.appendLog("after clear")
    controller.flushLogBuffer()
    precondition(controller.logView.string == "after clear")
    print("PASS: incremental append, selection preservation, Unicode truncation, bounded storage, clear pending output")
}

}
func runLogRegressionChecks() { MainViewController.checkLogs() }
