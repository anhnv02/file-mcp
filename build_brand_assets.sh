#!/usr/bin/env bash
# Rebuild the complete FileMCP identity from shared document-and-connection vector geometry.
set -Eeuo pipefail
cd "$(dirname "$0")"
BRAND_DIR="$PWD/assets/branding/filemcp-v2"
"${SWIFT:-swift}" assets/branding/render_filemcp_icon.swift --brand-kit "$BRAND_DIR"
rm -f "$BRAND_DIR/source-folder.png"
bash build_macos_icon.sh
cp build/AppIcon.icns "$BRAND_DIR/FileMCP.icns"
cp "$BRAND_DIR/FileMCP.ico" windows/assets/filemcp.ico
cp "$BRAND_DIR/wordmark-light.svg" assets/branding/filemcp-logo.svg
mkdir -p dist
python3 - "$BRAND_DIR" "$PWD/dist/FileMCP-brand-kit-v2.zip" <<'PY'
from pathlib import Path
from zipfile import ZipFile, ZipInfo, ZIP_DEFLATED
import sys
source, destination = map(Path, sys.argv[1:])
with ZipFile(destination, 'w', compression=ZIP_DEFLATED) as archive:
    for path in sorted(source.iterdir()):
        if path.is_file() and path.suffix.lower() in {'.svg', '.png', '.icns', '.ico', '.md'}:
            entry = ZipInfo('FileMCP-brand-kit-v2/' + path.name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.compress_type = ZIP_DEFLATED
            entry.external_attr = 0o100644 << 16
            archive.writestr(entry, path.read_bytes())
print('Built:', destination)
PY
