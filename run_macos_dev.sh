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
RG_BIN="$ROOT/vendor/ripgrep/$TARGET_TAG/rg"
for required_binary in "$TUNNEL_BIN" "$RG_BIN"; do
    if [ ! -f "$required_binary" ]; then
        echo "ERROR: missing bundled executable for $TARGET_TAG: $required_binary" >&2
        exit 1
    fi
done

mkdir -p "$BUILD_DIR"
cp "$TUNNEL_BIN" "$BUILD_DIR/tunnel-client"
chmod 755 "$BUILD_DIR/tunnel-client"
cp "$RG_BIN" "$BUILD_DIR/rg"
chmod 755 "$BUILD_DIR/rg"

echo "Compiling full Swift macOS app ..."
"$SWIFTC" \
    -Onone \
    -g \
    -framework AppKit \
    -framework Network \
    -framework Security \
    -o "$UI_BIN" \
    "$ROOT/macos/ProcessRunner.swift" \
    "$ROOT/macos/Ripgrep.swift" \
    "$ROOT/macos/LocalMCPServer.swift" \
    "$ROOT/macos/CodexHistory.swift" \
    "$ROOT/macos/LocalMCPRuntime.swift" \
    "$ROOT/macos/FileMCPApp.swift" \
    "$ROOT/macos/main.swift"

echo "Starting FileMCP dev app"
echo "  Swift binary:  $UI_BIN"
echo "  tunnel-client: $BUILD_DIR/tunnel-client"
echo "  ripgrep:       $BUILD_DIR/rg"
echo
exec "$UI_BIN"
