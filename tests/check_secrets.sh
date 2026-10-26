#!/usr/bin/env bash
# Scan reachable Git history plus the files eligible for the next public commit.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
command -v gitleaks >/dev/null 2>&1 || { echo 'Install Gitleaks 8.30.1 or newer before scanning.' >&2; exit 2; }
SCAN_DIR="$(mktemp -d)"
trap 'rm -rf "$SCAN_DIR"' EXIT
# Redaction is mandatory; do not upload raw secret reports as CI artifacts.
gitleaks git --no-banner --redact=100 --log-opts=--all .
python3 - "$SCAN_DIR" <<'PY'
from pathlib import Path
import shutil, subprocess, sys
root = Path.cwd()
target = Path(sys.argv[1]) / 'working-tree'
target.mkdir()
files = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard']).decode().split('\0')
for name in set(filter(None, files)):
    source = root / name
    if source.is_file() and not source.is_symlink():
        destination = target / name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
PY
gitleaks dir --no-banner --redact=100 "$SCAN_DIR/working-tree"
