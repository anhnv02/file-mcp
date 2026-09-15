#!/usr/bin/env bash
# Exercise AppKit log updates without loading settings or accessing credentials.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
cat macos/FileMCPApp.swift tests/SwiftUILogChecks.swift > "$TEST_DIR/FileMCPApp.swift"
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import AppKit
let app = NSApplication.shared
runLogRegressionChecks()
SWIFT
swiftc -module-cache-path "${SWIFT_MODULECACHE_PATH:-$TEST_DIR/cache}" \
    -framework AppKit -framework Network -framework Security \
    -o "$TEST_DIR/check" macos/ProcessRunner.swift macos/Ripgrep.swift macos/LocalMCPServer.swift \
    macos/CodexHistory.swift macos/LocalMCPRuntime.swift \
    "$TEST_DIR/FileMCPApp.swift" "$TEST_DIR/main.swift"
"$TEST_DIR/check"
