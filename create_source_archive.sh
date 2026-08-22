#!/usr/bin/env bash
# Create a release-safe FileMCP source archive from tracked Git content only.
set -Eeuo pipefail
cd "$(dirname "$0")"

if [ -n "$(git status --porcelain)" ]; then
    echo "ERROR: working tree must be clean before creating a source archive." >&2
    exit 1
fi

VERSION="$(plutil -extract CFBundleShortVersionString raw -o - macos/Info.plist)"
PREFIX="filemcp-v${VERSION}/"
OUTPUT="dist/filemcp-v${VERSION}-source.zip"

mkdir -p dist
rm -f "$OUTPUT"
git archive --format=zip --prefix="$PREFIX" --output="$OUTPUT" HEAD

echo "Built: $OUTPUT"
shasum -a 256 "$OUTPUT"
