#!/usr/bin/env bash
# Build the full native macOS FileMCP app.
set -Eeuo pipefail
cd "$(dirname "$0")"

ROOT="$PWD"
APP="$ROOT/dist/FileMCP.app"
SWIFTC="${SWIFTC:-swiftc}"

"$ROOT/build_macos_icon.sh"

command -v "$SWIFTC" >/dev/null 2>&1 || {
    echo "ERROR: swiftc is required to build the native macOS app." >&2
    exit 1
}

ARCH="$(uname -m)"
case "$ARCH" in
    arm64|aarch64) TARGET_TAG="darwin-arm64"; TARGET_TRIPLE="arm64-apple-macosx12.0" ;;
    x86_64|amd64) TARGET_TAG="darwin-amd64"; TARGET_TRIPLE="x86_64-apple-macosx12.0" ;;
    *) echo "ERROR: unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
esac

TUNNEL_BIN="$ROOT/vendor/tunnel-client/$TARGET_TAG/tunnel-client"
APP_LICENSE="$ROOT/LICENSE"
TUNNEL_LICENSE="$ROOT/vendor/tunnel-client/LICENSE"
TUNNEL_NOTICE="$ROOT/vendor/tunnel-client/NOTICE"
TUNNEL_THIRD_PARTY="$ROOT/vendor/tunnel-client/$TARGET_TAG/THIRD-PARTY-LICENSES.txt"
if [ ! -f "$TUNNEL_BIN" ]; then
    echo "ERROR: missing tunnel-client for $TARGET_TAG:" >&2
    echo "       $TUNNEL_BIN" >&2
    exit 1
fi
for required_file in "$APP_LICENSE" "$TUNNEL_LICENSE" "$TUNNEL_NOTICE" "$TUNNEL_THIRD_PARTY"; do
    if [ ! -f "$required_file" ]; then
        echo "ERROR: missing required license/provenance file: $required_file" >&2
        exit 1
    fi
done

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/macos/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/build/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$APP_LICENSE" "$APP/Contents/Resources/FileMCP-LICENSE.txt"
cp "$TUNNEL_LICENSE" "$APP/Contents/Resources/tunnel-client-LICENSE.txt"
cp "$TUNNEL_NOTICE" "$APP/Contents/Resources/tunnel-client-NOTICE.txt"
cp "$TUNNEL_THIRD_PARTY" "$APP/Contents/Resources/tunnel-client-THIRD-PARTY-LICENSES.txt"
cp "$TUNNEL_BIN" "$APP/Contents/MacOS/tunnel-client"
chmod 755 "$APP/Contents/MacOS/tunnel-client"

"$SWIFTC" \
    -O \
    -target "$TARGET_TRIPLE" \
    -framework AppKit \
    -framework Network \
    -framework Security \
    -o "$APP/Contents/MacOS/FileMCP" \
    "$ROOT/macos/ProcessRunner.swift" \
    "$ROOT/macos/LocalMCPServer.swift" \
    "$ROOT/macos/LocalMCPRuntime.swift" \
    "$ROOT/macos/FileMCPApp.swift" \
    "$ROOT/macos/main.swift"

echo
echo "Built: $APP"
file "$APP/Contents/MacOS/FileMCP" "$APP/Contents/MacOS/tunnel-client"
ls -lh "$APP/Contents/MacOS/FileMCP" "$APP/Contents/MacOS/tunnel-client"
