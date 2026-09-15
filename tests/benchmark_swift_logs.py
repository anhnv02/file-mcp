#!/usr/bin/env python3
"""Compare baseline/current AppKit log costs using synthetic data; no credentials or tunnel.

Run: python3 tests/benchmark_swift_logs.py --baseline <git-ref>
Results: build/log-benchmark/results.jsonl. CPU percent uses one logical core = 100%.
Each case runs in a fresh process, prefilled to the 500,000-character cap, with default follow enabled.
The disabled control still runs the same 10 ms workload timer without storing output.
"""
import argparse
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', default='HEAD')
parser.add_argument('--duration', type=float, default=4)
parser.add_argument('--repeats', type=int, default=3)
args = parser.parse_args()
if args.duration <= 0 or args.repeats < 1:
    parser.error('duration and repeats must be positive')
out = ROOT / 'build/log-benchmark'
out.mkdir(parents=True, exist_ok=True)
fixture = (ROOT / 'tests/SwiftLogBenchmark.swift.in').read_text()
baseline = subprocess.check_output(['git', 'show', f'{args.baseline}:macos/FileMCPApp.swift'], cwd=ROOT, text=True)
for version, source in [('old', baseline), ('new', (ROOT / 'macos/FileMCPApp.swift').read_text())]:
    folder = out / version
    folder.mkdir(exist_ok=True)
    signature = 'private func flushLogBuffer() {'
    if source.count(signature) != 1:
        raise RuntimeError('Expected exactly one flushLogBuffer method')
    source = source.replace(signature, 'private func benchmarkOriginalFlush() {')
    setup = 'controller.followLogsCheckbox.state = .on' if version == 'new' else ''
    (folder / 'FileMCPApp.swift').write_text(source + fixture.replace('BENCHMARK_FOLLOW_SETUP', setup))
    (folder / 'main.swift').write_text('import AppKit\nlet app = NSApplication.shared\nrunBenchmark()\n')
    subprocess.run(['swiftc', '-O', '-module-cache-path', str(out / 'cache'),
                    '-framework', 'AppKit', '-framework', 'Network', '-framework', 'Security',
                    '-o', str(folder / 'check'), *[str(ROOT / 'macos' / f'{name}.swift') for name in
                    ['ProcessRunner', 'LocalMCPServer', 'CodexHistory', 'LocalMCPRuntime']],
                    str(folder / 'FileMCPApp.swift'), str(folder / 'main.swift')], check=True)
with (out / 'results.jsonl').open('w') as output:
    for repeat in range(args.repeats):
        for rate in (10, 100, 1000):
            for mode in ('disabled', 'hidden', 'visible'):
                for version in ('old', 'new'):
                    if mode == 'disabled' and version == 'old':
                        continue
                    result = subprocess.run([str(out / version / 'check'), mode, str(rate), str(args.duration)],
                                            capture_output=True, text=True, check=True)
                    row = json.loads(result.stdout.strip().splitlines()[-1])
                    row.update(version=version, repeat=repeat)
                    output.write(json.dumps(row) + '\n')
                    output.flush()
                    print(json.dumps(row), flush=True)
