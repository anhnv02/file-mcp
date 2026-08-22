#!/usr/bin/env bash
# Fast development launcher for the full native Swift FileMCP app.
set -Eeuo pipefail
cd "$(dirname "$0")"

ROOT="$PWD"
BUILD_DIR="${MCP_MACOS_DEV_BUILD_DIR:-$ROOT/build/macos-dev}"
UI_BIN="$BUILD_DIR/FileMCP"
SWIFTC="${SWIFTC:-swiftc}"

if ! command -v "$SWIFTC" >/dev/null 2>&1; then
    echo "ERROR: swiftc is required. Install Xcode Command Line Tools or Xcode." >&2
    exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) TARGET_TAG="darwin-arm64" ;;
    x86_64|amd64) TARGET_TAG="darwin-amd64" ;;
    *) echo "ERROR: unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
esac

TUNNEL_BIN="$ROOT/vendor/tunnel-client/$TARGET_TAG/tunnel-client"
if [ ! -f "$TUNNEL_BIN" ]; then
    echo "ERROR: missing tunnel-client for $TARGET_TAG: $TUNNEL_BIN" >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"
cp "$TUNNEL_BIN" "$BUILD_DIR/tunnel-client"
chmod 755 "$BUILD_DIR/tunnel-client"

echo "Compiling full Swift macOS app ..."
"$SWIFTC" \
    -Onone \
    -g \
    -framework AppKit \
    -framework Network \
    -framework Security \
    -o "$UI_BIN" \
    "$ROOT/macos/ProcessRunner.swift" \
    "$ROOT/macos/LocalMCPServer.swift" \
    "$ROOT/macos/LocalMCPRuntime.swift" \
    "$ROOT/macos/FileMCPApp.swift" \
    "$ROOT/macos/main.swift"

echo "Starting FileMCP dev app"
echo "  Swift binary:  $UI_BIN"
echo "  tunnel-client: $BUILD_DIR/tunnel-client"
echo
exec "$UI_BIN"
