#!/usr/bin/env python3
"""Independent HTTP/MCP clients concurrently executing against one FileMCP runtime.

The caller supplies the isolated, short-lived server root and dummy local token.
No network is used except loopback; test processes are cleaned up by the suite.
"""
import concurrent.futures
import json
import os
from pathlib import Path
import sys
import time
import urllib.request

if len(sys.argv) != 4:
    raise SystemExit("usage: check_parallel_clients_http.py URL ROOT TOKEN")
url, root, token = sys.argv[1], Path(sys.argv[2]), sys.argv[3]
assert url.startswith("http://127.0.0.1:")
assert len(token) == 64


def rpc(name, arguments):
    req = {"jsonrpc": "2.0", "id": 5001, "method": "tools/call", "params": {"name": name, "arguments": arguments}}
    http = urllib.request.Request(url, json.dumps(req).encode(), method="POST", headers={
        "Content-Type": "application/json", "X-FileMCP-Local-Token": token,
        "User-Agent": "FileMCP-Independent-Test-Client",
    })
    with urllib.request.urlopen(http, timeout=22) as resp:
        result = json.load(resp)["result"]
    return result.get("isError", False), result.get("structuredContent", {}), result


def success(name, arguments):
    failed, body, response = rpc(name, arguments)
    if failed:
        raise AssertionError(f"{name} returned an error: {response.get('content', [])}")
    return body


configured = int(os.environ.get("FILEMCP_MAX_CONCURRENT_COMMANDS", "8"))
limit = max(4, min(16, configured))
workdirs = [f"http-{n:02d}" for n in range(limit)]
for name in workdirs + ["http-overcap"]:
    (root / name).mkdir(exist_ok=True)

# Two separate HTTP connections must execute run_command at the same time.
# They mutually wait for each other's marker. A serial dispatcher would fail.
def sync_client(name, peer):
    shell = f"touch started; for n in $(seq 1 140); do if test -f ../{peer}/started; then printf parallel-sync-ok; exit 0; fi; sleep .05; done; exit 24"
    return success("run_command", {"command": shell, "cwd": name, "timeout_seconds": 12})

with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
    jobs = [pool.submit(sync_client, workdirs[0], workdirs[1]), pool.submit(sync_client, workdirs[1], workdirs[0])]
    results = [future.result(timeout=16) for future in jobs]
assert all("parallel-sync-ok" in str(v) for v in results), results
print("http-concurrent-sync-clients: ok")

# Four long sessions from independent callers must be admitted concurrently.
active = {}
for name in workdirs:
    result = success("start_command", {
        "request_id": "independent-client-" + name,
        "command": "printf parallel-start; sleep 12; printf parallel-end",
        "cwd": name,
        "timeout_seconds": 25,
    })
    assert result.get("state") == "running", result
    active[name] = result["session_id"]
failed, _, _ = rpc("start_command", {"request_id": "over-capacity", "command": "true", "cwd": "http-overcap"})
assert failed, "Fifth concurrent job should be refused"
failed, _, _ = rpc("start_command", {"request_id": "same-worktree", "command": "true", "cwd": workdirs[0]})
assert failed, "Overlapping cwd should be refused"
print(f"http-{limit}-long-clients-admitted: ok")

# Cancelling one job does not stop its siblings.
success("cancel_command", {"session_id": active[workdirs[1]]})
deadline = time.monotonic() + 20
while time.monotonic() < deadline:
    states = {name: success("read_command_output", {"session_id": sid}).get("state") for name, sid in active.items()}
    if all(value not in ("running", "stopping") for value in states.values()):
        break
    time.sleep(.1)
assert states[workdirs[1]] == "cancelled", states
assert all(states[name] == "exited" for name in workdirs if name != workdirs[1]), states
print("http-independent-session-cancellation: ok")
