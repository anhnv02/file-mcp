#!/usr/bin/env bash
# Generate the FileMCP macOS .icns asset from the brand source.
set -Eeuo pipefail
cd "$(dirname "$0")"

ROOT="$PWD"
RENDERER="$ROOT/assets/branding/render_filemcp_icon.swift"
SOURCE="$ROOT/build/filemcp-icon.png"
ICONSET="$ROOT/build/AppIcon.iconset"
OUTPUT="$ROOT/build/AppIcon.icns"
SWIFT="${SWIFT:-swift}"

[ -f "$RENDERER" ] || { echo "ERROR: missing $RENDERER" >&2; exit 1; }
command -v "$SWIFT" >/dev/null 2>&1 || {
    echo "ERROR: swift is required to render the FileMCP app icon." >&2
    exit 1
}

mkdir -p "$ROOT/build"
"$SWIFT" "$RENDERER" "$SOURCE"

rm -rf "$ICONSET" "$OUTPUT"
mkdir -p "$ICONSET"

for size in 16 32 128 256 512; do
    double=$((size * 2))
    sips -z "$size" "$size" "$SOURCE" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z "$double" "$double" "$SOURCE" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUTPUT"
echo "Built: $OUTPUT"
