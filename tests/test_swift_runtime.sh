#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."

TMP_DIR="$(mktemp -d)"
SERVER_PID=""
stop_server() {
    [ -n "$SERVER_PID" ] || return 0
    if kill -0 "$SERVER_PID" 2>/dev/null; then
        kill "$SERVER_PID" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$SERVER_PID" 2>/dev/null || break
            sleep 0.05
        done
        if kill -0 "$SERVER_PID" 2>/dev/null; then
            kill -9 "$SERVER_PID" 2>/dev/null || true
        fi
    fi
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
}
cleanup() {
    stop_server
    if [ -n "${TMPDIR:-}" ]; then
        TEST_ROOT="${TMPDIR%/}/filemcp-server-test"
        TEST_OUTSIDE="${TMPDIR%/}/filemcp-server-outside"
        chmod 700 "$TEST_ROOT/enumeration-error/locked" 2>/dev/null || true
        chmod 600 "$TEST_ROOT/unreadable-file/secret.txt" 2>/dev/null || true
        rm -rf "$TEST_ROOT" "$TEST_OUTSIDE" 2>/dev/null || true
    fi
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

MCP_HTTP_FUZZ_ITERATIONS="${MCP_HTTP_FUZZ_ITERATIONS:-160}"
case "$MCP_HTTP_FUZZ_ITERATIONS" in
    ''|*[!0-9]*)
        echo "MCP_HTTP_FUZZ_ITERATIONS must be a positive integer" >&2
        exit 2
        ;;
esac
if [ "$MCP_HTTP_FUZZ_ITERATIONS" -lt 1 ]; then
    echo "MCP_HTTP_FUZZ_ITERATIONS must be at least 1" >&2
    exit 2
fi

MCP_EXTENDED_SEARCH_TESTS="${MCP_EXTENDED_SEARCH_TESTS:-0}"
case "$MCP_EXTENDED_SEARCH_TESTS" in
    0|1) ;;
    *) echo "MCP_EXTENDED_SEARCH_TESTS must be 0 or 1" >&2; exit 2 ;;
esac

case "$(uname -m)" in
    arm64|aarch64) TUNNEL_TARGET="darwin-arm64" ;;
    x86_64|amd64) TUNNEL_TARGET="darwin-amd64" ;;
    *) echo "unsupported macOS architecture for tunnel-client test" >&2; exit 2 ;;
esac
TUNNEL_BIN="$PWD/vendor/tunnel-client/$TUNNEL_TARGET/tunnel-client"
[ -x "$TUNNEL_BIN" ] || { echo "missing vendored tunnel-client: $TUNNEL_BIN" >&2; exit 2; }
LOCAL_AUTH_PROFILE_DIR="$TMP_DIR/tunnel-profile"
LOCAL_AUTH_PROFILE_TOKEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
FILEMCP_LOCAL_AUTH_TOKEN="$LOCAL_AUTH_PROFILE_TOKEN" \
MCP_EXTRA_HEADERS="X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN" \
MCP_DISCOVERY_EXTRA_HEADERS="X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN" \
"$TUNNEL_BIN" init \
    --sample sample_mcp_remote_no_auth \
    --profile local-auth-profile \
    --profile-dir "$LOCAL_AUTH_PROFILE_DIR" \
    --force \
    --tunnel-id tunnel_0123456789abcdef0123456789abcdef \
    --mcp-server-url http://127.0.0.1:18088/mcp \
    --health-listen-addr 127.0.0.1:0 >/dev/null
LOCAL_AUTH_PROFILE="$LOCAL_AUTH_PROFILE_DIR/local-auth-profile.yaml"
[ -s "$LOCAL_AUTH_PROFILE" ]
[ "$(stat -f '%Lp' "$LOCAL_AUTH_PROFILE")" = "600" ]
if grep -Fq "$LOCAL_AUTH_PROFILE_TOKEN" "$LOCAL_AUTH_PROFILE" || \
   grep -Eiq 'extra_headers|X-FileMCP-Local-Token|FILEMCP_LOCAL_AUTH_TOKEN' "$LOCAL_AUTH_PROFILE"; then
    echo "tunnel-client init persisted the per-runtime local auth credential" >&2
    exit 1
fi
echo "tunnel-client-local-auth-env: ok"

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation
import Darwin

func waitForProcessExit(_ pid: pid_t, timeoutSeconds: TimeInterval = 2.0) -> Bool {
    guard pid > 0 else { return true }
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    repeat {
        if kill(pid, 0) != 0, errno == ESRCH { return true }
        usleep(50_000)
    } while Date() < deadline
    return kill(pid, 0) != 0 && errno == ESRCH
}

let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-test-child.pid").path
try? FileManager.default.removeItem(atPath: pidFile)
let command = "sh -c 'sleep 20 & echo $! > \(pidFile); wait'"
let timed = try ProcessRunner.run(
    executable: "/bin/sh",
    arguments: ["-lc", command],
    timeoutSeconds: 1
)
precondition(timed.timedOut, "command should time out")
let childText = try String(contentsOfFile: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let childPID = pid_t(Int(childText) ?? 0)
precondition(waitForProcessExit(childPID), "timed-out child process survived")
print("process-tree-timeout: ok")

let backgroundPIDFile = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-test-background-child.pid").path
try? FileManager.default.removeItem(atPath: backgroundPIDFile)
let background = try ProcessRunner.run(
    executable: "/bin/sh",
    arguments: ["-lc", "sleep 20 & echo $! > \(backgroundPIDFile)"],
    timeoutSeconds: 5
)
precondition(!background.timedOut && background.exitCode == 0, "background parent should exit normally")
let backgroundPIDText = try String(contentsOfFile: backgroundPIDFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let backgroundPID = pid_t(Int(backgroundPIDText) ?? 0)
precondition(waitForProcessExit(backgroundPID), "background child survived successful parent exit")
print("process-tree-normal-exit-cleanup: ok")

for index in 0..<12 {
    let exited = DispatchSemaphore(value: 0)
    let managed = try ProcessRunner.startManaged(
        executable: "/bin/sh",
        arguments: ["-lc", "printf managed-\(index); sleep 10"],
        onOutput: { _ in },
        onExit: { _ in exited.signal() }
    )
    managed.stopSynchronously()
    precondition(exited.wait(timeout: .now() + 3) == .success, "managed stop did not complete")
}
print("managed-reader-stop-race: ok")

let managedChildPIDFile = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-managed-background-child.pid").path
try? FileManager.default.removeItem(atPath: managedChildPIDFile)
let managedExited = DispatchSemaphore(value: 0)
let managedBackground = try ProcessRunner.startManaged(
    executable: "/bin/sh",
    arguments: ["-lc", "sleep 20 & echo $! > \(managedChildPIDFile)"],
    onOutput: { _ in },
    onExit: { _ in managedExited.signal() }
)
precondition(managedExited.wait(timeout: .now() + 3) == .success, "managed parent exit did not complete")
_ = managedBackground
let managedChildText = try String(contentsOfFile: managedChildPIDFile, encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
let managedChildPID = pid_t(Int(managedChildText) ?? 0)
precondition(waitForProcessExit(managedChildPID), "managed background child survived parent exit")
print("managed-process-descendant-cleanup: ok")

do {
    _ = try ProcessRunner.run(
        executable: "/bin/echo",
        arguments: ["safe\0truncated"],
        timeoutSeconds: 1
    )
    preconditionFailure("NUL-containing argv must be rejected")
} catch {
    precondition(error.localizedDescription.contains("NUL byte"), "unexpected NUL argv error: \(error)")
}

do {
    _ = try ProcessRunner.run(
        executable: "/bin/echo",
        arguments: [],
        environment: ["BAD=NAME": "value"],
        timeoutSeconds: 1
    )
    preconditionFailure("invalid environment variable name must be rejected")
} catch {
    precondition(error.localizedDescription.contains("Environment variable name"), "unexpected environment error: \(error)")
}
print("process-posix-string-validation: ok")
SWIFT

swiftc -o "$TMP_DIR/process-test" \
    macos/ProcessRunner.swift \
    "$TMP_DIR/main.swift"
"$TMP_DIR/process-test"

cat >"$TMP_DIR/tunnel-client" <<'SH'
#!/bin/sh
profile_dir=
previous=
for argument in "$@"; do
    if [ "$previous" = "--profile-dir" ]; then profile_dir="$argument"; fi
    previous="$argument"
done
if [ -n "${MCP_TEST_PROFILE_DIR_EXPECTED:-}" ] && [ "$profile_dir" != "$MCP_TEST_PROFILE_DIR_EXPECTED" ]; then
    echo "unexpected profile directory: $profile_dir" >&2
    exit 3
fi
if [ -n "${MCP_TEST_ENV_CAPTURE:-}" ]; then
    case "${NO_PROXY:-}" in
        *127.0.0.1*localhost*::1*|*127.0.0.1*::1*localhost*|*localhost*127.0.0.1*::1*|*localhost*::1*127.0.0.1*|*::1*127.0.0.1*localhost*|*::1*localhost*127.0.0.1*) ;;
        *) echo missing-loopback-no-proxy >&2; exit 3 ;;
    esac
    [ -z "${MCP_SERVER_URL:-}" ] || { echo inherited-mcp-server-url >&2; exit 3; }
    [ -z "${HEALTH_UNIX_SOCKET:-}" ] || { echo inherited-health-unix-socket >&2; exit 3; }
    [ -z "${LOG_HTTP_RAW_UNSAFE:-}" ] || { echo inherited-raw-http-logging >&2; exit 3; }
fi
if [ -n "${MCP_TEST_ENV_CAPTURE:-}" ]; then
    {
        printf '%s\n' "${MCP_EXTRA_HEADERS:-}"
        printf '%s\n' "${MCP_DISCOVERY_EXTRA_HEADERS:-}"
    } > "$MCP_TEST_ENV_CAPTURE"
fi
case "$1" in
    init)
        [ "${MCP_EXTRA_HEADERS:-}" = "X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN" ] || { echo bad-mcp-extra-headers >&2; exit 3; }
        [ "${MCP_DISCOVERY_EXTRA_HEADERS:-}" = "X-FileMCP-Local-Token: env:FILEMCP_LOCAL_AUTH_TOKEN" ] || { echo bad-discovery-extra-headers >&2; exit 3; }
        case "${FILEMCP_LOCAL_AUTH_TOKEN:-}" in
            ''|*[!0-9a-f]*) echo invalid-local-auth-token >&2; exit 3 ;;
        esac
        [ "${#FILEMCP_LOCAL_AUTH_TOKEN}" -eq 64 ] || { echo bad-local-auth-token-length >&2; exit 3; }
        if [ "${MCP_TEST_SLOW_INIT:-0}" = "1" ]; then sleep 10; fi
        echo "init-ok ${CONTROL_PLANE_API_KEY:-} ${FILEMCP_LOCAL_AUTH_TOKEN:-}"
        exit 0
        ;;
    doctor) echo "doctor-ok ${CONTROL_PLANE_API_KEY:-} ${FILEMCP_LOCAL_AUTH_TOKEN:-}"; exit 0 ;;
    run) echo "run-ok ${CONTROL_PLANE_API_KEY:-} ${FILEMCP_LOCAL_AUTH_TOKEN:-}"; trap 'exit 0' TERM INT; while :; do sleep 1; done ;;
    *) echo unsupported-subcommand >&2; exit 2 ;;
esac
SH
chmod +x "$TMP_DIR/tunnel-client"

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

func waitFor(_ predicate: () -> Bool, timeout: TimeInterval, label: String) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return }
        Thread.sleep(forTimeInterval: 0.05)
    }
    fatalError("timed out waiting for \(label)")
}

func isFailed(_ state: LocalMCPRuntimeState) -> Bool {
    if case .failed = state { return true }
    return false
}

func holdsIdleSleepAssertion() -> Bool {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    process.arguments = ["-g", "assertions"]
    process.standardOutput = pipe
    try! process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    return output.split(whereSeparator: { $0.isNewline }).contains { line in
        line.contains("pid \(getpid())(") && line.contains("PreventUserIdleSystemSleep")
    }
}

let root = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-runtime-test-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let profile = "runtime-test-\(UUID().uuidString)"
let profileDirectory = root.appendingPathComponent("tunnel-profiles", isDirectory: true)
let authCapture = root.appendingPathComponent("local-auth-headers.txt")
setenv("MCP_TEST_ENV_CAPTURE", authCapture.path, 1)
setenv("MCP_TEST_PROFILE_DIR_EXPECTED", profileDirectory.path, 1)
setenv("MCP_SERVER_URL", "https://evil.example/mcp", 1)
setenv("HEALTH_UNIX_SOCKET", "/tmp/evil-health.sock", 1)
setenv("LOG_HTTP_RAW_UNSAFE", "true", 1)
let first = LocalMCPRuntime(profileDirectory: profileDirectory)
let second = LocalMCPRuntime(profileDirectory: profileDirectory)
let logLock = NSLock()
var capturedRuntimeLog = ""
first.onLog = { text in
    logLock.lock()
    capturedRuntimeLog += text
    logLock.unlock()
}
let firstConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: profile, port: 18086,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
let secondConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: profile, port: 18087,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)

first.start(firstConfig)
waitFor({ first.state == .running }, timeout: 5, label: "first runtime")
waitFor({ holdsIdleSleepAssertion() }, timeout: 2, label: "idle sleep assertion while running")
let authLines = try String(contentsOf: authCapture, encoding: .utf8)
    .split(whereSeparator: { $0.isNewline })
    .map(String.init)
precondition(authLines.count == 2, "tunnel-client did not receive both local auth header settings")
let expectedLocalAuthHeader = "\(fileMCPLocalAuthHeaderName): env:FILEMCP_LOCAL_AUTH_TOKEN"
precondition(authLines[0] == expectedLocalAuthHeader, "unexpected runtime local auth header reference")
precondition(authLines[1] == expectedLocalAuthHeader, "unexpected discovery local auth header reference")
Thread.sleep(forTimeInterval: 0.2)
logLock.lock()
let safeRuntimeLog = capturedRuntimeLog
logLock.unlock()
precondition(!safeRuntimeLog.contains("test-key"), "runtime log leaked the control-plane API key")
precondition(safeRuntimeLog.range(of: "[0-9a-f]{64}", options: .regularExpression) == nil, "runtime log leaked the local auth token")
precondition(safeRuntimeLog.contains("[REDACTED]"), "runtime log did not exercise secret redaction")
unsetenv("MCP_TEST_ENV_CAPTURE")
second.start(secondConfig)
waitFor({ isFailed(second.state) }, timeout: 5, label: "profile lock failure")
first.stop()
waitFor({ first.state == .stopped }, timeout: 5, label: "first stop")
waitFor({ !holdsIdleSleepAssertion() }, timeout: 2, label: "idle sleep assertion released after stop")
second.start(secondConfig)
waitFor({ second.state == .running }, timeout: 5, label: "second recovery")
second.stop()
waitFor({ second.state == .stopped }, timeout: 5, label: "second stop")
first.start(firstConfig)
waitFor({ first.state == .running }, timeout: 5, label: "first restart")
first.shutdownImmediately()
waitFor({ first.state == .stopped }, timeout: 5, label: "shutdown")
waitFor({ !holdsIdleSleepAssertion() }, timeout: 2, label: "idle sleep assertion released after shutdown")
print("runtime-lifecycle-profile-lock: ok")

let invalidHealthRuntime = LocalMCPRuntime(profileDirectory: profileDirectory)
let invalidHealthConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: "invalid-health-\(UUID().uuidString)", port: 18083,
    allowedDirectory: root.path, healthAddress: "0.0.0.0:8080",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
invalidHealthRuntime.start(invalidHealthConfig)
waitFor({ isFailed(invalidHealthRuntime.state) }, timeout: 2, label: "non-loopback health address rejection")
if case let .failed(message) = invalidHealthRuntime.state {
    precondition(message.contains("Health listener must use localhost"), "unexpected health validation error: \(message)")
}
print("runtime-health-loopback-policy: ok")

let invalidTunnelRuntime = LocalMCPRuntime(profileDirectory: profileDirectory)
let invalidTunnelConfig = LocalMCPConfiguration(
    tunnelID: "tunnel-test", apiKey: "test-key", profile: "invalid-tunnel", port: 18082,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
invalidTunnelRuntime.start(invalidTunnelConfig)
waitFor({ isFailed(invalidTunnelRuntime.state) }, timeout: 2, label: "invalid tunnel ID rejection")
if case let .failed(message) = invalidTunnelRuntime.state {
    precondition(message.contains("Tunnel ID must match"), "unexpected tunnel ID validation error: \(message)")
}

let invalidProfileRuntime = LocalMCPRuntime(profileDirectory: profileDirectory)
let invalidProfileConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: "../escape", port: 18081,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
invalidProfileRuntime.start(invalidProfileConfig)
waitFor({ isFailed(invalidProfileRuntime.state) }, timeout: 2, label: "invalid profile rejection")
if case let .failed(message) = invalidProfileRuntime.state {
    precondition(message.contains("Profile must start"), "unexpected profile validation error: \(message)")
}
print("runtime-tunnel-profile-validation: ok")

setenv("MCP_TEST_SLOW_INIT", "1", 1)
let immediateStopRuntime = LocalMCPRuntime(profileDirectory: profileDirectory)
let immediateStopConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: "immediate-\(UUID().uuidString)", port: 18084,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
immediateStopRuntime.start(immediateStopConfig)
immediateStopRuntime.stop()
Thread.sleep(forTimeInterval: 0.5)
precondition(immediateStopRuntime.state == .stopped, "immediate stop after start must cancel the queued startup")
print("runtime-immediate-stop: ok")

let slowRuntime = LocalMCPRuntime(profileDirectory: profileDirectory)
let slowConfig = LocalMCPConfiguration(
    tunnelID: "tunnel_0123456789abcdef0123456789abcdef", apiKey: "test-key", profile: "slow-\(UUID().uuidString)", port: 18085,
    allowedDirectory: root.path, healthAddress: "127.0.0.1:0",
    gitUserName: "", gitUserEmail: "", enableCommands: false
)
slowRuntime.start(slowConfig)
waitFor({ slowRuntime.state == .starting }, timeout: 2, label: "slow runtime starting")
Thread.sleep(forTimeInterval: 0.2)
let shutdownStart = Date()
slowRuntime.shutdownImmediately()
let shutdownElapsed = Date().timeIntervalSince(shutdownStart)
unsetenv("MCP_TEST_SLOW_INIT")
unsetenv("MCP_TEST_PROFILE_DIR_EXPECTED")
unsetenv("MCP_SERVER_URL")
unsetenv("HEALTH_UNIX_SOCKET")
unsetenv("LOG_HTTP_RAW_UNSAFE")
precondition(slowRuntime.state == .stopped, "cancelled bootstrap must end stopped")
precondition(shutdownElapsed < 2.5, "bootstrap shutdown took too long: \(shutdownElapsed)s")
print("runtime-bootstrap-cancel: ok")
SWIFT

swiftc -framework Network -framework Security -o "$TMP_DIR/runtime-test" \
    macos/ProcessRunner.swift \
    macos/Ripgrep.swift \
    macos/LocalMCPServer.swift \
    macos/CodexHistory.swift \
    macos/LocalMCPRuntime.swift \
    "$TMP_DIR/main.swift"
"$TMP_DIR/runtime-test"

cat >"$TMP_DIR/main.swift" <<'SWIFT'
import Foundation

let root = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-server-test")
try? FileManager.default.removeItem(at: root)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
try "hello swift".write(to: root.appendingPathComponent("hello.txt"), atomically: true, encoding: .utf8)
try """
import Foundation

func alpha() {
    print("needle-target")
}

func beta() {
    alpha()
}
""".write(to: root.appendingPathComponent("sample.swift"), atomically: true, encoding: .utf8)
let crlfText = [
    "line-one",
    "line-two",
    "needle-crlf",
    "line-four",
].joined(separator: "\r\n")
try crlfText.write(to: root.appendingPathComponent("crlf.txt"), atomically: true, encoding: .utf8)
let binaryDirectory = root.appendingPathComponent("binary-only")
try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
var binaryData = Data(repeating: 65, count: 1_024)
binaryData[0] = 0
try binaryData.write(to: binaryDirectory.appendingPathComponent("blob.bin"))
try "first\nsecond\n".write(to: root.appendingPathComponent("trailing-newline.txt"), atomically: true, encoding: .utf8)
try String(repeating: "x", count: 80_001).write(to: root.appendingPathComponent("long-line.txt"), atomically: true, encoding: .utf8)
let manyLinesText = (1...1200).map { index in
    String(format: "SHORT-%04d", index)
}.joined(separator: "\n")
try manyLinesText.write(to: root.appendingPathComponent("many-lines.txt"), atomically: true, encoding: .utf8)
let largeRangeText = (1...1000).map { index in
    String(format: "LINE-%04d ", index) + String(repeating: "x", count: 190)
}.joined(separator: "\n")
try largeRangeText.write(to: root.appendingPathComponent("large-range.txt"), atomically: true, encoding: .utf8)
let listLimitDirectory = root.appendingPathComponent("list-limit")
try FileManager.default.createDirectory(at: listLimitDirectory, withIntermediateDirectories: true)
for index in 1...1001 {
    FileManager.default.createFile(
        atPath: listLimitDirectory.appendingPathComponent(String(format: "entry-%04d.txt", index)).path,
        contents: Data()
    )
}
let filenameLimitDirectory = root.appendingPathComponent("filename-limit")
try FileManager.default.createDirectory(at: filenameLimitDirectory, withIntermediateDirectories: true)
for index in 1...205 {
    FileManager.default.createFile(
        atPath: filenameLimitDirectory.appendingPathComponent(String(format: "filename-target-%03d.txt", index)).path,
        contents: Data()
    )
}
let scopeA = root.appendingPathComponent("scope-a")
let scopeB = root.appendingPathComponent("scope-b")
try FileManager.default.createDirectory(at: scopeA, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: scopeB, withIntermediateDirectories: true)
try "a".write(to: scopeA.appendingPathComponent("scoped-target.txt"), atomically: true, encoding: .utf8)
try "b".write(to: scopeB.appendingPathComponent("scoped-target.txt"), atomically: true, encoding: .utf8)
let nextDirectory = root.appendingPathComponent(".next")
try FileManager.default.createDirectory(at: nextDirectory, withIntermediateDirectories: true)
try "generated".write(to: nextDirectory.appendingPathComponent("generated-target.txt"), atomically: true, encoding: .utf8)

let ignoredProject = root.appendingPathComponent("ignored-project")
try FileManager.default.createDirectory(at: ignoredProject.appendingPathComponent("generated"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: ignoredProject.appendingPathComponent("src"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: ignoredProject.appendingPathComponent(".git"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: ignoredProject.appendingPathComponent("generated/EmptyGenerated.xcodeproj"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: ignoredProject.appendingPathComponent("dotignored/EmptyIgnored.xcworkspace"), withIntermediateDirectories: true)
try "generated/\n".write(to: ignoredProject.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
try "dotignored/\n".write(to: ignoredProject.appendingPathComponent(".ignore"), atomically: true, encoding: .utf8)
try "ignore-probe\n".write(to: ignoredProject.appendingPathComponent("generated/output.txt"), atomically: true, encoding: .utf8)
try "ignore-probe\n".write(to: ignoredProject.appendingPathComponent("src/kept.txt"), atomically: true, encoding: .utf8)
try "ignore-probe\n".write(to: ignoredProject.appendingPathComponent(".git/probe.txt"), atomically: true, encoding: .utf8)

let grepFixture = root.appendingPathComponent("grep-fixture")
try FileManager.default.createDirectory(at: grepFixture, withIntermediateDirectories: true)
try "let grepAlpha = 1\nlet grepAlpha2 = 2\nfunc grepBeta() {\n    grepAlpha\n}\n".write(
    to: grepFixture.appendingPathComponent("alpha.swift"), atomically: true, encoding: .utf8
)
try "const GREPALPHA = 3;\nconst grepBeta = { start:\n  end };\n".write(
    to: grepFixture.appendingPathComponent("beta.ts"), atomically: true, encoding: .utf8
)
let caseGlob = root.appendingPathComponent("case-glob")
try FileManager.default.createDirectory(at: caseGlob, withIntermediateDirectories: true)
try "case-probe\n".write(to: caseGlob.appendingPathComponent("ReadMe.MD"), atomically: true, encoding: .utf8)
let globOrder = root.appendingPathComponent("glob-order")
try FileManager.default.createDirectory(at: globOrder, withIntermediateDirectories: true)
for (name, timestamp) in [("older.swift", 1_600_000_000.0), ("newer.swift", 1_700_000_000.0), ("middle.swift", 1_650_000_000.0)] {
    let file = globOrder.appendingPathComponent(name)
    try "order\n".write(to: file, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: timestamp)], ofItemAtPath: file.path)
}

let rankedSearchDirectory = root.appendingPathComponent("ranked-search")
try FileManager.default.createDirectory(at: rankedSearchDirectory, withIntermediateDirectories: true)
for index in 1...30 {
    try "let usage_\(index) = QualityTarget()\n".write(
        to: rankedSearchDirectory.appendingPathComponent(String(format: "usage-%02d.swift", index)),
        atomically: true,
        encoding: .utf8
    )
}
try "final class QualityTarget {}\n".write(
    to: rankedSearchDirectory.appendingPathComponent("definition.swift"),
    atomically: true,
    encoding: .utf8
)
try "let fixture = \"final class StringOnlyTarget {}\"\n".write(
    to: rankedSearchDirectory.appendingPathComponent("string-fixture.swift"),
    atomically: true,
    encoding: .utf8
)
try "let call = TypedTarget()\nİ.obj.TypedTarget()\nprivate func TypedTarget() {}\n".write(
    to: rankedSearchDirectory.appendingPathComponent("typed-definition.swift"),
    atomically: true,
    encoding: .utf8
)
try "let used = TypedValueTarget\nprivate static int TypedValueTarget = 1;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("typed-value.cs"),
    atomically: true,
    encoding: .utf8
)
try "let call = GenericTarget<Int>(1)\nprivate TResult GenericTarget<TArg>(TArg value) => default!;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("generic-method.cs"),
    atomically: true,
    encoding: .utf8
)
try "value = 1# class PythonCommentTarget: pass\n".write(
    to: rankedSearchDirectory.appendingPathComponent("python-comment.py"),
    atomically: true,
    encoding: .utf8
)
try "var raw = `\ntype GoRawStringTarget struct{}\n`\n".write(
    to: rankedSearchDirectory.appendingPathComponent("go-raw.go"),
    atomically: true,
    encoding: .utf8
)
try "echo ok # class ShellCommentTarget {}\n".write(
    to: rankedSearchDirectory.appendingPathComponent("shell-comment.sh"),
    atomically: true,
    encoding: .utf8
)
try "<#\nclass PowerShellBlockTarget {}\n#>\n#class PowerShellLineTarget {}\n".write(
    to: rankedSearchDirectory.appendingPathComponent("powershell-comment.ps1"),
    atomically: true,
    encoding: .utf8
)
try "let exact = CaseTarget()\n".write(
    to: rankedSearchDirectory.appendingPathComponent("case-exact.swift"),
    atomically: true,
    encoding: .utf8
)
try "let lower = casetarget()\n".write(
    to: rankedSearchDirectory.appendingPathComponent("case-lower.swift"),
    atomically: true,
    encoding: .utf8
)
try "let ref = FilenameOnlyTarget()\n".write(
    to: rankedSearchDirectory.appendingPathComponent("FilenameOnlyTarget.swift"),
    atomically: true,
    encoding: .utf8
)
try "let ref = FilenameMatchTarget()\n".write(
    to: rankedSearchDirectory.appendingPathComponent("prefix-FilenameMatchTarget-suffix.swift"),
    atomically: true,
    encoding: .utf8
)
try "const AmbiguousTypeUsage& value = source;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("ambiguous-type-usage.cpp"),
    atomically: true,
    encoding: .utf8
)
try "class AmbiguousTypeUsage {};\n".write(
    to: rankedSearchDirectory.appendingPathComponent("ambiguous-type-definition.hpp"),
    atomically: true,
    encoding: .utf8
)
try "const ConstantTarget = 1;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("constant.js"),
    atomically: true,
    encoding: .utf8
)
try "static RustStaticTarget: i32 = 1;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("static.rs"),
    atomically: true,
    encoding: .utf8
)
try "/*\nfinal class BlockCommentTarget {}\n/* nested */\nfinal class NestedBlockCommentTarget {}\n*/\nlet raw = \"\"\"\nfinal class MultilineStringTarget {}\n\"\"\"\nprivate func `EscapedTarget`() {}\n".write(
    to: rankedSearchDirectory.appendingPathComponent("lexical-state.swift"),
    atomically: true,
    encoding: .utf8
)
try "const raw = `\nclass TemplateStringTarget {}\n`;\n".write(
    to: rankedSearchDirectory.appendingPathComponent("lexical-template.ts"),
    atomically: true,
    encoding: .utf8
)

let overviewProject = root.appendingPathComponent("overview-project")
try FileManager.default.createDirectory(at: overviewProject.appendingPathComponent("src"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: overviewProject.appendingPathComponent("tests"), withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: overviewProject.appendingPathComponent("node_modules/ignored"), withIntermediateDirectories: true)
try "{}".write(to: overviewProject.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
try "export const main = 1\n".write(to: overviewProject.appendingPathComponent("src/main.ts"), atomically: true, encoding: .utf8)
try "export const test = 1\n".write(to: overviewProject.appendingPathComponent("tests/main.test.ts"), atomically: true, encoding: .utf8)
try "hidden\n".write(to: overviewProject.appendingPathComponent("node_modules/ignored/hidden.ts"), atomically: true, encoding: .utf8)
try "{}".write(to: overviewProject.appendingPathComponent("node_modules/ignored/package.json"), atomically: true, encoding: .utf8)
let xcodeProject = overviewProject.appendingPathComponent("Demo.xcodeproj")
try FileManager.default.createDirectory(at: xcodeProject, withIntermediateDirectories: true)
try "project-marker\n".write(
    to: xcodeProject.appendingPathComponent("project.pbxproj"),
    atomically: true,
    encoding: .utf8
)
try FileManager.default.createDirectory(
    at: overviewProject.appendingPathComponent("empty-dir"),
    withIntermediateDirectories: true
)
try FileManager.default.createDirectory(
    at: overviewProject.appendingPathComponent("EmptyProject.xcodeproj"),
    withIntermediateDirectories: true
)
try FileManager.default.createDirectory(
    at: overviewProject.appendingPathComponent("EmptyWorkspace.xcworkspace"),
    withIntermediateDirectories: true
)

let caseExcludedProject = root.appendingPathComponent("case-exclusion-project")
try FileManager.default.createDirectory(
    at: caseExcludedProject.appendingPathComponent("NODE_MODULES/ignored"),
    withIntermediateDirectories: true
)
try "case-hidden\n".write(
    to: caseExcludedProject.appendingPathComponent("NODE_MODULES/ignored/hidden.ts"),
    atomically: true,
    encoding: .utf8
)

let outside = FileManager.default.temporaryDirectory.appendingPathComponent("filemcp-server-outside")
try? FileManager.default.removeItem(at: outside)
try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try "must stay private".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)
try "{}".write(to: outside.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
try "keep target".write(to: root.appendingPathComponent("delete-target.txt"), atomically: true, encoding: .utf8)
let deleteTargetDirectory = root.appendingPathComponent("delete-target-dir")
try FileManager.default.createDirectory(at: deleteTargetDirectory, withIntermediateDirectories: true)
try "keep nested".write(to: deleteTargetDirectory.appendingPathComponent("nested.txt"), atomically: true, encoding: .utf8)
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("delete-file-link"),
    withDestinationURL: root.appendingPathComponent("delete-target.txt")
)
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("delete-dir-link"),
    withDestinationURL: deleteTargetDirectory
)
try FileManager.default.createSymbolicLink(
    at: root.appendingPathComponent("delete-outside-link"),
    withDestinationURL: outside.appendingPathComponent("secret.txt")
)

let localAuthToken = String(repeating: "a", count: 64)

do {
    let invalidPortServer = try LocalMCPServer(
        port: 0, allowedDirectory: root.path, gitUserName: "", gitUserEmail: "",
        enableCommands: false, localAuthToken: localAuthToken, log: { _ in }
    )
    try invalidPortServer.start()
    preconditionFailure("port 0 must be rejected")
} catch {
    // Expected: the tunnel needs a stable non-zero local port.
}

let safeGitServer = try LocalMCPServer(
    port: 18089,
    allowedDirectory: root.path,
    gitUserName: "Test User",
    gitUserEmail: "test@example.com",
    enableCommands: false,
    localAuthToken: localAuthToken,
    log: { _ in }
)
let server = try LocalMCPServer(
    port: 18088,
    allowedDirectory: root.path,
    gitUserName: "Test User",
    gitUserEmail: "test@example.com",
    enableCommands: true,
    localAuthToken: localAuthToken,
    log: { _ in }
)
try safeGitServer.start()
try server.start()
// The shell harness owns this process lifetime and terminates it after all
// transport tests. Do not use a wall-clock timer here: as the suite grows, a
// fixed lifetime turns later parser/fuzz checks into false crash reports.
while true {
    RunLoop.current.run(until: Date().addingTimeInterval(3_600))
}
SWIFT

swiftc -framework Network -o "$TMP_DIR/server-test" \
    macos/ProcessRunner.swift \
    macos/Ripgrep.swift \
    macos/LocalMCPServer.swift \
    macos/CodexHistory.swift \
    "$TMP_DIR/main.swift"
mkdir -p "$TMP_DIR/git-template"
printf 'outside-template-marker\n' > "$TMP_DIR/git-template/copied-from-template"
FILEMCP_RG="$PWD/vendor/ripgrep/darwin-arm64/rg" GIT_TEMPLATE_DIR="$TMP_DIR/git-template" "$TMP_DIR/server-test" &
SERVER_PID=$!
sleep 1

BASE_URL="http://127.0.0.1:18088/mcp"
SAFE_BASE_URL="http://127.0.0.1:18089/mcp"
SERVER_ROOT="${TMPDIR%/}/filemcp-server-test"
LOCAL_AUTH_TOKEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

UNAUTHENTICATED="$(command curl -sS -i -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":389,"method":"ping","params":{}}')"
printf '%s' "$UNAUTHENTICATED" | grep -q 'HTTP/1.1 401 Unauthorized'
printf '%s' "$UNAUTHENTICATED" | grep -q 'Unauthorized'

DISCOVERY_PATH="$(command curl -sS -i 'http://127.0.0.1:18088/.well-known/oauth-protected-resource/mcp')"
printf '%s' "$DISCOVERY_PATH" | grep -q 'HTTP/1.1 404 Not Found'
printf '%s' "$DISCOVERY_PATH" | grep -q 'Not found'

DISCOVERY_ROOT="$(command curl -sS -i 'http://127.0.0.1:18088/.well-known/oauth-protected-resource')"
printf '%s' "$DISCOVERY_ROOT" | grep -q 'HTTP/1.1 404 Not Found'

UNAUTHENTICATED_UNKNOWN_PATH="$(command curl -sS -i 'http://127.0.0.1:18088/not-found')"
printf '%s' "$UNAUTHENTICATED_UNKNOWN_PATH" | grep -q 'HTTP/1.1 401 Unauthorized'

UNAUTHENTICATED_DISCOVERY_POST="$(command curl -sS -i -X POST 'http://127.0.0.1:18088/.well-known/oauth-protected-resource/mcp')"
printf '%s' "$UNAUTHENTICATED_DISCOVERY_POST" | grep -q 'HTTP/1.1 401 Unauthorized'

DOCTOR_RESULT="$(CONTROL_PLANE_API_KEY=dummy-key "$TUNNEL_BIN" doctor \
    --control-plane.tunnel-id tunnel_0123456789abcdef0123456789abcdef \
    --mcp.server-url "$BASE_URL" \
    --health.listen-addr 127.0.0.1:0 2>&1)"
printf '%s' "$DOCTOR_RESULT" | grep -Eq 'CHECK oauth_metadata +PASS OAuth metadata not advertised'
printf '%s' "$DOCTOR_RESULT" | grep -q 'RESULT ok'
echo "tunnel-client-doctor-no-auth-oauth-discovery: ok"

WRONG_LOCAL_TOKEN="$(command curl -sS -i -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'X-FileMCP-Local-Token: bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' \
    -d '{"jsonrpc":"2.0","id":388,"method":"ping","params":{}}')"
printf '%s' "$WRONG_LOCAL_TOKEN" | grep -q 'HTTP/1.1 401 Unauthorized'

curl() {
    command curl -H "X-FileMCP-Local-Token: $LOCAL_AUTH_TOKEN" "$@"
}

SAFE_TOOLS="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":390,"method":"tools/list","params":{}}')"
if printf '%s' "$SAFE_TOOLS" | grep -q '"name":"run_command"'; then
    echo "run_command must not be exposed while command execution is disabled" >&2
    exit 1
fi
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"save_conversation_to_codex"'
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"search_code"'
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"repo_overview"'
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"batch_read"'
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"apply_patch"'
printf '%s' "$SAFE_TOOLS" | grep -q '"name":"workspace_context"'

INVALID_CODEX_MESSAGES="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":391,"method":"tools/call","params":{"name":"save_conversation_to_codex","arguments":{"title":"invalid fixture","messages":[{"role":"system","content":"must be rejected"}]}}}')"
printf '%s' "$INVALID_CODEX_MESSAGES" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$INVALID_CODEX_MESSAGES" | grep -q 'role must be user or assistant'

NEGATIVE_LENGTH="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: -1\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$NEGATIVE_LENGTH" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$NEGATIVE_LENGTH" | grep -q 'Invalid Content-Length header'
kill -0 "$SERVER_PID"

OVERSIZED_LENGTH="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: 8000001\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$OVERSIZED_LENGTH" | grep -q 'HTTP/1.1 413 Payload Too Large'
kill -0 "$SERVER_PID"

MALFORMED_LENGTH="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: nope\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$MALFORMED_LENGTH" | grep -q 'HTTP/1.1 400 Bad Request'
kill -0 "$SERVER_PID"

SIGNED_LENGTH="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: +1\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$SIGNED_LENGTH" | grep -q 'HTTP/1.1 400 Bad Request'
kill -0 "$SERVER_PID"

DUPLICATE_LENGTH="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$DUPLICATE_LENGTH" | grep -q 'HTTP/1.1 400 Bad Request'
kill -0 "$SERVER_PID"

DUPLICATE_MCP_METHOD="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nMcp-Method: ping\r\nMcp-Method: tools/list\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$DUPLICATE_MCP_METHOD" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$DUPLICATE_MCP_METHOD" | grep -q 'Duplicate mcp-method header'
kill -0 "$SERVER_PID"

TRANSFER_ENCODING="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$TRANSFER_ENCODING" | grep -q 'HTTP/1.1 400 Bad Request'
kill -0 "$SERVER_PID"

MALFORMED_HEADER_NAME="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nBad Header: value\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$MALFORMED_HEADER_NAME" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$MALFORMED_HEADER_NAME" | grep -q 'Malformed request header'
kill -0 "$SERVER_PID"

HEADER_NAME_OWS="$(printf 'POST /mcp HTTP/1.1\r\nHost : 127.0.0.1:18088\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$HEADER_NAME_OWS" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$HEADER_NAME_OWS" | grep -q 'Malformed request header'
kill -0 "$SERVER_PID"

INVALID_HOST_PORT="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:99999\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$INVALID_HOST_PORT" | grep -q 'HTTP/1.1 403 Forbidden'
kill -0 "$SERVER_PID"

EXTRA_BODY_BYTES="$(printf 'POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nX-FileMCP-Local-Token: %s\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\nJUNK' "$LOCAL_AUTH_TOKEN" | nc 127.0.0.1 18088)"
printf '%s' "$EXTRA_BODY_BYTES" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$EXTRA_BODY_BYTES" | grep -q 'Unexpected bytes after request body'
kill -0 "$SERVER_PID"

MISSING_HOST="$(printf 'POST /mcp HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$MISSING_HOST" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$MISSING_HOST" | grep -q 'Missing Host header'
kill -0 "$SERVER_PID"

EARLY_FORBIDDEN_HOST="$(printf 'POST /mcp HTTP/1.1\r\nHost: evil.example\r\nContent-Type: application/json\r\nContent-Length: 8000000\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$EARLY_FORBIDDEN_HOST" | grep -q 'HTTP/1.1 403 Forbidden'
printf '%s' "$EARLY_FORBIDDEN_HOST" | grep -q 'Forbidden host'
kill -0 "$SERVER_PID"

MALFORMED_REQUEST_LINE="$(printf 'POST /mcp\r\nHost: 127.0.0.1:18088\r\nContent-Length: 0\r\n\r\n' | nc 127.0.0.1 18088)"
printf '%s' "$MALFORMED_REQUEST_LINE" | grep -q 'HTTP/1.1 400 Bad Request'
printf '%s' "$MALFORMED_REQUEST_LINE" | grep -q 'Malformed request line'
kill -0 "$SERVER_PID"

# Repeated malformed framing used to be difficult to distinguish from the test
# server's fixed lifetime expiring. Keep the server alive under harness control
# and hammer deterministic malformed variants, then prove it still serves a
# valid request afterwards.
for index in $(seq 1 "$MCP_HTTP_FUZZ_ITERATIONS"); do
    case $((index % 5)) in
        0) request="POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: -${index}\r\n\r\n" ;;
        1) request="POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: application/json\r\nContent-Length: ${index}x\r\n\r\n" ;;
        2) request="POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n" ;;
        3) request="P${index} /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Length: 0\r\n\r\n" ;;
        4) request="POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:18088\r\nContent-Type: text/plain\r\nX-Fuzz-${index}: value\r\nContent-Length: 0\r\n\r\n" ;;
    esac
    printf '%b' "$request" | nc 127.0.0.1 18088 >/dev/null
    if [ $((index % 20)) -eq 0 ]; then
        kill -0 "$SERVER_PID"
    fi
done
POST_FUZZ_PING="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":399,"method":"ping","params":{}}')"
printf '%s' "$POST_FUZZ_PING" | grep -q '"result"'
kill -0 "$SERVER_PID"
echo "http-malformed-fuzz: ok"

INITIALIZE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')"
printf '%s' "$INITIALIZE" | grep -q '"protocolVersion":"2025-03-26"'
printf '%s' "$INITIALIZE" | grep -q '"serverInfo"'
printf '%s' "$INITIALIZE" | grep -q '"name":"filemcp"'

TOP_LEVEL_NON_OBJECT_PARAMS="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":101,"method":"initialize","params":[]}')"
printf '%s' "$TOP_LEVEL_NON_OBJECT_PARAMS" | grep -q '"code":-32602'
printf '%s' "$TOP_LEVEL_NON_OBJECT_PARAMS" | grep -q 'Invalid params: expected an object'

CLAIMLESS_DISCOVER="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":102,"method":"server/discover","params":{}}')"
printf '%s' "$CLAIMLESS_DISCOVER" | grep -q '"code":-32601'
printf '%s' "$CLAIMLESS_DISCOVER" | grep -q 'Method not found: server.*discover'

DOWNGRADE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"protocolVersion":"2099-01-01","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}')"
printf '%s' "$DOWNGRADE" | grep -q '"protocolVersion":"2025-11-25"'

READ_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"read_file","arguments":{"relative_path":"hello.txt"}}}')"
printf '%s' "$READ_RESULT" | grep -q 'hello swift'

printf '%s' "$READ_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -qx 'hello swift'

LIST_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"list_files","arguments":{}}}')"
printf '%s' "$LIST_RESULT" | plutil -extract result.structuredContent.result raw -expect array -o - - | grep -Eq '^[1-9][0-9]*$'
printf '%s' "$LIST_RESULT" | plutil -extract result.structuredContent.result json -o - - | grep -q '"sample.swift"'

printf '%s' "$LIST_RESULT" | plutil -extract result.structuredContent.truncated raw -expect bool -o - - | grep -qx 'false'

LIST_LIMIT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":300,"method":"tools/call","params":{"name":"list_files","arguments":{"subpath":"list-limit"}}}')"
printf '%s' "$LIST_LIMIT_RESULT" | plutil -extract result.structuredContent.result raw -expect array -o - - | grep -qx '1000'
printf '%s' "$LIST_LIMIT_RESULT" | plutil -extract result.structuredContent.truncated raw -expect bool -o - - | grep -qx 'true'
if printf '%s' "$LIST_LIMIT_RESULT" | grep -q '\[\.\.\.truncated'; then
    echo "list_files leaked truncation marker into filename results" >&2
    exit 1
fi

tool_call() {
    curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
        -d "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"
}
extract() {
    plutil -extract "result.structuredContent.$1" "$2" -o - -
}

GLOB_RESULT="$(tool_call 301 glob '{"pattern":"sample.swift"}')"
printf '%s' "$GLOB_RESULT" | extract files raw | grep -qx '1'
printf '%s' "$GLOB_RESULT" | extract files.0 raw | grep -qx 'sample.swift'
if printf '%s' "$GLOB_RESULT" | grep -q '/private'; then
    echo "glob returned a non-relative canonical path" >&2
    exit 1
fi
printf '%s' "$GLOB_RESULT" | extract truncated raw | grep -qx 'false'
printf '%s' "$GLOB_RESULT" | grep -q '"next_offset":null'

SCOPED_GLOB_RESULT="$(tool_call 3011 glob '{"pattern":"scoped-target*","path":"scope-a"}')"
printf '%s' "$SCOPED_GLOB_RESULT" | extract files raw | grep -qx '1'
printf '%s' "$SCOPED_GLOB_RESULT" | extract files.0 raw | grep -qx 'scope-a/scoped-target.txt'

BROAD_GENERATED_GLOB_RESULT="$(tool_call 3012 glob '{"pattern":"generated-target.txt"}')"
printf '%s' "$BROAD_GENERATED_GLOB_RESULT" | extract files.0 raw | grep -qx '.next/generated-target.txt'
EXPLICIT_GENERATED_GLOB_RESULT="$(tool_call 3013 glob '{"pattern":"*","path":".next"}')"
printf '%s' "$EXPLICIT_GENERATED_GLOB_RESULT" | extract files.0 raw | grep -qx '.next/generated-target.txt'

BROAD_GENERATED_CONTENT_RESULT="$(tool_call 3014 grep '{"pattern":"generated","path":".next","output_mode":"content"}')"
printf '%s' "$BROAD_GENERATED_CONTENT_RESULT" | extract matches.0.path raw | grep -qx '.next/generated-target.txt'
BROAD_GENERATED_FILES_RESULT="$(tool_call 3015 grep '{"pattern":"^generated$"}')"
printf '%s' "$BROAD_GENERATED_FILES_RESULT" | extract files.0 raw | grep -qx '.next/generated-target.txt'

GREP_HEAD_LIMIT="$(tool_call 3016 grep '{"pattern":"QualityTarget","path":"ranked-search","head_limit":1}')"
printf '%s' "$GREP_HEAD_LIMIT" | extract truncated raw | grep -qx 'true'
printf '%s' "$GREP_HEAD_LIMIT" | extract truncation_reasons json | grep -q 'head_limit'
printf '%s' "$GREP_HEAD_LIMIT" | extract next_offset raw | grep -qx '1'
printf '%s' "$GREP_HEAD_LIMIT" | extract total raw | grep -qx '31'
GREP_SECOND_PAGE="$(tool_call 3043 grep '{"pattern":"QualityTarget","path":"ranked-search","head_limit":30,"offset":1}')"
printf '%s' "$GREP_SECOND_PAGE" | extract returned raw | grep -qx '30'
printf '%s' "$GREP_SECOND_PAGE" | grep -q '"next_offset":null'

IGNORED_DEFAULT="$(tool_call 3044 grep '{"pattern":"ignore-probe","path":"ignored-project"}')"
printf '%s' "$IGNORED_DEFAULT" | extract files raw | grep -qx '1'
printf '%s' "$IGNORED_DEFAULT" | extract files.0 raw | grep -qx 'ignored-project/src/kept.txt'
IGNORED_INCLUDED="$(tool_call 3045 grep '{"pattern":"ignore-probe","path":"ignored-project","include_ignored":true}')"
printf '%s' "$IGNORED_INCLUDED" | extract total raw | grep -qx '2'
printf '%s' "$IGNORED_INCLUDED" | grep -q 'ignored-project\\/generated\\/output.txt\|ignored-project/generated/output.txt'
if printf '%s' "$IGNORED_INCLUDED" | grep -q 'probe.txt'; then
    echo "include_ignored must still exclude .git" >&2
    exit 1
fi
IGNORED_GLOB="$(tool_call 3046 glob '{"pattern":"*.txt","path":"ignored-project"}')"
printf '%s' "$IGNORED_GLOB" | extract files raw | grep -qx '1'
printf '%s' "$IGNORED_GLOB" | extract files.0 raw | grep -qx 'ignored-project/src/kept.txt'
IGNORED_DEFAULT_OVERVIEW="$(tool_call 30469 repo_overview '{"path":"ignored-project"}')"
printf '%s' "$IGNORED_DEFAULT_OVERVIEW" | extract files_seen raw | grep -qx '3'
printf '%s' "$IGNORED_DEFAULT_OVERVIEW" | extract directories_seen raw | grep -qx '1'
if printf '%s' "$IGNORED_DEFAULT_OVERVIEW" | grep -q 'EmptyGenerated.xcodeproj\|EmptyIgnored.xcworkspace'; then
    echo "repo_overview leaked ignored empty manifests" >&2
    exit 1
fi
IGNORED_OVERVIEW="$(tool_call 3047 repo_overview '{"path":"ignored-project","include_ignored":true}')"
printf '%s' "$IGNORED_OVERVIEW" | extract files_seen raw | grep -qx '4'
printf '%s' "$IGNORED_OVERVIEW" | extract directories_seen raw | grep -qx '5'
printf '%s' "$IGNORED_OVERVIEW" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'EmptyGenerated.xcodeproj'
printf '%s' "$IGNORED_OVERVIEW" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'EmptyIgnored.xcworkspace'
DIRECT_GIT_GREP="$(tool_call 30471 grep '{"pattern":"ignore-probe","path":"ignored-project/.git"}')"
printf '%s' "$DIRECT_GIT_GREP" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$DIRECT_GIT_GREP" | grep -q '.git is always excluded from search'
DIRECT_GIT_FILE_GREP="$(tool_call 304711 grep '{"pattern":"ignore-probe","path":"ignored-project/.git/probe.txt","include_ignored":true}')"
printf '%s' "$DIRECT_GIT_FILE_GREP" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$DIRECT_GIT_FILE_GREP" | grep -q '.git is always excluded from search'
DIRECT_GIT_GLOB="$(tool_call 30472 glob '{"pattern":"*","path":"ignored-project/.git","include_ignored":true}')"
printf '%s' "$DIRECT_GIT_GLOB" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
DIRECT_GIT_CODE="$(tool_call 30473 search_code '{"queries":["ignore-probe"],"path":"ignored-project/.git","include_ignored":true}')"
printf '%s' "$DIRECT_GIT_CODE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
DIRECT_GIT_OVERVIEW="$(tool_call 30474 repo_overview '{"path":"ignored-project/.git","include_ignored":true}')"
printf '%s' "$DIRECT_GIT_OVERVIEW" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'

GREP_CONTENT="$(tool_call 3048 grep '{"pattern":"grepAlpha\\b","path":"grep-fixture","output_mode":"content","context":1}')"
printf '%s' "$GREP_CONTENT" | extract total raw | grep -qx '2'
printf '%s' "$GREP_CONTENT" | extract matches.0.path raw | grep -qx 'grep-fixture/alpha.swift'
printf '%s' "$GREP_CONTENT" | extract matches.0.line raw | grep -qx '1'
printf '%s' "$GREP_CONTENT" | extract matches.0.before raw | grep -qx '0'
printf '%s' "$GREP_CONTENT" | extract matches.0.after.0.text raw | grep -qx 'let grepAlpha2 = 2'
printf '%s' "$GREP_CONTENT" | extract matches.1.line raw | grep -qx '4'
printf '%s' "$GREP_CONTENT" | extract matches.1.before.0.line raw | grep -qx '3'
GREP_INSENSITIVE_COUNT="$(tool_call 3049 grep '{"pattern":"grepalpha","fixed_strings":true,"case_insensitive":true,"path":"grep-fixture","output_mode":"count"}')"
printf '%s' "$GREP_INSENSITIVE_COUNT" | extract counts json | grep -q '"count":3'
printf '%s' "$GREP_INSENSITIVE_COUNT" | extract counts.1.path raw | grep -qx 'grep-fixture/beta.ts'
printf '%s' "$GREP_INSENSITIVE_COUNT" | extract counts.1.count raw | grep -qx '1'
GREP_TYPE="$(tool_call 3050 grep '{"pattern":"grepBeta","path":"grep-fixture","type":"ts"}')"
printf '%s' "$GREP_TYPE" | extract files raw | grep -qx '1'
printf '%s' "$GREP_TYPE" | extract files.0 raw | grep -qx 'grep-fixture/beta.ts'
GREP_GLOB="$(tool_call 3051 grep '{"pattern":"grepBeta","path":"grep-fixture","glob":"*.swift"}')"
printf '%s' "$GREP_GLOB" | extract files raw | grep -qx '1'
printf '%s' "$GREP_GLOB" | extract files.0 raw | grep -qx 'grep-fixture/alpha.swift'
GREP_FILE_PATH="$(tool_call 3052 grep '{"pattern":"grepBeta","path":"grep-fixture/beta.ts","output_mode":"content"}')"
printf '%s' "$GREP_FILE_PATH" | extract matches.0.path raw | grep -qx 'grep-fixture/beta.ts'
GREP_MULTILINE="$(tool_call 3053 grep '{"pattern":"start:.*end","path":"grep-fixture","multiline":true,"output_mode":"content"}')"
printf '%s' "$GREP_MULTILINE" | extract total raw | grep -qx '2'
printf '%s' "$GREP_MULTILINE" | extract matches.1.text raw | grep -qx '  end };'
GREP_INVALID_TYPE="$(tool_call 3054 grep '{"pattern":"x","type":"not a type"}')"
printf '%s' "$GREP_INVALID_TYPE" | plutil -extract result.isError raw -o - - | grep -qx 'true'
GREP_UNKNOWN_TYPE="$(tool_call 3055 grep '{"pattern":"x","type":"definitelynotatype"}')"
printf '%s' "$GREP_UNKNOWN_TYPE" | plutil -extract result.isError raw -o - - | grep -qx 'true'
GREP_BAD_REGEX="$(tool_call 3056 grep '{"pattern":"(unclosed"}')"
printf '%s' "$GREP_BAD_REGEX" | plutil -extract result.isError raw -o - - | grep -qx 'true'
printf '%s' "$GREP_BAD_REGEX" | grep -q 'regex parse error'
GREP_BAD_MODE="$(tool_call 3057 grep '{"pattern":"x","output_mode":"lines"}')"
printf '%s' "$GREP_BAD_MODE" | grep -q 'Argument output_mode must be one of'
GREP_OPTION_PATTERN="$(tool_call 3058 grep '{"pattern":"--pre=/usr/bin/touch","path":"grep-fixture"}')"
printf '%s' "$GREP_OPTION_PATTERN" | plutil -extract result.isError raw -o - - | grep -qx 'false'
printf '%s' "$GREP_OPTION_PATTERN" | extract total raw | grep -qx '0'
GLOB_OPTION_PATTERN="$(tool_call 3059 glob '{"pattern":"--pre=/usr/bin/touch","path":"grep-fixture"}')"
printf '%s' "$GLOB_OPTION_PATTERN" | plutil -extract result.isError raw -o - - | grep -qx 'false'
printf '%s' "$GLOB_OPTION_PATTERN" | extract total raw | grep -qx '0'
GLOB_ORDER="$(tool_call 3060 glob '{"pattern":"*.swift","path":"glob-order","head_limit":2}')"
printf '%s' "$GLOB_ORDER" | extract files raw | grep -qx '2'
printf '%s' "$GLOB_ORDER" | extract files.0 raw | grep -qx 'glob-order/newer.swift'
printf '%s' "$GLOB_ORDER" | extract files.1 raw | grep -qx 'glob-order/middle.swift'
printf '%s' "$GLOB_ORDER" | extract next_offset raw | grep -qx '2'
GLOB_CASE="$(tool_call 3064 glob '{"pattern":"*readme*","path":"case-glob"}')"
printf '%s' "$GLOB_CASE" | extract files.0 raw | grep -qx 'case-glob/ReadMe.MD'
GREP_GLOB_CASE="$(tool_call 3065 grep '{"pattern":"case-probe","path":"case-glob","glob":"*.md"}')"
printf '%s' "$GREP_GLOB_CASE" | extract total raw | grep -qx '1'
GLOB_ESCAPE="$(tool_call 3061 glob '{"pattern":"**/secret.txt"}')"
printf '%s' "$GLOB_ESCAPE" | extract total raw | grep -qx '0'
GREP_ESCAPE="$(tool_call 3062 grep '{"pattern":"must stay private","output_mode":"content"}')"
if printf '%s' "$GREP_ESCAPE" | grep -q 'secret.txt'; then
    echo "grep escaped through symlink" >&2
    exit 1
fi
echo "grep-glob: ok"

RANKED_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3017,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["QualityTarget","class QualityTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.truncated raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.truncation_reasons raw -expect array -o - - | grep -qx '0'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.files_matched raw -expect integer -o - - | grep -qx '31'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.files_ranked raw -expect integer -o - - | grep -qx '31'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '31'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.returned_matches raw -expect integer -o - - | grep -qx '1'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.result_limit_reached raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/definition.swift'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'likely_declaration'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.1.observed_matching_lines raw -expect integer -o - - | grep -qx '1'
printf '%s' "$RANKED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.1.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/definition.swift'

TYPED_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3026,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["TypedTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$TYPED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/typed-definition.swift'
printf '%s' "$TYPED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.line raw -expect integer -o - - | grep -qx '3'
printf '%s' "$TYPED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'likely_declaration'

TYPED_VALUE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3028,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["TypedValueTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$TYPED_VALUE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/typed-value.cs'
printf '%s' "$TYPED_VALUE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.line raw -expect integer -o - - | grep -qx '2'
printf '%s' "$TYPED_VALUE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'likely_declaration'

GENERIC_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3030,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["GenericTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$GENERIC_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/generic-method.cs'
printf '%s' "$GENERIC_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.line raw -expect integer -o - - | grep -qx '2'
printf '%s' "$GENERIC_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'likely_declaration'

CASE_INSENSITIVE_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3031,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["CaseTarget"],"path":"ranked-search","max_results_per_query":2}}}')"
printf '%s' "$CASE_INSENSITIVE_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '2'
printf '%s' "$CASE_INSENSITIVE_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/case-exact.swift'
printf '%s' "$CASE_INSENSITIVE_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'exact_case'

CASE_SENSITIVE_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3032,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["CaseTarget"],"path":"ranked-search","case_sensitive":true,"max_results_per_query":2}}}')"
printf '%s' "$CASE_SENSITIVE_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '1'
printf '%s' "$CASE_SENSITIVE_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/case-exact.swift'

FILENAME_SIGNAL_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3033,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["FilenameOnlyTarget","FilenameMatchTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$FILENAME_SIGNAL_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals json -o - - | grep -q 'filename_exact'
printf '%s' "$FILENAME_SIGNAL_RESULT" | plutil -extract result.structuredContent.query_results.1.matches.0.signals json -o - - | grep -q 'filename_match'

AMBIGUOUS_DECL_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3042,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["AmbiguousTypeUsage","ConstantTarget","RustStaticTarget"],"path":"ranked-search","max_results_per_query":2}}}')"
printf '%s' "$AMBIGUOUS_DECL_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'ranked-search/ambiguous-type-definition.hpp'
printf '%s' "$AMBIGUOUS_DECL_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.1.signals json -o - - | grep -vq 'likely_declaration'
printf '%s' "$AMBIGUOUS_DECL_RESULT" | plutil -extract result.structuredContent.query_results.1.matches.0.signals json -o - - | grep -q 'likely_declaration'
printf '%s' "$AMBIGUOUS_DECL_RESULT" | plutil -extract result.structuredContent.query_results.2.matches.0.signals json -o - - | grep -q 'likely_declaration'

PYTHON_COMMENT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3034,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["PythonCommentTarget","GoRawStringTarget","ShellCommentTarget","PowerShellBlockTarget","PowerShellLineTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$PYTHON_COMMENT_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$PYTHON_COMMENT_RESULT" | plutil -extract result.structuredContent.query_results.1.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$PYTHON_COMMENT_RESULT" | plutil -extract result.structuredContent.query_results.2.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$PYTHON_COMMENT_RESULT" | plutil -extract result.structuredContent.query_results.3.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$PYTHON_COMMENT_RESULT" | plutil -extract result.structuredContent.query_results.4.matches.0.signals raw -expect array -o - - | grep -qx '0'

STRING_FIXTURE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3027,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["StringOnlyTarget"],"path":"ranked-search","max_results_per_query":2}}}')"
printf '%s' "$STRING_FIXTURE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals raw -expect array -o - - | grep -qx '0'

LEXICAL_STATE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3029,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["BlockCommentTarget","NestedBlockCommentTarget","MultilineStringTarget","EscapedTarget","TemplateStringTarget"],"path":"ranked-search","max_results_per_query":2}}}')"
printf '%s' "$LEXICAL_STATE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$LEXICAL_STATE_RESULT" | plutil -extract result.structuredContent.query_results.1.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$LEXICAL_STATE_RESULT" | plutil -extract result.structuredContent.query_results.2.matches.0.signals raw -expect array -o - - | grep -qx '0'
printf '%s' "$LEXICAL_STATE_RESULT" | plutil -extract result.structuredContent.query_results.3.matches.0.signals json -o - - | grep -q 'likely_declaration'
printf '%s' "$LEXICAL_STATE_RESULT" | plutil -extract result.structuredContent.query_results.4.matches.0.signals raw -expect array -o - - | grep -qx '0'

RANKED_GENERATED_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3018,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["generated"],"max_results_per_query":1}}}')"
printf '%s' "$RANKED_GENERATED_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx '.next/generated-target.txt'

RANKED_ESCAPE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3019,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["must stay private"],"max_results_per_query":3}}}')"
printf '%s' "$RANKED_ESCAPE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '0'
if printf '%s' "$RANKED_ESCAPE_RESULT" | grep -q 'secret.txt'; then
    echo "search_code escaped through symlink" >&2
    exit 1
fi

INVALID_RANKED_QUERY="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3020,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":[123]}}}')"
printf '%s' "$INVALID_RANKED_QUERY" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$INVALID_RANKED_QUERY" | grep -q 'queries\[0\] must be a string'

SIX_RANKED_QUERIES="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3036,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["QualityTarget","TypedTarget","TypedValueTarget","GenericTarget","CaseTarget","FilenameOnlyTarget"],"path":"ranked-search","max_results_per_query":1}}}')"
printf '%s' "$SIX_RANKED_QUERIES" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$SIX_RANKED_QUERIES" | plutil -extract result.structuredContent.query_results raw -expect array -o - - | grep -qx '6'

SEVEN_RANKED_QUERIES="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3037,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["a","b","c","d","e","f","g"]}}}')"
printf '%s' "$SEVEN_RANKED_QUERIES" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$SEVEN_RANKED_QUERIES" | grep -q 'at most 6'

QUERY_500="$(printf '%0500d' 0 | tr '0' x)"
QUERY_501="${QUERY_500}x"
QUERY_500_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":3038,\"method\":\"tools/call\",\"params\":{\"name\":\"search_code\",\"arguments\":{\"queries\":[\"$QUERY_500\"],\"path\":\"ranked-search\"}}}")"
printf '%s' "$QUERY_500_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
QUERY_501_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":3039,\"method\":\"tools/call\",\"params\":{\"name\":\"search_code\",\"arguments\":{\"queries\":[\"$QUERY_501\"],\"path\":\"ranked-search\"}}}")"
printf '%s' "$QUERY_501_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$QUERY_501_RESULT" | grep -q 'longer than 500 characters'

OVERVIEW_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3021,"method":"tools/call","params":{"name":"repo_overview","arguments":{"path":"overview-project"}}}')"
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.top_level_entries json -o - - | grep -q 'package.json'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'package.json'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'Demo.xcodeproj'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'EmptyProject.xcodeproj'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.manifests json -o - - | grep -q 'EmptyWorkspace.xcworkspace'
OVERVIEW_DIRECTORIES="$(printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.directories_seen raw -expect integer -o - -)"
test "$OVERVIEW_DIRECTORIES" -ge 6
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.default_excluded_directory_names json -o - - | grep -q 'node_modules'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.file_extensions.0.extension raw -expect string -o - - | grep -qx '.ts'
printf '%s' "$OVERVIEW_RESULT" | plutil -extract result.structuredContent.file_extensions.0.count raw -expect integer -o - - | grep -qx '2'
if printf '%s' "$OVERVIEW_RESULT" | grep -q 'node_modules/ignored/package.json'; then
    echo "repo_overview traversed an excluded dependency directory" >&2
    exit 1
fi

XCODE_CONTENT_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3040,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["project-marker"],"path":"overview-project","max_results_per_query":2}}}')"
printf '%s' "$XCODE_CONTENT_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '1'
printf '%s' "$XCODE_CONTENT_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'overview-project/Demo.xcodeproj/project.pbxproj'
XCODE_FILENAME_RESULT="$(tool_call 3041 glob '{"pattern":"project.pbxproj","path":"overview-project"}')"
printf '%s' "$XCODE_FILENAME_RESULT" | extract files.0 raw | grep -qx 'overview-project/Demo.xcodeproj/project.pbxproj'

BROAD_EXCLUDED_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3023,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["hidden"],"path":"overview-project","max_results_per_query":2}}}')"
printf '%s' "$BROAD_EXCLUDED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '0'
printf '%s' "$BROAD_EXCLUDED_CODE_RESULT" | plutil -extract result.structuredContent.default_excluded_directory_names json -o - - | grep -q 'node_modules'

CASE_EXCLUDED_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3035,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["case-hidden"],"path":"case-exclusion-project","max_results_per_query":2}}}')"
printf '%s' "$CASE_EXCLUDED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '0'

EXPLICIT_EXCLUDED_CODE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3024,"method":"tools/call","params":{"name":"search_code","arguments":{"queries":["hidden"],"path":"overview-project/node_modules","max_results_per_query":2}}}')"
printf '%s' "$EXPLICIT_EXCLUDED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.observed_matching_lines raw -expect integer -o - - | grep -qx '1'
printf '%s' "$EXPLICIT_EXCLUDED_CODE_RESULT" | plutil -extract result.structuredContent.query_results.0.matches.0.path raw -expect string -o - - | grep -qx 'overview-project/node_modules/ignored/hidden.ts'

EXPLICIT_EXCLUDED_OVERVIEW_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3025,"method":"tools/call","params":{"name":"repo_overview","arguments":{"path":"overview-project/node_modules"}}}')"
printf '%s' "$EXPLICIT_EXCLUDED_OVERVIEW_RESULT" | plutil -extract result.structuredContent.manifests.0 raw -expect string -o - - | grep -qx 'overview-project/node_modules/ignored/package.json'

ROOT_OVERVIEW_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":3022,"method":"tools/call","params":{"name":"repo_overview","arguments":{}}}')"
if printf '%s' "$ROOT_OVERVIEW_RESULT" | grep -q 'escape/package.json'; then
    echo "repo_overview escaped through symlink" >&2
    exit 1
fi

GLOB_LIMIT_RESULT="$(tool_call 306 glob '{"pattern":"filename-target-*","head_limit":1000}')"
printf '%s' "$GLOB_LIMIT_RESULT" | extract files raw | grep -qx '205'
GLOB_PAGE_RESULT="$(tool_call 3063 glob '{"pattern":"filename-target-*","head_limit":200}')"
printf '%s' "$GLOB_PAGE_RESULT" | extract files raw | grep -qx '200'
printf '%s' "$GLOB_PAGE_RESULT" | extract truncated raw | grep -qx 'true'
printf '%s' "$GLOB_PAGE_RESULT" | extract total raw | grep -qx '205'

EMPTY_GLOB_QUERY="$(tool_call 307 glob '{"pattern":""}')"
printf '%s' "$EMPTY_GLOB_QUERY" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$EMPTY_GLOB_QUERY" | grep -q 'pattern must be 1...500 characters'

INVALID_OPTIONAL_TYPE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":302,"method":"tools/call","params":{"name":"list_files","arguments":{"subpath":123}}}')"
printf '%s' "$INVALID_OPTIONAL_TYPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$INVALID_OPTIONAL_TYPE" | grep -q 'Missing or invalid argument: subpath'

UNKNOWN_ARGUMENT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":303,"method":"tools/call","params":{"name":"read_file","arguments":{"relative_path":"hello.txt","surprise":true}}}')"
printf '%s' "$UNKNOWN_ARGUMENT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$UNKNOWN_ARGUMENT" | grep -q 'Unexpected argument: surprise'

NON_OBJECT_ARGUMENTS="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":304,"method":"tools/call","params":{"name":"read_file","arguments":[]}}')"
printf '%s' "$NON_OBJECT_ARGUMENTS" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$NON_OBJECT_ARGUMENTS" | grep -q 'Invalid arguments: expected an object'

OUT_OF_RANGE_OPTIONAL="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":305,"method":"tools/call","params":{"name":"grep","arguments":{"pattern":"needle","context":11}}}')"
printf '%s' "$OUT_OF_RANGE_OPTIONAL" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$OUT_OF_RANGE_OPTIONAL" | grep -q 'Argument context must be &lt;= 10\|Argument context must be <= 10'

SEARCH_RESULT="$(tool_call 33 grep '{"pattern":"needle-target","fixed_strings":true,"output_mode":"content","context":1}')"
printf '%s' "$SEARCH_RESULT" | extract matches.0.path raw | grep -qx 'sample.swift'
printf '%s' "$SEARCH_RESULT" | extract matches.0.line raw | grep -qx '4'
printf '%s' "$SEARCH_RESULT" | extract matches.0.before.0.text raw | grep -qx 'func alpha() {'
printf '%s' "$SEARCH_RESULT" | extract truncation_reasons raw | grep -qx '0'

CRLF_SEARCH="$(tool_call 332 grep '{"pattern":"needle-crlf","output_mode":"content","context":1}')"
printf '%s' "$CRLF_SEARCH" | extract matches.0.path raw | grep -qx 'crlf.txt'
printf '%s' "$CRLF_SEARCH" | extract matches.0.line raw | grep -qx '3'
printf '%s' "$CRLF_SEARCH" | extract matches.0.text raw | grep -qx 'needle-crlf'
printf '%s' "$CRLF_SEARCH" | extract matches.0.before.0.line raw | grep -qx '2'

CRLF_RANGE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":333,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"crlf.txt","start_line":2,"end_line":3}}}')"
printf '%s' "$CRLF_RANGE" | sed 's/\\"/"/g' | grep -q '"total_lines" : 4'
printf '%s' "$CRLF_RANGE" | sed 's/\\"/"/g' | grep -q '"end_line" : 3'
printf '%s' "$CRLF_RANGE" | grep -q 'line-two'
printf '%s' "$CRLF_RANGE" | grep -q 'needle-crlf'

RANGE_MISSING_START="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":334,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"sample.swift","end_line":7}}}')"
printf '%s' "$RANGE_MISSING_START" | grep -q '"isError":true'
printf '%s' "$RANGE_MISSING_START" | grep -q 'Missing or invalid argument: start_line'

RANGE_FRACTIONAL_START="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":337,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"sample.swift","start_line":1.5,"end_line":7}}}')"
printf '%s' "$RANGE_FRACTIONAL_START" | grep -q '"isError":true'
printf '%s' "$RANGE_FRACTIONAL_START" | grep -q 'Missing or invalid argument: start_line'

BINARY_SCAN="$(tool_call 335 grep '{"pattern":"A","path":"binary-only"}')"
printf '%s' "$BINARY_SCAN" | extract total raw | grep -qx '0'
printf '%s' "$BINARY_SCAN" | extract default_excluded_directory_names json | grep -q 'node_modules'

EOF_RANGE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":336,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"trailing-newline.txt","start_line":1,"end_line":2}}}')"
printf '%s' "$EOF_RANGE" | sed 's/\\"/"/g' | grep -q '"total_lines" : 2'
printf '%s' "$EOF_RANGE" | grep -q 'has_after.*false'
printf '%s' "$EOF_RANGE" | grep -q 'truncated.*false'
printf '%s' "$EOF_RANGE" | grep -q 'second'

RANGE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":34,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"sample.swift","start_line":3,"end_line":7}}}')"
printf '%s' "$RANGE_RESULT" | grep -q 'start_line.*3'
printf '%s' "$RANGE_RESULT" | grep -q 'end_line.*7'
printf '%s' "$RANGE_RESULT" | grep -q 'has_before.*true'
printf '%s' "$RANGE_RESULT" | grep -q 'needle-target'
printf '%s' "$RANGE_RESULT" | grep -q 'func beta'
printf '%s' "$RANGE_RESULT" | plutil -extract result.structuredContent.start_line raw -expect integer -o - - | grep -qx '3'
printf '%s' "$RANGE_RESULT" | plutil -extract result.structuredContent.end_line raw -expect integer -o - - | grep -qx '7'


BATCH_READ_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":342,"method":"tools/call","params":{"name":"batch_read","arguments":{"operations":[{"tool":"read_file","arguments":{"relative_path":"hello.txt"}},{"tool":"read_file_range","arguments":{"relative_path":"sample.swift","start_line":3,"end_line":5}},{"tool":"glob","arguments":{"pattern":"scoped-target*","path":"scope-a"}},{"tool":"search_code","arguments":{"queries":["TypedTarget"],"path":"ranked-search","max_results_per_query":1}},{"tool":"repo_overview","arguments":{"path":"overview-project"}}]}}}')"
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.requested raw -expect integer -o - - | grep -qx '5'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.completed raw -expect integer -o - - | grep -qx '5'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.succeeded raw -expect integer -o - - | grep -qx '5'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.failed raw -expect integer -o - - | grep -qx '0'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.results.0.structured_content.result raw -expect string -o - - | grep -qx 'hello swift'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.results.2.structured_content.files.0 raw -expect string -o - - | grep -qx 'scope-a/scoped-target.txt'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.results.3.structured_content.query_results.0.matches.0.line raw -expect integer -o - - | grep -qx '3'
printf '%s' "$BATCH_READ_RESULT" | plutil -extract result.structuredContent.results.4.structured_content.manifests json -o - - | grep -q 'package.json'

BATCH_READ_REJECT_WRITE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":343,"method":"tools/call","params":{"name":"batch_read","arguments":{"stop_on_error":true,"operations":[{"tool":"write_file","arguments":{"relative_path":"should-not-exist.txt","content":"no"}},{"tool":"read_file","arguments":{"relative_path":"hello.txt"}}]}}}')"
printf '%s' "$BATCH_READ_REJECT_WRITE" | plutil -extract result.structuredContent.completed raw -expect integer -o - - | grep -qx '1'
printf '%s' "$BATCH_READ_REJECT_WRITE" | plutil -extract result.structuredContent.succeeded raw -expect integer -o - - | grep -qx '0'
printf '%s' "$BATCH_READ_REJECT_WRITE" | plutil -extract result.structuredContent.failed raw -expect integer -o - - | grep -qx '1'
printf '%s' "$BATCH_READ_REJECT_WRITE" | plutil -extract result.structuredContent.stopped_on_error raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$BATCH_READ_REJECT_WRITE" | plutil -extract result.structuredContent.results.0.ok raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$BATCH_READ_REJECT_WRITE" | grep -q 'batch_read does not allow tool: write_file'
[ ! -e "$SERVER_ROOT/should-not-exist.txt" ]


BATCH_READ_CONTINUE_AFTER_ERROR="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":344,"method":"tools/call","params":{"name":"batch_read","arguments":{"operations":[{"tool":"write_file","arguments":{"relative_path":"still-should-not-exist.txt","content":"no"}},{"tool":"read_file","arguments":{"relative_path":"hello.txt"}}]}}}')"
printf '%s' "$BATCH_READ_CONTINUE_AFTER_ERROR" | plutil -extract result.structuredContent.completed raw -expect integer -o - - | grep -qx '2'
printf '%s' "$BATCH_READ_CONTINUE_AFTER_ERROR" | plutil -extract result.structuredContent.succeeded raw -expect integer -o - - | grep -qx '1'
printf '%s' "$BATCH_READ_CONTINUE_AFTER_ERROR" | plutil -extract result.structuredContent.failed raw -expect integer -o - - | grep -qx '1'
printf '%s' "$BATCH_READ_CONTINUE_AFTER_ERROR" | plutil -extract result.structuredContent.stopped_on_error raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$BATCH_READ_CONTINUE_AFTER_ERROR" | plutil -extract result.structuredContent.results.1.structured_content.result raw -expect string -o - - | grep -qx 'hello swift'
[ ! -e "$SERVER_ROOT/still-should-not-exist.txt" ]

BATCH_OPERATION='{"tool":"read_file","arguments":{"relative_path":"hello.txt"}}'
BATCH_MAX_OPS=""
for index in $(seq 1 16); do
    if [ -n "$BATCH_MAX_OPS" ]; then BATCH_MAX_OPS="$BATCH_MAX_OPS,$BATCH_OPERATION"; else BATCH_MAX_OPS="$BATCH_OPERATION"; fi
done
BATCH_MAX_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":345,\"method\":\"tools/call\",\"params\":{\"name\":\"batch_read\",\"arguments\":{\"operations\":[$BATCH_MAX_OPS]}}}")"
printf '%s' "$BATCH_MAX_RESULT" | plutil -extract result.structuredContent.requested raw -expect integer -o - - | grep -qx '16'
printf '%s' "$BATCH_MAX_RESULT" | plutil -extract result.structuredContent.succeeded raw -expect integer -o - - | grep -qx '16'
BATCH_TOO_MANY_RESULT="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":346,\"method\":\"tools/call\",\"params\":{\"name\":\"batch_read\",\"arguments\":{\"operations\":[$BATCH_MAX_OPS,$BATCH_OPERATION]}}}")"
printf '%s' "$BATCH_TOO_MANY_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$BATCH_TOO_MANY_RESULT" | grep -q 'at most 16'

RANGE_LIMIT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":341,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"large-range.txt","start_line":1,"end_line":1000}}}')"
printf '%s' "$RANGE_LIMIT_RESULT" | sed 's/\\"/"/g' | grep -q '"end_line" : 398'
printf '%s' "$RANGE_LIMIT_RESULT" | grep -q 'truncated.*true'
printf '%s' "$RANGE_LIMIT_RESULT" | grep -q 'has_after.*true'
printf '%s' "$RANGE_LIMIT_RESULT" | grep -q 'LINE-0398'
if printf '%s' "$RANGE_LIMIT_RESULT" | grep -q 'LINE-0399'; then
    echo "read_file_range returned a partial line past end_line" >&2
    exit 1
fi

RANGE_CONTINUATION="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":342,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"large-range.txt","start_line":399,"end_line":1000}}}')"
printf '%s' "$RANGE_CONTINUATION" | sed 's/\\"/"/g' | grep -q '"start_line" : 399'
printf '%s' "$RANGE_CONTINUATION" | grep -q 'LINE-0399'

LONG_LINE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":338,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"long-line.txt","start_line":1,"end_line":1}}}')"
printf '%s' "$LONG_LINE_RESULT" | grep -q '"isError":true'
printf '%s' "$LONG_LINE_RESULT" | grep -q '80,000 character response limit'

LONG_READ_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":339,"method":"tools/call","params":{"name":"read_file","arguments":{"relative_path":"long-line.txt"}}}')"
printf '%s' "$LONG_READ_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$LONG_READ_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -q '\[\.\.\.truncated\.\.\.\]'

LINE_LIMIT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":339,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"many-lines.txt","start_line":1,"end_line":1200}}}')"
printf '%s' "$LINE_LIMIT_RESULT" | sed 's/\\"/"/g' | grep -q '"end_line" : 1000'
printf '%s' "$LINE_LIMIT_RESULT" | grep -q 'truncated.*true'
printf '%s' "$LINE_LIMIT_RESULT" | grep -q 'has_after.*true'
printf '%s' "$LINE_LIMIT_RESULT" | grep -q 'SHORT-1000'
if printf '%s' "$LINE_LIMIT_RESULT" | grep -q 'SHORT-1001'; then
    echo "read_file_range exceeded the 1000-line cap" >&2
    exit 1
fi

LINE_LIMIT_CONTINUATION="$(curl -fsS -X POST "$BASE_URL" -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":340,"method":"tools/call","params":{"name":"read_file_range","arguments":{"relative_path":"many-lines.txt","start_line":1001,"end_line":1200}}}')"
printf '%s' "$LINE_LIMIT_CONTINUATION" | grep -q 'SHORT-1001'

ESCAPE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":31,"method":"tools/call","params":{"name":"read_file","arguments":{"relative_path":"escape/secret.txt"}}}')"
printf '%s' "$ESCAPE_RESULT" | grep -q '"isError":true'
printf '%s' "$ESCAPE_RESULT" | grep -q 'outside the shared directory'

WRITE_ESCAPE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"write_file","arguments":{"relative_path":"escape/new.txt","content":"blocked"}}}')"
printf '%s' "$WRITE_ESCAPE" | grep -q '"isError":true'
printf '%s' "$WRITE_ESCAPE" | grep -q 'outside the shared directory'

DELETE_FILE_LINK="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":321,"method":"tools/call","params":{"name":"delete_file","arguments":{"relative_path":"delete-file-link"}}}')"
printf '%s' "$DELETE_FILE_LINK" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
[ -f "$SERVER_ROOT/delete-target.txt" ]
[ ! -L "$SERVER_ROOT/delete-file-link" ]

DELETE_DIR_LINK="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":322,"method":"tools/call","params":{"name":"delete_directory","arguments":{"relative_path":"delete-dir-link"}}}')"
printf '%s' "$DELETE_DIR_LINK" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$DELETE_DIR_LINK" | grep -q 'Use delete_file for symlinks'
[ -d "$SERVER_ROOT/delete-target-dir" ]
[ -L "$SERVER_ROOT/delete-dir-link" ]

DELETE_DIR_LINK_AS_FILE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":323,"method":"tools/call","params":{"name":"delete_file","arguments":{"relative_path":"delete-dir-link"}}}')"
printf '%s' "$DELETE_DIR_LINK_AS_FILE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
[ -d "$SERVER_ROOT/delete-target-dir" ]
[ ! -L "$SERVER_ROOT/delete-dir-link" ]

DELETE_OUTSIDE_LINK="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":324,"method":"tools/call","params":{"name":"delete_file","arguments":{"relative_path":"delete-outside-link"}}}')"
printf '%s' "$DELETE_OUTSIDE_LINK" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
[ -f "${TMPDIR%/}/filemcp-server-outside/secret.txt" ]
[ ! -L "$SERVER_ROOT/delete-outside-link" ]

echo "symlink-delete-semantics: ok"

GIT_INIT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":400,"method":"tools/call","params":{"name":"git_init","arguments":{"repo_path":"git-fixture"}}}')"
printf '%s' "$GIT_INIT_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$GIT_INIT_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -qx 'Initialized Git repository: git-fixture'
if printf '%s' "$GIT_INIT_RESULT" | grep -q "$SERVER_ROOT"; then
    echo "git_init leaked the absolute shared-root path" >&2
    exit 1
fi

printf 'first\n' > "$TMP_DIR/git-content.txt"
GIT_WRITE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":401,"method":"tools/call","params":{"name":"write_file","arguments":{"relative_path":"git-fixture/file with space.txt","content":"first\n"}}}')"
printf '%s' "$GIT_WRITE_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'

GIT_ADD_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":402,"method":"tools/call","params":{"name":"git_add","arguments":{"repo_path":"git-fixture","paths":"file with space.txt"}}}')"
printf '%s' "$GIT_ADD_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$GIT_ADD_RESULT" | grep -q 'Staged: file with space.txt'

GIT_COMMIT_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":403,"method":"tools/call","params":{"name":"git_commit","arguments":{"repo_path":"git-fixture","message":"initial fixture"}}}')"
printf '%s' "$GIT_COMMIT_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'

GIT_STATUS_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":404,"method":"tools/call","params":{"name":"git_status","arguments":{"repo_path":"git-fixture"}}}')"
printf '%s' "$GIT_STATUS_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -qx '(working tree clean)'

GIT_LOG_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":405,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"git-fixture","count":1}}}')"
printf '%s' "$GIT_LOG_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -q 'initial fixture'

GIT_UPDATE_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":406,"method":"tools/call","params":{"name":"write_file","arguments":{"relative_path":"git-fixture/file with space.txt","content":"second\n"}}}')"
printf '%s' "$GIT_UPDATE_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'

GIT_DIFF_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":407,"method":"tools/call","params":{"name":"git_diff","arguments":{"repo_path":"git-fixture","paths":"\"file with space.txt\""}}}')"
printf '%s' "$GIT_DIFF_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$GIT_DIFF_RESULT" | grep -q -- '-first'
printf '%s' "$GIT_DIFF_RESULT" | grep -q -- '+second'

GIT_BAD_QUOTE="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":408,"method":"tools/call","params":{"name":"git_diff","arguments":{"repo_path":"git-fixture","paths":"\"unterminated"}}}')"
printf '%s' "$GIT_BAD_QUOTE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$GIT_BAD_QUOTE" | grep -q 'Unterminated quote in Git paths'

SAFE_INIT_RESULT="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":409,"method":"tools/call","params":{"name":"git_init","arguments":{"repo_path":"safe-init-template"}}}')"
printf '%s' "$SAFE_INIT_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
if [ -e "$SERVER_ROOT/safe-init-template/.git/copied-from-template" ]; then
    echo "git_init copied an external Git template while command execution was disabled" >&2
    exit 1
fi

echo "git-tools-integration: ok"

SAFE_HOOK_REPO="$SERVER_ROOT/safe-hook-repo"
mkdir -p "$SAFE_HOOK_REPO"
git -C "$SAFE_HOOK_REPO" init -q -b main
printf 'one\n' > "$SAFE_HOOK_REPO/hook.txt"
git -C "$SAFE_HOOK_REPO" add hook.txt
git -C "$SAFE_HOOK_REPO" -c user.name=test -c user.email=test@example.com commit -qm initial
printf 'two\n' >> "$SAFE_HOOK_REPO/hook.txt"
git -C "$SAFE_HOOK_REPO" add hook.txt
HOOK_MARKER="$TMP_DIR/pre-commit-ran"
cat > "$SAFE_HOOK_REPO/.git/hooks/pre-commit" <<EOF
#!/bin/sh
printf hook > '$HOOK_MARKER'
EOF
chmod +x "$SAFE_HOOK_REPO/.git/hooks/pre-commit"
SAFE_COMMIT="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":410,"method":"tools/call","params":{"name":"git_commit","arguments":{"repo_path":"safe-hook-repo","message":"safe commit"}}}')"
printf '%s' "$SAFE_COMMIT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
if [ -e "$HOOK_MARKER" ]; then
    echo "git_commit executed a repository hook while command execution was disabled" >&2
    exit 1
fi

SAFE_FILTER_REPO="$SERVER_ROOT/safe-filter-repo"
mkdir -p "$SAFE_FILTER_REPO"
git -C "$SAFE_FILTER_REPO" init -q -b main
FILTER_MARKER="$TMP_DIR/filter-ran"
FILTER_SCRIPT="$TMP_DIR/filter-command.sh"
cat > "$FILTER_SCRIPT" <<EOF
#!/bin/sh
cat
printf filter > '$FILTER_MARKER'
EOF
chmod +x "$FILTER_SCRIPT"
git -C "$SAFE_FILTER_REPO" config filter.audit.clean "$FILTER_SCRIPT"
git -C "$SAFE_FILTER_REPO" config filter.audit.smudge cat
printf '*.txt filter=audit\n' > "$SAFE_FILTER_REPO/.gitattributes"
printf 'filtered\n' > "$SAFE_FILTER_REPO/filtered.txt"
SAFE_ADD_FILTER="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":411,"method":"tools/call","params":{"name":"git_add","arguments":{"repo_path":"safe-filter-repo","paths":"filtered.txt"}}}')"
printf '%s' "$SAFE_ADD_FILTER" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$SAFE_ADD_FILTER" | grep -q 'uses Git content filter'
if [ -e "$FILTER_MARKER" ]; then
    echo "git_add executed a content filter while command execution was disabled" >&2
    exit 1
fi

SAFE_DIFF_REPO="$SERVER_ROOT/safe-diff-repo"
mkdir -p "$SAFE_DIFF_REPO"
git -C "$SAFE_DIFF_REPO" init -q -b main
printf 'before\n' > "$SAFE_DIFF_REPO/diff.txt"
git -C "$SAFE_DIFF_REPO" add diff.txt
git -C "$SAFE_DIFF_REPO" -c user.name=test -c user.email=test@example.com commit -qm initial
printf 'after\n' > "$SAFE_DIFF_REPO/diff.txt"
DIFF_MARKER="$TMP_DIR/external-diff-ran"
DIFF_SCRIPT="$TMP_DIR/external-diff.sh"
cat > "$DIFF_SCRIPT" <<EOF
#!/bin/sh
printf diff > '$DIFF_MARKER'
EOF
chmod +x "$DIFF_SCRIPT"
git -C "$SAFE_DIFF_REPO" config diff.external "$DIFF_SCRIPT"
SAFE_DIFF="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":412,"method":"tools/call","params":{"name":"git_diff","arguments":{"repo_path":"safe-diff-repo"}}}')"
printf '%s' "$SAFE_DIFF" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$SAFE_DIFF" | grep -q -- '-before'
printf '%s' "$SAFE_DIFF" | grep -q -- '+after'
if [ -e "$DIFF_MARKER" ]; then
    echo "git_diff executed an external diff command while command execution was disabled" >&2
    exit 1
fi

OUTSIDE_WORKTREE="$TMP_DIR/outside-worktree"
SAFE_ESCAPE_REPO="$SERVER_ROOT/safe-worktree-escape"
mkdir -p "$SAFE_ESCAPE_REPO" "$OUTSIDE_WORKTREE"
git -C "$SAFE_ESCAPE_REPO" init -q -b main
printf 'inside\n' > "$SAFE_ESCAPE_REPO/escape.txt"
git -C "$SAFE_ESCAPE_REPO" add escape.txt
git -C "$SAFE_ESCAPE_REPO" -c user.name=test -c user.email=test@example.com commit -qm initial
cp "$SAFE_ESCAPE_REPO/escape.txt" "$OUTSIDE_WORKTREE/escape.txt"
git -C "$SAFE_ESCAPE_REPO" config core.worktree "$OUTSIDE_WORKTREE"
printf 'outside-worktree-secret\n' > "$OUTSIDE_WORKTREE/escape.txt"
WORKTREE_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":413,"method":"tools/call","params":{"name":"git_diff","arguments":{"repo_path":"safe-worktree-escape","paths":"escape.txt"}}}')"
printf '%s' "$WORKTREE_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$WORKTREE_ESCAPE" | grep -q 'Git worktree is outside or different'
if printf '%s' "$WORKTREE_ESCAPE" | grep -q 'outside-worktree-secret'; then
    echo "git_diff leaked content from an out-of-root core.worktree" >&2
    exit 1
fi

OUTSIDE_GITDIR="$TMP_DIR/outside-gitdir"
mkdir -p "$OUTSIDE_GITDIR/source" "$SERVER_ROOT/safe-gitdir-escape"
git -C "$OUTSIDE_GITDIR/source" init -q -b main
printf 'history-secret\n' > "$OUTSIDE_GITDIR/source/history.txt"
git -C "$OUTSIDE_GITDIR/source" add history.txt
git -C "$OUTSIDE_GITDIR/source" -c user.name=test -c user.email=test@example.com commit -qm outside-history-secret
printf 'gitdir: %s/.git\n' "$OUTSIDE_GITDIR/source" > "$SERVER_ROOT/safe-gitdir-escape/.git"
GITDIR_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":414,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"safe-gitdir-escape"}}}')"
printf '%s' "$GITDIR_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$GITDIR_ESCAPE" | grep -q 'Git directory is outside the shared directory'
if printf '%s' "$GITDIR_ESCAPE" | grep -q 'outside-history-secret'; then
    echo "git_log leaked history from an out-of-root gitdir" >&2
    exit 1
fi

SAFE_EMBEDDED_REPO="$SERVER_ROOT/safe-embedded-repo"
mkdir -p "$SAFE_EMBEDDED_REPO/nested"
git -C "$SAFE_EMBEDDED_REPO" init -q -b main
printf 'gitdir: %s/.git\n' "$OUTSIDE_GITDIR/source" > "$SAFE_EMBEDDED_REPO/nested/.git"
EMBEDDED_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":426,"method":"tools/call","params":{"name":"git_add","arguments":{"repo_path":"safe-embedded-repo","paths":"nested"}}}')"
printf '%s' "$EMBEDDED_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$EMBEDDED_ESCAPE" | grep -q 'Git directory is outside the shared directory'

SAFE_ALTERNATE_REPO="$SERVER_ROOT/safe-alternate-escape"
mkdir -p "$SAFE_ALTERNATE_REPO"
git -C "$SAFE_ALTERNATE_REPO" init -q -b main
mkdir -p "$SAFE_ALTERNATE_REPO/.git/objects/info"
printf '%s/.git/objects\n' "$OUTSIDE_GITDIR/source" > "$SAFE_ALTERNATE_REPO/.git/objects/info/alternates"
ALTERNATE_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":415,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"safe-alternate-escape"}}}')"
printf '%s' "$ALTERNATE_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$ALTERNATE_ESCAPE" | grep -q 'alternate object directory is outside the shared directory'

SAFE_QUOTED_ALTERNATE_REPO="$SERVER_ROOT/safe-quoted-alternate-escape"
mkdir -p "$SAFE_QUOTED_ALTERNATE_REPO"
git -C "$SAFE_QUOTED_ALTERNATE_REPO" init -q -b main
mkdir -p "$SAFE_QUOTED_ALTERNATE_REPO/.git/objects/info"
printf '"%s/.git/objects"\n' "$OUTSIDE_GITDIR/source" > "$SAFE_QUOTED_ALTERNATE_REPO/.git/objects/info/alternates"
QUOTED_ALTERNATE_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":419,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"safe-quoted-alternate-escape"}}}')"
printf '%s' "$QUOTED_ALTERNATE_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$QUOTED_ALTERNATE_ESCAPE" | grep -q 'quoted Git alternate object paths are not supported safely'

SAFE_ALTERNATES_METADATA_REPO="$SERVER_ROOT/safe-alternates-metadata-escape"
mkdir -p "$SAFE_ALTERNATES_METADATA_REPO"
git -C "$SAFE_ALTERNATES_METADATA_REPO" init -q -b main
OUTSIDE_ALTERNATES_INFO="$TMP_DIR/outside-alternates-info"
mkdir -p "$OUTSIDE_ALTERNATES_INFO"
printf '%s/.git/objects\n' "$OUTSIDE_GITDIR/source" > "$OUTSIDE_ALTERNATES_INFO/alternates"
rm -rf "$SAFE_ALTERNATES_METADATA_REPO/.git/objects/info"
ln -s "$OUTSIDE_ALTERNATES_INFO" "$SAFE_ALTERNATES_METADATA_REPO/.git/objects/info"
ALTERNATES_METADATA_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":420,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"safe-alternates-metadata-escape"}}}')"
printf '%s' "$ALTERNATES_METADATA_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$ALTERNATES_METADATA_ESCAPE" | grep -q 'Git alternates metadata is outside the shared directory'

SAFE_FSMONITOR_REPO="$SERVER_ROOT/safe-fsmonitor-repo"
mkdir -p "$SAFE_FSMONITOR_REPO"
git -C "$SAFE_FSMONITOR_REPO" init -q -b main
printf 'tracked\n' > "$SAFE_FSMONITOR_REPO/tracked.txt"
git -C "$SAFE_FSMONITOR_REPO" add tracked.txt
git -C "$SAFE_FSMONITOR_REPO" -c user.name=test -c user.email=test@example.com commit -qm initial
FSMONITOR_MARKER="$TMP_DIR/fsmonitor-ran"
FSMONITOR_SCRIPT="$TMP_DIR/fsmonitor.sh"
cat > "$FSMONITOR_SCRIPT" <<EOF
#!/bin/sh
printf fsmonitor > '$FSMONITOR_MARKER'
exit 0
EOF
chmod +x "$FSMONITOR_SCRIPT"
git -C "$SAFE_FSMONITOR_REPO" config core.fsmonitor "$FSMONITOR_SCRIPT"
SAFE_STATUS="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":416,"method":"tools/call","params":{"name":"git_status","arguments":{"repo_path":"safe-fsmonitor-repo"}}}')"
printf '%s' "$SAFE_STATUS" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
if [ -e "$FSMONITOR_MARKER" ]; then
    echo "git_status executed core.fsmonitor while command execution was disabled" >&2
    exit 1
fi

SAFE_CONFIG_SYMLINK_REPO="$SERVER_ROOT/safe-config-symlink"
mkdir -p "$SAFE_CONFIG_SYMLINK_REPO"
git -C "$SAFE_CONFIG_SYMLINK_REPO" init -q -b main
cp "$SAFE_CONFIG_SYMLINK_REPO/.git/config" "$TMP_DIR/outside-repo-config"
rm "$SAFE_CONFIG_SYMLINK_REPO/.git/config"
ln -s "$TMP_DIR/outside-repo-config" "$SAFE_CONFIG_SYMLINK_REPO/.git/config"
CONFIG_SYMLINK_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":425,"method":"tools/call","params":{"name":"git_status","arguments":{"repo_path":"safe-config-symlink"}}}')"
printf '%s' "$CONFIG_SYMLINK_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$CONFIG_SYMLINK_ESCAPE" | grep -q 'Git config metadata is outside the shared directory'

SAFE_CONFIG_INCLUDE_REPO="$SERVER_ROOT/safe-config-include"
mkdir -p "$SAFE_CONFIG_INCLUDE_REPO"
git -C "$SAFE_CONFIG_INCLUDE_REPO" init -q -b main
printf '[core]\n\tworktree = %s\n' "$OUTSIDE_WORKTREE" > "$TMP_DIR/outside-git-config"
git -C "$SAFE_CONFIG_INCLUDE_REPO" config include.path "$TMP_DIR/outside-git-config"
CONFIG_INCLUDE_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":423,"method":"tools/call","params":{"name":"git_status","arguments":{"repo_path":"safe-config-include"}}}')"
printf '%s' "$CONFIG_INCLUDE_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$CONFIG_INCLUDE_ESCAPE" | grep -q 'Git repository config includes are not allowed'

SAFE_GIT_SYMLINK_REPO="$SERVER_ROOT/safe-git-symlink"
mkdir -p "$SAFE_GIT_SYMLINK_REPO"
ln -s "$OUTSIDE_GITDIR/source/.git" "$SAFE_GIT_SYMLINK_REPO/.git"
GIT_SYMLINK_ESCAPE="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":424,"method":"tools/call","params":{"name":"git_log","arguments":{"repo_path":"safe-git-symlink"}}}')"
printf '%s' "$GIT_SYMLINK_ESCAPE" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$GIT_SYMLINK_ESCAPE" | grep -q '.git must be a directory or a regular gitdir metadata file'

SAFE_WORKTREE_MAIN="$SERVER_ROOT/safe-worktree-main"
SAFE_LINKED_WORKTREE="$SERVER_ROOT/safe-linked-worktree"
mkdir -p "$SAFE_WORKTREE_MAIN"
git -C "$SAFE_WORKTREE_MAIN" init -q -b main
printf 'linked\n' > "$SAFE_WORKTREE_MAIN/linked.txt"
git -C "$SAFE_WORKTREE_MAIN" add linked.txt
git -C "$SAFE_WORKTREE_MAIN" -c user.name=test -c user.email=test@example.com commit -qm initial
git -C "$SAFE_WORKTREE_MAIN" worktree add -q -b linked-branch "$SAFE_LINKED_WORKTREE"
LINKED_WORKTREE_STATUS="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":417,"method":"tools/call","params":{"name":"git_status","arguments":{"repo_path":"safe-linked-worktree"}}}')"
printf '%s' "$LINKED_WORKTREE_STATUS" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$LINKED_WORKTREE_STATUS" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -qx '(working tree clean)'

SAFE_CREDENTIAL_REPO="$SERVER_ROOT/safe-credential-config"
mkdir -p "$SAFE_CREDENTIAL_REPO"
git -C "$SAFE_CREDENTIAL_REPO" init -q -b main
git -C "$SAFE_CREDENTIAL_REPO" config credential.helper '!printf unsafe-helper'
CREDENTIAL_CONFIG_RESULT="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":421,"method":"tools/call","params":{"name":"git_push","arguments":{"repo_path":"safe-credential-config"}}}')"
printf '%s' "$CREDENTIAL_CONFIG_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$CREDENTIAL_CONFIG_RESULT" | grep -q 'repository-local credential helper'

SAFE_COOKIE_REPO="$SERVER_ROOT/safe-cookie-config"
mkdir -p "$SAFE_COOKIE_REPO"
git -C "$SAFE_COOKIE_REPO" init -q -b main
printf 'secret-cookie-data\n' > "$TMP_DIR/outside.cookies"
git -C "$SAFE_COOKIE_REPO" config http.cookieFile "$TMP_DIR/outside.cookies"
COOKIE_CONFIG_RESULT="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":422,"method":"tools/call","params":{"name":"git_push","arguments":{"repo_path":"safe-cookie-config"}}}')"
printf '%s' "$COOKIE_CONFIG_RESULT" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$COOKIE_CONFIG_RESULT" | grep -q "repository-controlled HTTP file setting 'http.cookiefile'"

OUTSIDE_BARE="$TMP_DIR/outside-push.git"
git init -q --bare "$OUTSIDE_BARE"
SAFE_PUSH_REPO="$SERVER_ROOT/safe-push-repo"
mkdir -p "$SAFE_PUSH_REPO"
git -C "$SAFE_PUSH_REPO" init -q -b main
printf 'push\n' > "$SAFE_PUSH_REPO/push.txt"
git -C "$SAFE_PUSH_REPO" add push.txt
git -C "$SAFE_PUSH_REPO" -c user.name=test -c user.email=test@example.com commit -qm initial
git -C "$SAFE_PUSH_REPO" remote add origin "$OUTSIDE_BARE"
git -C "$SAFE_PUSH_REPO" config branch.main.remote origin
git -C "$SAFE_PUSH_REPO" config branch.main.merge refs/heads/main
SAFE_LOCAL_PUSH="$(curl -fsS -X POST "$SAFE_BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":418,"method":"tools/call","params":{"name":"git_push","arguments":{"repo_path":"safe-push-repo"}}}')"
printf '%s' "$SAFE_LOCAL_PUSH" | plutil -extract result.isError raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$SAFE_LOCAL_PUSH" | grep -q "transport 'file' not allowed"
if git --git-dir="$OUTSIDE_BARE" show-ref --verify --quiet refs/heads/main; then
    echo "git_push wrote to an out-of-root local remote while command execution was disabled" >&2
    exit 1
fi

echo "git-safe-mode-sandbox: ok"

COMMAND_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"printf swift-ok","timeout_seconds":5}}}')"
printf '%s' "$COMMAND_RESULT" | grep -q 'swift-ok'

printf '%s' "$COMMAND_RESULT" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -q 'exit_code: 0'

LARGE_COMMAND_RESULT="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"run_command","arguments":{"command":"yes x | head -c 120000","timeout_seconds":5}}}')"
grep -q 'truncated 20000 bytes' <<<"$LARGE_COMMAND_RESULT"

echo "mcp-legacy-smoke: ok"

MODERN_META='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"test","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}'

DISCOVER="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: server/discover' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"server/discover\",\"params\":{\"_meta\":$MODERN_META}}")"
printf '%s' "$DISCOVER" | grep -q '"supportedVersions":\["2026-07-28"\]'
printf '%s' "$DISCOVER" | grep -q '"resultType":"complete"'
printf '%s' "$DISCOVER" | grep -q '"name":"filemcp"'
printf '%s' "$DISCOVER" | grep -q 'io.modelcontextprotocol\\/serverInfo'
printf '%s' "$DISCOVER" | grep -q 'search_code'
printf '%s' "$DISCOVER" | grep -q 'repo_overview'

TOOLS="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/list' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/list\",\"params\":{\"_meta\":$MODERN_META}}")"
printf '%s' "$TOOLS" | grep -q '"resultType":"complete"'
printf '%s' "$TOOLS" | grep -q '"cacheScope":"private"'
printf '%s' "$TOOLS" | grep -q '"name":"read_file"'
printf '%s' "$TOOLS" | grep -q '"name":"read_file_range"'
printf '%s' "$TOOLS" | plutil -extract result.tools.3.name raw -expect string -o - - | grep -qx 'grep'
printf '%s' "$TOOLS" | plutil -extract result.tools.6.name raw -expect string -o - - | grep -qx 'glob'
printf '%s' "$TOOLS" | plutil -extract result.tools.3.inputSchema.properties.output_mode.enum json -o - - | grep -q 'files_with_matches'
printf '%s' "$TOOLS" | grep -q '"outputSchema"'
printf '%s' "$TOOLS" | plutil -extract result.tools.0.outputSchema.properties.result.type raw -expect string -o - - | grep -qx 'array'
printf '%s' "$TOOLS" | plutil -extract result.tools.1.outputSchema.properties.result.type raw -expect string -o - - | grep -qx 'string'
printf '%s' "$TOOLS" | plutil -extract result.tools.2.outputSchema.properties.content.type raw -expect string -o - - | grep -qx 'string'
printf '%s' "$TOOLS" | plutil -extract result.tools.4.name raw -expect string -o - - | grep -qx 'search_code'
printf '%s' "$TOOLS" | plutil -extract result.tools.4.outputSchema.properties.query_results.type raw -expect string -o - - | grep -qx 'array'
printf '%s' "$TOOLS" | plutil -extract result.tools.5.name raw -expect string -o - - | grep -qx 'repo_overview'
printf '%s' "$TOOLS" | plutil -extract result.tools.5.outputSchema.properties.manifests.type raw -expect string -o - - | grep -qx 'array'
printf '%s' "$TOOLS" | plutil -extract result.tools.0.annotations.openWorldHint raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$TOOLS" | plutil -extract result.tools.7.annotations.destructiveHint raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$TOOLS" | plutil -extract result.tools.16.annotations.openWorldHint raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$TOOLS" | plutil -extract result.tools.17.name raw -expect string -o - - | grep -qx 'save_conversation_to_codex'
printf '%s' "$TOOLS" | plutil -extract result.tools.17.annotations.openWorldHint raw -expect bool -o - - | grep -qx 'false'
printf '%s' "$TOOLS" | plutil -extract result.tools.18.annotations.openWorldHint raw -expect bool -o - - | grep -qx 'true'
printf '%s' "$TOOLS" | plutil -extract result.tools.19.name raw -expect string -o - - | grep -qx 'batch_read'
printf '%s' "$TOOLS" | plutil -extract result.tools.19.annotations.readOnlyHint raw -expect bool -o - - | grep -qx 'true'

MODERN_CALL="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/call' \
    -H 'Mcp-Name: =?base64?cmVhZF9maWxl?=' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"read_file\",\"arguments\":{\"relative_path\":\"hello.txt\"},\"_meta\":$MODERN_META}}")"
printf '%s' "$MODERN_CALL" | grep -q 'hello swift'
printf '%s' "$MODERN_CALL" | grep -q '"resultType":"complete"'
printf '%s' "$MODERN_CALL" | plutil -extract result.structuredContent.result raw -expect string -o - - | grep -qx 'hello swift'

UNKNOWN_TOOL="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/call' \
    -H 'Mcp-Name: does_not_exist' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"does_not_exist\",\"arguments\":{},\"_meta\":$MODERN_META}}")"
printf '%s' "$UNKNOWN_TOOL" | grep -q '"code":-32602'

STATUS="$(curl -sS -o "$TMP_DIR/mismatch.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: tools/list-wrong' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/list\",\"params\":{\"_meta\":$MODERN_META}}")"
[ "$STATUS" = "400" ]
grep -q '"code":-32020' "$TMP_DIR/mismatch.json"

STATUS="$(curl -sS -o "$TMP_DIR/version-mismatch.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2099-01-01' \
    -H 'Mcp-Method: tools/list' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":141,\"method\":\"tools/list\",\"params\":{\"_meta\":$MODERN_META}}")"
[ "$STATUS" = "400" ]
grep -q '"code":-32020' "$TMP_DIR/version-mismatch.json"

STATUS="$(curl -sS -o "$TMP_DIR/missing-version-header.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'Mcp-Method: server/discover' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":142,\"method\":\"server/discover\",\"params\":{\"_meta\":$MODERN_META}}")"
[ "$STATUS" = "400" ]
grep -q '"code":-32020' "$TMP_DIR/missing-version-header.json"

FUTURE_META='{"io.modelcontextprotocol/protocolVersion":"2099-01-01","io.modelcontextprotocol/clientCapabilities":{}}'
STATUS="$(curl -sS -o "$TMP_DIR/version.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2099-01-01' \
    -H 'Mcp-Method: tools/list' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/list\",\"params\":{\"_meta\":$FUTURE_META}}")"
[ "$STATUS" = "400" ]
grep -q '"code":-32022' "$TMP_DIR/version.json"
grep -q '2026-07-28' "$TMP_DIR/version.json"

STATUS="$(curl -sS -o "$TMP_DIR/meta.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: ping' \
    -d '{"jsonrpc":"2.0","id":16,"method":"ping","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}')"
[ "$STATUS" = "400" ]
grep -q '"code":-32602' "$TMP_DIR/meta.json"

STATUS="$(curl -sS -o "$TMP_DIR/method.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: made/up' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"made/up\",\"params\":{\"_meta\":$MODERN_META}}")"
[ "$STATUS" = "404" ]
grep -q '"code":-32601' "$TMP_DIR/method.json"

STATUS="$(curl -sS -o "$TMP_DIR/origin.txt" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Origin: https://evil.example' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":18,"method":"ping","params":{}}')"
[ "$STATUS" = "403" ]
grep -q 'Forbidden origin' "$TMP_DIR/origin.txt"

STATUS="$(curl -sS -o "$TMP_DIR/origin-port.txt" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Origin: https://chatgpt.com:444' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":180,"method":"ping","params":{}}')"
[ "$STATUS" = "403" ]
grep -q 'Forbidden origin' "$TMP_DIR/origin-port.txt"

STATUS="$(curl -sS -o "$TMP_DIR/origin-path.txt" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Origin: https://chatgpt.com/not-an-origin' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":179,"method":"ping","params":{}}')"
[ "$STATUS" = "403" ]
grep -q 'Forbidden origin' "$TMP_DIR/origin-path.txt"

STATUS="$(curl -sS -o "$TMP_DIR/host.txt" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Host: evil.example' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":181,"method":"ping","params":{}}')"
[ "$STATUS" = "403" ]
grep -q 'Forbidden host' "$TMP_DIR/host.txt"

STATUS="$(curl -sS -o "$TMP_DIR/content-type.txt" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: text/plain' \
    -d '{"jsonrpc":"2.0","id":182,"method":"ping","params":{}}')"
[ "$STATUS" = "415" ]
grep -q 'Content-Type must be application/json' "$TMP_DIR/content-type.txt"

MALFORMED_CLIENT_META='{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":"bad","io.modelcontextprotocol/clientCapabilities":{}}'
STATUS="$(curl -sS -o "$TMP_DIR/client-info.json" -w '%{http_code}' -X POST "$BASE_URL" \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: ping' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":183,\"method\":\"ping\",\"params\":{\"_meta\":$MALFORMED_CLIENT_META}}")"
[ "$STATUS" = "400" ]
grep -q '"code":-32602' "$TMP_DIR/client-info.json"
grep -q 'Invalid _meta.io.modelcontextprotocol.*clientInfo' "$TMP_DIR/client-info.json"

ALLOWED_ORIGIN="$(curl -fsS -X POST "$BASE_URL" \
    -H 'Origin: https://chatgpt.com' \
    -H 'Content-Type: application/json' \
    -H 'MCP-Protocol-Version: 2026-07-28' \
    -H 'Mcp-Method: ping' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"ping\",\"params\":{\"_meta\":$MODERN_META}}")"
printf '%s' "$ALLOWED_ORIGIN" | grep -q '"resultType":"complete"'

echo "mcp-modern-2026-07-28: ok"

if [ "$MCP_EXTENDED_SEARCH_TESTS" = "1" ]; then
    python3 - "$SERVER_ROOT" <<'PYEXT'
import os
import sys
root = sys.argv[1]

def mkdir(name):
    path = os.path.join(root, name)
    os.makedirs(path, exist_ok=True)
    return path

preview = mkdir("preview-limit")
with open(os.path.join(preview, "preview.txt"), "w", encoding="utf-8") as handle:
    for index in range(100):
        handle.write(f"preview-target-{index:03d} " + ("x" * 970) + "\n")

oversized = mkdir("oversized-file")
with open(os.path.join(oversized, "too-large.txt"), "wb") as handle:
    handle.write(b"OversizedTarget\n" + b"x" * 1_000_000)

byte_limit = mkdir("byte-limit")
payload = b"ByteLimitTarget\n" + b"x" * 989_000
for index in range(51):
    with open(os.path.join(byte_limit, f"chunk-{index:02d}.txt"), "wb") as handle:
        handle.write(payload)

file_limit = mkdir("code-file-limit")
for index in range(2_001):
    with open(os.path.join(file_limit, f"file-{index:04d}.txt"), "w", encoding="utf-8") as handle:
        handle.write("FileLimitTarget\n")

output_limit = mkdir("output-limit")
with open(os.path.join(output_limit, "lines.txt"), "w", encoding="utf-8") as handle:
    handle.write("y\n" * 450_000)

overview_limits = mkdir("overview-limits")
for index in range(101):
    manifest_dir = os.path.join(overview_limits, f"manifest-{index:03d}")
    os.makedirs(manifest_dir, exist_ok=True)
    open(os.path.join(manifest_dir, "package.json"), "wb").close()
for index in range(21):
    open(os.path.join(overview_limits, f"type-{index:02d}.ext{index:02d}"), "wb").close()
for index in range(1001):
    open(os.path.join(overview_limits, f"top-{index:04d}.txt"), "wb").close()

unreadable = mkdir("unreadable-file")
unreadable_file = os.path.join(unreadable, "secret.txt")
with open(unreadable_file, "w", encoding="utf-8") as handle:
    handle.write("unreadable-target\n")
os.chmod(unreadable_file, 0)

enumeration = mkdir("enumeration-error")
locked = os.path.join(enumeration, "locked")
os.makedirs(locked, exist_ok=True)
with open(os.path.join(locked, "hidden.txt"), "w", encoding="utf-8") as handle:
    handle.write("enumeration-hidden\n")
os.chmod(locked, 0)
PYEXT

    PREVIEW_LIMIT_RESULT="$(tool_call 5001 grep '{"pattern":"preview-target","path":"preview-limit","output_mode":"content","context":10}')"
    printf '%s' "$PREVIEW_LIMIT_RESULT" | extract truncated raw | grep -qx 'true'
    printf '%s' "$PREVIEW_LIMIT_RESULT" | extract truncation_reasons json | grep -q 'preview_limit'
    printf '%s' "$PREVIEW_LIMIT_RESULT" | extract next_offset raw | grep -Eq '^[1-9][0-9]*$'

    OVERSIZED_FILE_RESULT="$(tool_call 5002 search_code '{"queries":["OversizedTarget"],"path":"oversized-file","max_results_per_query":1}')"
    printf '%s' "$OVERSIZED_FILE_RESULT" | extract files_matched raw | grep -qx '0'
    printf '%s' "$OVERSIZED_FILE_RESULT" | extract query_results.0.observed_matching_lines raw | grep -qx '0'
    OVERSIZED_GLOB_RESULT="$(tool_call 5013 glob '{"pattern":"*.txt","path":"oversized-file"}')"
    printf '%s' "$OVERSIZED_GLOB_RESULT" | extract files.0 raw | grep -qx 'oversized-file/too-large.txt'
    OVERSIZED_OVERVIEW_RESULT="$(tool_call 5014 repo_overview '{"path":"oversized-file"}')"
    printf '%s' "$OVERSIZED_OVERVIEW_RESULT" | extract files_seen raw | grep -qx '1'

    BYTE_LIMIT_RESULT="$(tool_call 5003 search_code '{"queries":["ByteLimitTarget"],"path":"byte-limit","max_results_per_query":1}')"
    printf '%s' "$BYTE_LIMIT_RESULT" | extract truncated raw | grep -qx 'true'
    printf '%s' "$BYTE_LIMIT_RESULT" | extract truncation_reasons json | grep -q 'byte_limit'
    printf '%s' "$BYTE_LIMIT_RESULT" | extract files_ranked raw | grep -qx '50'

    FILE_LIMIT_RESULT="$(tool_call 5004 search_code '{"queries":["FileLimitTarget"],"path":"code-file-limit","max_results_per_query":1}')"
    printf '%s' "$FILE_LIMIT_RESULT" | extract truncation_reasons json | grep -q 'file_limit'
    printf '%s' "$FILE_LIMIT_RESULT" | extract files_matched raw | grep -qx '2001'
    printf '%s' "$FILE_LIMIT_RESULT" | extract files_ranked raw | grep -qx '2000'

    OUTPUT_LIMIT_RESULT="$(tool_call 5009 grep '{"pattern":"y","path":"output-limit","output_mode":"content","head_limit":1}')"
    printf '%s' "$OUTPUT_LIMIT_RESULT" | plutil -extract result.isError raw -o - - | grep -qx 'false'
    printf '%s' "$OUTPUT_LIMIT_RESULT" | extract truncation_reasons json | grep -q 'output_limit'
    printf '%s' "$OUTPUT_LIMIT_RESULT" | extract returned raw | grep -qx '1'

    OVERVIEW_LIMIT_RESULT="$(tool_call 5012 repo_overview '{"path":"overview-limits"}')"
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract manifests raw | grep -qx '100'
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract manifest_results_limited raw | grep -qx 'true'
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract file_extensions raw | grep -qx '20'
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract extension_counts_limited raw | grep -qx 'true'
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract top_level_entries raw | grep -qx '1000'
    printf '%s' "$OVERVIEW_LIMIT_RESULT" | extract top_level_truncated raw | grep -qx 'true'

    UNREADABLE_RESULT="$(tool_call 5005 search_code '{"queries":["unreadable-target"],"path":"unreadable-file","max_results_per_query":1}')"
    printf '%s' "$UNREADABLE_RESULT" | plutil -extract result.isError raw -o - - | grep -qx 'false'
    printf '%s' "$UNREADABLE_RESULT" | extract search_errors raw | grep -qx '1'
    printf '%s' "$UNREADABLE_RESULT" | extract truncation_reasons json | grep -q 'search_error'
    printf '%s' "$UNREADABLE_RESULT" | extract query_results.0.observed_matching_lines raw | grep -qx '0'

    ENUMERATION_RESULT="$(tool_call 5006 search_code '{"queries":["enumeration-hidden"],"path":"enumeration-error","max_results_per_query":1}')"
    printf '%s' "$ENUMERATION_RESULT" | extract truncated raw | grep -qx 'true'
    printf '%s' "$ENUMERATION_RESULT" | extract search_errors raw | grep -Eq '^[1-9][0-9]*$'

    ENUMERATION_GLOB_RESULT="$(tool_call 5007 glob '{"pattern":"*","path":"enumeration-error"}')"
    printf '%s' "$ENUMERATION_GLOB_RESULT" | extract truncated raw | grep -qx 'true'

    ENUMERATION_OVERVIEW_RESULT="$(tool_call 5008 repo_overview '{"path":"enumeration-error"}')"
    printf '%s' "$ENUMERATION_OVERVIEW_RESULT" | extract truncated raw | grep -qx 'true'
    printf '%s' "$ENUMERATION_OVERVIEW_RESULT" | extract search_errors raw | grep -Eq '^[1-9][0-9]*$'

    chmod 700 "$SERVER_ROOT/enumeration-error/locked"
    chmod 600 "$SERVER_ROOT/unreadable-file/secret.txt"
    echo "extended-search-limits: ok"
fi

python3 tests/check_agent_tools_http.py

stop_server
