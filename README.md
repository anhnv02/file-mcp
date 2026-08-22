# FileMCP

<p align="center">
  <img src="assets/branding/filemcp-logo.svg" alt="FileMCP" width="720">
</p>

<p align="center"><strong>Your Files. Your MCP.</strong></p>

FileMCP is a native macOS app that gives ChatGPT controlled access to a local workspace through MCP. It can read and modify files, run Git operations, and—only when explicitly enabled—run shell commands on your Mac.

The local MCP server stays bound to `127.0.0.1`. FileMCP uses OpenAI [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) to make that local server available to supported OpenAI products without opening a public inbound port on your machine.

> [!WARNING]
> FileMCP can modify or delete files inside the directory you choose. If command execution is enabled, it can also run processes with the permissions of your macOS user account. Use a narrowly scoped workspace and enable shell access only when you trust the workflow using it.

FileMCP is an independent open-source project. It is not an official OpenAI product.

## Highlights

- Native **Swift + AppKit** macOS application.
- Local MCP server listens on **loopback only** (`127.0.0.1`).
- Built-in filesystem tools are restricted to one configured workspace root; optional shell commands are not OS-sandboxed.
- Symlinks and canonical paths are checked before file operations.
- Git operations are available without enabling arbitrary shell execution.
- Optional shell execution is **off by default**.
- Runtime API keys are stored in **macOS Keychain**.
- Process output, request sizes, search scope, and concurrency are bounded.
- Child process groups are terminated on timeout, stop, and application shutdown.
- Bundled OpenAI `tunnel-client` provenance and checksums are documented in the repository.

## Requirements

- macOS 12 or later.
- Xcode or Xcode Command Line Tools with `swift` and `swiftc`.
- Access to a ChatGPT plan/workspace that supports custom MCP apps. Check OpenAI's current Developer Mode/MCP documentation for plan and workspace availability.
- A Secure MCP Tunnel configured for your OpenAI workspace.
- A restricted Platform runtime API key whose principal has **Tunnels Read + Use** for that tunnel.

The repository currently bundles `tunnel-client` for **Apple Silicon (`darwin-arm64`)**. The build scripts understand Intel macOS as well, but the matching official `darwin-amd64/tunnel-client` binary and platform third-party license sidecar must be added under `vendor/tunnel-client/` before building on Intel.

## Quick start

### 1. Build FileMCP

```bash
./build_macos_app.sh
```

The app is created at:

```text
dist/FileMCP.app
```

Launch it with:

```bash
open "dist/FileMCP.app"
```

The local build is unsigned. Distribution builds should be code-signed and notarized using the normal macOS release process.

### 2. Configure the connection

Open the **Connection** tab and enter the Secure MCP Tunnel ID and runtime API key. The key is stored in macOS Keychain after it is saved.

Open **Settings** and choose the local directory that ChatGPT is allowed to access. Click **Connect** to start the local MCP server and Secure MCP Tunnel.

### 3. Add the MCP app in ChatGPT

Use ChatGPT Developer Mode / custom MCP app configuration for your workspace and connect it to the corresponding Secure MCP Tunnel. Availability and exact UI can vary by ChatGPT plan and workspace policy. For the current setup flow and plan-specific requirements, see OpenAI's [Developer mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461) documentation.

FileMCP does not listen on a public network interface; the local MCP endpoint remains on `127.0.0.1`.

## Application settings

The default UI keeps the common workflow small. Technical settings are placed under **Advanced options**.

| Setting | Purpose |
| --- | --- |
| Tunnel ID | Selects the OpenAI Secure MCP Tunnel; must match `tunnel_` followed by 32 lowercase letters or digits. |
| Runtime API key | Authenticates `tunnel-client`; persisted in macOS Keychain. |
| Shared directory | The only filesystem root exposed to MCP file tools. |
| Allow shell commands | Enables `run_command`; disabled by default. |
| Profile | FileMCP-owned `tunnel-client` profile name; letters/numbers plus `.`, `_`, `-`, maximum 128 characters. |
| MCP port | Local loopback port used by the Swift MCP server. |
| Health listener | Loopback-only `tunnel-client` health/admin listener. Port `0` requests an ephemeral port. |
| Git name / Git email | Optional Git identity used by `git_commit`. |

Closing the window does not stop FileMCP. Click the Dock icon to reopen it. Use **Quit FileMCP** in the persistent footer or `⌘Q` to terminate the application and stop the runtime.

## Available MCP tools

### Filesystem

| Tool | Purpose |
| --- | --- |
| `list_files` | List entries in a directory. |
| `read_file` | Read a text file. |
| `read_file_range` | Read a targeted line range with range metadata. |
| `search_filenames` | Search filenames recursively. |
| `search_content` | Search text content and return bounded previews. |
| `write_file` | Create or replace a text file. |
| `delete_file` | Delete a file or file symlink. |
| `delete_directory` | Recursively delete a directory within the workspace. |

### Git

| Tool | Purpose |
| --- | --- |
| `git_init` | Initialize a repository. |
| `git_status` | Inspect repository state. |
| `git_log` | Read commit history. |
| `git_diff` | Inspect working-tree or staged changes. |
| `git_add` | Stage files. |
| `git_commit` | Create a commit. |
| `git_push` | Push the current branch to its configured upstream. |

### Optional command execution

```text
run_command(command, cwd="", timeout_seconds=30)
```

`run_command` is exposed only when shell-command permission is enabled in FileMCP settings. Commands run through the user's login shell and are not placed inside an OS-level sandbox.

## Security model

FileMCP intentionally treats the local workspace as a privileged boundary.

### Local networking

- The MCP server binds only to `127.0.0.1`.
- Every runtime start creates a fresh 256-bit local token. `tunnel-client` resolves that token through `env:FILEMCP_LOCAL_AUTH_TOKEN` and injects it only on requests to the local MCP origin.
- Missing or incorrect local-auth tokens are rejected before request bodies are accepted. The token is not persisted in the generated tunnel profile and is redacted from FileMCP logs/errors.
- The `tunnel-client` health/admin listener is restricted to `localhost`, `127.0.0.1`, or `[::1]`; FileMCP rejects public/LAN bind addresses.
- HTTP requires a valid `Host`, validates `Origin`, rejects malformed header names/values and inconsistent body framing, and bounds request headers/bodies.
- Processes with the same macOS user privileges, or root, remain inside the local trust boundary; the per-runtime token is defense in depth, not an OS sandbox.

### Filesystem containment

- Paths are canonicalized before access.
- Symlink traversal is checked against the configured workspace root.
- File reads and writes are limited to **5 MB per request**.
- Text responses and search previews are truncated to bounded sizes.
- Recursive filename/content searches have visit, result, and byte-scan limits.

### Git safety

When shell execution is disabled, Git runs in a restricted mode designed to prevent Git metadata or configuration from escaping the shared-directory boundary. FileMCP validates the requested worktree plus Git/common/object directories before each operation and also checks:

- `.git` redirect files, `commondir`, `config`, and `config.worktree` metadata;
- alternate object-store metadata, including quoted/escaped and symlink escape cases;
- embedded repositories encountered by `git_add`;
- repository config includes and repository-controlled HTTP cookie/certificate/key file settings.

Safe mode also suppresses execution-oriented Git behavior:

- hooks, `core.fsmonitor`, external `git init` templates, external diff/text conversion, GPG signing, and content filters during `git_add`;
- arbitrary Git transports and local-file transport; only HTTP, HTTPS, and SSH are allowed;
- credential helpers are reset, askpass is disabled, and SSH runs with user SSH config/`ProxyCommand`/`ProxyJump` disabled. ssh-agent and default SSH identity files may still participate in an SSH push.

Git operations and mutating MCP tools are serialized against each other so another MCP request cannot change repository metadata between a safety check and the corresponding Git operation. When shell execution is explicitly enabled, these Git safe-mode restrictions are relaxed and Git behaves more like the user's normal local environment. Only use that mode for trusted workspaces.

### Process lifecycle

- Shell command timeout defaults to **30 seconds** and is capped at **120 seconds**.
- Shell/Git stdout and stderr are bounded to **100 KB per stream** for tool results.
- POSIX executable/argument/environment strings are validated before `posix_spawn`; NUL-truncation and invalid environment names are rejected.
- Child processes run in their own process group. Timeout, stop, parent exit, or app termination cleans up descendants with `SIGTERM` and a `SIGKILL` fallback.
- `tunnel-client init`, `doctor`, and runtime processes participate in the same cancellation lifecycle.

### Secrets and tunnel runtime isolation

Runtime API keys are stored as generic passwords in macOS Keychain and are passed to `tunnel-client` through the process environment rather than command-line arguments. Active API keys and local-auth tokens are redacted from tunnel-client output before FileMCP surfaces it in logs or runtime errors.

FileMCP keeps generated tunnel profiles under `~/Library/Application Support/FileMCP/tunnel-profiles` instead of the default `tunnel-client` profile directory, preventing `init --force` from overwriting an unrelated CLI profile with the same name. The directory is restricted to the current user, and the bundled client writes profile files with restrictive permissions.

The child `tunnel-client` receives an allowlisted environment rather than the app's complete ambient environment. FileMCP explicitly supplies its API/local-auth values, preserves normal proxy/locale variables, forces loopback hosts into `NO_PROXY`, and prevents ambient `MCP_SERVER_URL`, health-socket, raw-HTTP-log, or other tunnel config variables from silently overriding the generated profile.

The bundle identifier intentionally remains `com.localfilesmcp.app` after the FileMCP rebrand so existing Keychain and `UserDefaults` data continue to resolve. Legacy API keys stored in `UserDefaults` are migrated to Keychain when read successfully.

Never publish real API keys, OAuth tokens, `.env` files, Keychain exports, Git credentials, `.oauth_store.json`, or archives of a developer working directory.

For private vulnerability reporting guidance, see [`SECURITY.md`](SECURITY.md).

## Architecture

```text
ChatGPT / OpenAI product
          │
          │ Secure MCP Tunnel
          ▼
   OpenAI tunnel-client
          │
          │ http://127.0.0.1:<port>/mcp
          ▼
┌──────────────────────────────────────┐
│               FileMCP                │
│                                      │
│  AppKit UI                           │
│      │                               │
│      ▼                               │
│  LocalMCPRuntime                     │
│      │                               │
│      ├── LocalMCPServer              │
│      │     ├── filesystem tools      │
│      │     ├── Git tools             │
│      │     └── optional run_command  │
│      │                               │
│      └── ProcessRunner               │
│            ├── timeout               │
│            ├── bounded output        │
│            └── process-group cleanup │
└──────────────────────────────────────┘
```

The app is a single native Swift executable plus the vendored `tunnel-client` binary.

## MCP protocol compatibility

The server supports both modern discovery and legacy Streamable HTTP initialization used by supported MCP clients:

- Modern protocol: `2026-07-28`, including `server/discover` and per-request metadata.
- Legacy protocols: `2025-03-26`, `2025-06-18`, and `2025-11-25` through `initialize` negotiation.

Tool definitions include `outputSchema`, and successful tool responses provide structured output where applicable.

## Repository layout

```text
.
├── assets/branding/
│   ├── filemcp-logo.svg
│   └── render_filemcp_icon.swift
├── macos/
│   ├── FileMCPApp.swift
│   ├── LocalMCPRuntime.swift
│   ├── LocalMCPServer.swift
│   ├── ProcessRunner.swift
│   ├── Info.plist
│   └── main.swift
├── tests/
│   └── test_swift_runtime.sh
├── vendor/tunnel-client/
├── build_macos_app.sh
├── build_macos_icon.sh
├── run_macos_dev.sh
└── create_source_archive.sh
```

## Development

For a fast local development build:

```bash
./run_macos_dev.sh
```

This compiles the Swift sources into `build/macos-dev/`, copies the architecture-matched `tunnel-client`, and launches FileMCP directly.

### Verification

Run the full integration suite:

```bash
./tests/test_swift_runtime.sh
```

The malformed HTTP parser fuzz loop defaults to 160 iterations. For a faster targeted development run, reduce only that loop:

```bash
MCP_HTTP_FUZZ_ITERATIONS=20 ./tests/test_swift_runtime.sh
```

Static verification used by CI includes:

```bash
plutil -lint macos/Info.plist
bash -n build_macos_app.sh build_macos_icon.sh create_source_archive.sh run_macos_dev.sh tests/test_swift_runtime.sh

swiftc -warnings-as-errors -typecheck \
  -framework AppKit \
  -framework Network \
  -framework Security \
  macos/ProcessRunner.swift \
  macos/LocalMCPServer.swift \
  macos/LocalMCPRuntime.swift \
  macos/FileMCPApp.swift \
  macos/main.swift
```

See [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting changes, especially changes to path containment, Git safety, process execution, HTTP parsing, or secret handling.

## `tunnel-client` provenance

FileMCP currently vendors the official OpenAI `tunnel-client` release for Apple Silicon:

- release: `v0.0.12`;
- target: `darwin-arm64`;
- bundled binary SHA-256: `b1757220cf4722cec9085ee4a908cf0ee4c1a499a33bd99979b9a9c7669e29b1`.

The bundled binary has been verified against the official release artifact. Full provenance, source commit, archive checksum, and update instructions are documented in [`vendor/tunnel-client/README.md`](vendor/tunnel-client/README.md).

The vendored dependency preserves its upstream [`LICENSE`](vendor/tunnel-client/LICENSE), [`NOTICE`](vendor/tunnel-client/NOTICE), and platform third-party license evidence in `vendor/tunnel-client/darwin-arm64/THIRD-PARTY-LICENSES.txt`.

## Release packaging

Create a source archive only from tracked Git content:

```bash
./create_source_archive.sh
```

The script requires a clean working tree and uses `git archive`, preventing local credentials, `.git`, build output, and other ignored developer files from leaking into a source release.

Do not create public release archives by zipping the entire working directory.

## Contributing

- Development guidelines: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Security reporting: [`SECURITY.md`](SECURITY.md)
- Release notes: [`CHANGELOG.md`](CHANGELOG.md)

## License

FileMCP source code is licensed under the **Apache License 2.0**. See [`LICENSE`](LICENSE).

The vendored OpenAI `tunnel-client` is distributed under its upstream license in [`vendor/tunnel-client/LICENSE`](vendor/tunnel-client/LICENSE). Its upstream `NOTICE` and platform third-party license evidence are preserved beside the binary and copied into built app bundles.
