# FileMCP

<p align="center">
  <img src="assets/branding/filemcp-logo.svg" alt="FileMCP" width="720">
</p>

<p align="center"><strong>Your Files. Your MCP.</strong></p>

FileMCP is a native desktop app for **macOS and Windows** that gives ChatGPT controlled access to a local workspace through MCP. It can read and modify files, run Git operations, and—only when explicitly enabled—run local shell commands.

The MCP server stays bound to `127.0.0.1`. FileMCP uses OpenAI [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) to make that local server available to supported OpenAI products without opening a public inbound port on your computer.

> [!WARNING]
> FileMCP can modify or delete files inside the directory you choose. If command execution is enabled, it can also run processes with the permissions of your signed-in OS user. Use a narrowly scoped workspace and enable shell access only when you trust the workflow using it.

FileMCP is an independent open-source project. It is not an official OpenAI product.

## Highlights

- Native desktop implementations:
  - **Swift + AppKit** on macOS.
  - **C# + .NET 8 + WPF** on Windows.
- Equivalent MCP surface on both platforms: the same filesystem, Git, protocol, tunnel, and optional command-execution behavior.
- Local MCP server listens on **loopback only** (`127.0.0.1`).
- Built-in filesystem tools are restricted to one configured workspace root; optional shell commands are not OS-sandboxed.
- Symlink/reparse-point and canonical-path checks protect the workspace boundary.
- Git operations are available without enabling arbitrary shell execution.
- Optional shell execution is **off by default**.
- Runtime API keys are stored in the operating system credential store:
  - macOS Keychain.
  - Windows Credential Manager.
- Process output, request sizes, search scope, and concurrency are bounded.
- Descendant processes are cleaned up on timeout, stop, and application shutdown.
- Official OpenAI `tunnel-client` binaries are vendored with documented provenance and checksums.

## Platform support

| Platform | App technology | Bundled `tunnel-client` | Command shell |
| --- | --- | --- | --- |
| macOS Apple Silicon | Swift / AppKit | `darwin-arm64` | User shell (`zsh`/`sh`) |
| Windows x64 | .NET 8 / WPF | `windows-amd64` | Windows PowerShell |
| Windows ARM64 | .NET 8 / WPF | `windows-arm64` | Windows PowerShell |

The macOS build scripts understand Intel (`darwin-amd64`), but that platform is not currently bundled in this repository. Add the matching official `tunnel-client` binary and license sidecar before building for Intel macOS.

## Requirements

Common requirements:

- Access to a ChatGPT plan/workspace that supports custom MCP apps. Check OpenAI's current Developer Mode/MCP documentation for plan and workspace availability.
- A Secure MCP Tunnel configured for your OpenAI workspace.
- A restricted Platform runtime API key whose principal has **Tunnels Read + Use** for that tunnel.
- Git installed if you want to use the built-in Git tools.

For development/building:

- **macOS:** macOS 12 or later and Xcode or Xcode Command Line Tools with `swift`/`swiftc`.
- **Windows:** Windows 10/11 and the .NET 8 SDK. Git for Windows is required for Git-tool verification and normal Git use.

## Quick start

### macOS

Build:

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

### Windows

Build an x64 release from PowerShell:

```powershell
./build_windows_app.ps1 -Architecture x64
```

For Windows ARM64:

```powershell
./build_windows_app.ps1 -Architecture arm64
```

Release outputs are created under:

```text
dist/windows-x64/FileMCP/
dist/windows-arm64/FileMCP/
```

and packaged as:

```text
dist/FileMCP-v0.4.0-windows-x64.zip
dist/FileMCP-v0.4.0-windows-arm64.zip
```

The Windows app is self-contained, so end users do not need to install .NET separately. Local builds are unsigned; production distribution should Authenticode-sign the executable/package.

For a development run on Windows:

```powershell
./run_windows_dev.ps1
```

### Configure FileMCP

Open the **Connection** tab and enter the Secure MCP Tunnel ID and runtime API key. The key is stored in macOS Keychain or Windows Credential Manager after it is saved.

Open **Settings** and choose the local directory that ChatGPT is allowed to access. Click **Connect** to start the local MCP server and Secure MCP Tunnel.

### Add the MCP app in ChatGPT

Use ChatGPT Developer Mode / custom MCP app configuration for your workspace and connect it to the corresponding Secure MCP Tunnel. Availability and exact UI can vary by ChatGPT plan and workspace policy. For the current setup flow and plan-specific requirements, see OpenAI's [Developer mode and MCP apps in ChatGPT](https://help.openai.com/en/articles/12584461) documentation.

FileMCP does not listen on a public network interface; the local MCP endpoint remains on `127.0.0.1`.

## Application settings

The common workflow and terminology are kept aligned across macOS and Windows. Technical settings live under **Advanced options**.

| Setting | Purpose |
| --- | --- |
| Tunnel ID | Selects the OpenAI Secure MCP Tunnel; must match `tunnel_` followed by 32 lowercase letters or digits. |
| Runtime API key | Authenticates `tunnel-client`; stored in the platform credential store. |
| Shared directory | The only filesystem root exposed to MCP file tools. |
| Allow shell commands | Enables `run_command`; disabled by default. |
| Profile | FileMCP-owned `tunnel-client` profile name; letters/numbers plus `.`, `_`, `-`, maximum 128 characters. |
| MCP port | Local loopback port used by the MCP server. |
| Health listener | Loopback-only `tunnel-client` health/admin listener. Port `0` requests an ephemeral port. |
| Git name / Git email | Optional Git identity used by `git_commit`. |

Closing the main window does not stop an active tunnel:

- macOS: reopen FileMCP from the Dock.
- Windows: FileMCP remains available in the system tray; double-click the tray icon or choose **Open FileMCP**.

Use **Quit FileMCP** (or the platform quit shortcut) to terminate the app and stop the runtime.

## Available MCP tools

### Filesystem

| Tool | Purpose |
| --- | --- |
| `list_files` | List entries in a directory. |
| `read_file` | Read a text file. |
| `read_file_range` | Read a targeted line range with range metadata. |
| `search_filenames` | Search filenames recursively. |
| `search_content` | Search text content and return bounded previews. |
| `write_file` | Create, replace, or append to a text file. |
| `delete_file` | Delete a file or a file-like link/reparse entry. |
| `delete_directory` | Recursively delete a real directory within the workspace. |

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

`run_command` is exposed only when shell-command permission is enabled in FileMCP settings. It is intentionally not placed inside an OS-level sandbox.

- macOS executes through the user's configured shell, falling back to `/bin/sh`.
- Windows executes through Windows PowerShell with `-NoProfile -NonInteractive`.

Only the working directory is constrained to the shared root. Once command execution is enabled, the command itself has the normal permissions of the signed-in user.

## Security model

FileMCP intentionally treats the local workspace as a privileged boundary.

### Local networking

- The MCP server binds only to `127.0.0.1`.
- Every runtime start creates a fresh 256-bit local token. `tunnel-client` resolves that token through `env:FILEMCP_LOCAL_AUTH_TOKEN` and injects it only on requests to the local MCP origin.
- Missing or incorrect local-auth tokens are rejected before request bodies are accepted. The only exception is a bodyless `GET` to either standard OAuth Protected Resource Metadata discovery path; because FileMCP does not advertise OAuth, those requests return `404 Not Found` without exposing workspace data. The token is not persisted in the generated tunnel profile and is redacted from FileMCP logs/errors.
- The `tunnel-client` health/admin listener is restricted to `localhost`, `127.0.0.1`, or `[::1]`; FileMCP rejects public/LAN bind addresses.
- HTTP requires a valid `Host`, validates `Origin`, rejects malformed header names/values and inconsistent body framing, and bounds request headers/bodies.
- Processes running with the same OS-user privileges (or an administrator/root-equivalent context) remain inside the local trust boundary; the per-runtime token is defense in depth, not an OS sandbox.

### Filesystem containment

- Paths are canonicalized before access.
- macOS resolves symlink targets and validates existing ancestors against the configured workspace root.
- Windows resolves existing paths through Win32 handles (`GetFinalPathNameByHandleW`) so NTFS junctions, symbolic links, and other reparse-point escapes cannot be treated as ordinary in-root paths.
- Windows containment is case-insensitive and rejects rooted/UNC input supplied where a relative workspace path is required.
- Recursive search does not traverse reparse-point directories.
- File reads and writes are limited to **5 MB per request**.
- Text responses and search previews are truncated to bounded sizes.
- Recursive filename/content searches have visit, result, and byte-scan limits.

### Git safety

When shell execution is disabled, Git runs in a restricted mode designed to prevent Git metadata or configuration from escaping the shared-directory boundary. Both implementations validate the requested worktree plus Git/common/object directories before each operation and also check:

- `.git` redirect files, `commondir`, `config`, and `config.worktree` metadata;
- alternate object-store metadata, including quoted/path escape cases;
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
- Executable, argument, and environment strings are validated before process launch; NUL-truncation and invalid environment names are rejected.
- macOS launches children in dedicated process groups and cleans descendants on timeout/stop/parent exit.
- Windows assigns children to a Job Object with `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` and also uses process-tree termination as a fallback.
- `tunnel-client init`, `doctor`, and runtime processes participate in the same cancellation lifecycle.

### Secrets and tunnel runtime isolation

Runtime API keys are never stored in the plain settings file:

- macOS stores the key in Keychain as a generic password.
- Windows stores the key in Windows Credential Manager as a generic credential.

The API key is passed to `tunnel-client` through the child process environment rather than command-line arguments. Active API keys and per-runtime local-auth tokens are redacted from tunnel-client output before FileMCP surfaces it in logs or runtime errors.

FileMCP keeps generated tunnel profiles in an app-owned profile directory instead of the default `tunnel-client` profile directory, preventing `init --force` from overwriting an unrelated CLI profile with the same name:

- macOS: `~/Library/Application Support/FileMCP/tunnel-profiles`
- Windows: `%LOCALAPPDATA%\FileMCP\tunnel-profiles`

The child `tunnel-client` receives an allowlisted environment rather than the app's complete ambient environment. FileMCP explicitly supplies its API/local-auth values, preserves normal proxy/locale/platform variables, forces loopback hosts into `NO_PROXY`, and prevents ambient `MCP_SERVER_URL`, health-socket, raw-HTTP-log, or other tunnel config variables from silently overriding the generated profile.

The macOS bundle identifier intentionally remains `com.localfilesmcp.app` after the FileMCP rebrand so existing Keychain and `UserDefaults` data continue to resolve. Legacy macOS API keys stored in `UserDefaults` are migrated to Keychain when read successfully.

Never publish real API keys, OAuth tokens, `.env` files, credential-store exports, Git credentials, `.oauth_store.json`, or archives of a developer working directory.

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
                  ┌───────────────────────────────┐
                  │            FileMCP            │
                  │                               │
                  │  platform UI                  │
                  │  AppKit (macOS) / WPF (Win)  │
                  │              │                │
                  │              ▼                │
                  │       runtime orchestration   │
                  │              │                │
                  │       ┌──────┴──────┐         │
                  │       ▼             ▼         │
                  │   MCP server    process layer │
                  │   ├ files       ├ timeout     │
                  │   ├ Git         ├ output cap  │
                  │   └ commands    └ tree cleanup│
                  └───────────────────────────────┘
```

The macOS and Windows implementations intentionally use native platform APIs while preserving the same MCP/tool behavior and security invariants.

## MCP protocol compatibility

Both platform implementations support modern discovery and legacy Streamable HTTP initialization used by supported MCP clients:

- Modern protocol: `2026-07-28`, including `server/discover` and per-request metadata.
- Legacy protocols: `2025-03-26`, `2025-06-18`, and `2025-11-25` through `initialize` negotiation.

Tool definitions include `outputSchema`, and successful tool responses provide structured output where applicable.

## Repository layout

```text
.
├── assets/branding/
├── macos/
│   ├── FileMCPApp.swift
│   ├── LocalMCPRuntime.swift
│   ├── LocalMCPServer.swift
│   └── ProcessRunner.swift
├── windows/
│   ├── src/FileMCP.App/        # WPF desktop application
│   ├── src/FileMCP.Core/       # MCP, filesystem, Git, process, tunnel runtime
│   ├── tests/FileMCP.Core.Tests/
│   └── assets/
├── tests/
│   ├── test_swift_runtime.sh
│   └── test_windows_runtime.ps1
├── vendor/tunnel-client/
├── build_macos_app.sh
├── build_windows_app.ps1
├── run_macos_dev.sh
├── run_windows_dev.ps1
└── create_source_archive.sh
```

## Development and verification

### macOS

Development run:

```bash
./run_macos_dev.sh
```

Full integration suite:

```bash
./tests/test_swift_runtime.sh
```

The malformed HTTP parser fuzz loop defaults to 160 iterations. For a faster targeted run:

```bash
MCP_HTTP_FUZZ_ITERATIONS=20 ./tests/test_swift_runtime.sh
```

### Windows

Build the complete solution:

```powershell
dotnet build windows/FileMCP.Windows.sln -c Release -warnaserror
```

Run the Windows integration suite:

```powershell
./tests/test_windows_runtime.ps1
```

The Windows suite exercises Credential Manager, NTFS junction/reparse-point containment, Job Object process cleanup, Git for Windows safe mode, legacy/modern MCP, and the full `tunnel-client` runtime lifecycle through an isolated fake tunnel client.

GitHub Actions runs both macOS and Windows verification jobs. See [`CONTRIBUTING.md`](CONTRIBUTING.md) before submitting changes, especially changes to path containment, Git safety, process execution, HTTP parsing, credential storage, or tunnel isolation.

## `tunnel-client` provenance

FileMCP vendors official OpenAI `tunnel-client` v0.0.12 binaries for the platforms currently distributed by the project:

| Target | Bundled executable SHA-256 |
| --- | --- |
| `darwin-arm64` | `b1757220cf4722cec9085ee4a908cf0ee4c1a499a33bd99979b9a9c7669e29b1` |
| `windows-amd64` | `6649169733686805ca16cccd91774594d0c017fd729c37ad4ce1cd18323d9ae8` |
| `windows-arm64` | `480684ec1031fc2985c7e87f9d669e7dfda4012a8ecdab21eabe1b5deafdd656` |

The binaries are extracted from release archives verified against the upstream `SHA256SUMS.txt`. Full archive checksums, source commit, and update instructions are documented in [`vendor/tunnel-client/README.md`](vendor/tunnel-client/README.md).

The vendored dependency preserves its upstream [`LICENSE`](vendor/tunnel-client/LICENSE), [`NOTICE`](vendor/tunnel-client/NOTICE), and platform third-party license evidence beside each bundled executable. Build scripts copy the relevant legal files into each distributable app/package.

## Release packaging

Create a source archive only from tracked Git content:

```bash
./create_source_archive.sh
```

The script requires a clean working tree and uses `git archive`, preventing local credentials, `.git`, build output, and other ignored developer files from leaking into a source release.

Do not create public release archives by zipping the entire working directory.

Platform release builds are intentionally separate because signing/notarization requirements differ between macOS and Windows.

## Contributing

- Development guidelines: [`CONTRIBUTING.md`](CONTRIBUTING.md)
- Security reporting: [`SECURITY.md`](SECURITY.md)
- Release notes: [`CHANGELOG.md`](CHANGELOG.md)

## License

FileMCP source code is licensed under the **Apache License 2.0**. See [`LICENSE`](LICENSE).

The vendored OpenAI `tunnel-client` is distributed under its upstream license in [`vendor/tunnel-client/LICENSE`](vendor/tunnel-client/LICENSE). Its upstream `NOTICE` and platform third-party license evidence are preserved beside bundled binaries and copied into distributable app packages.


## Codex project skills

FileMCP can expose Codex Agent Skills stored inside the active shared workspace using the standard project layout:

```text
<shared-directory>/.agents/skills/<skill-name>/SKILL.md
```

Two read-only MCP tools are always exposed:

| Tool | Purpose |
| --- | --- |
| `list_codex_skills` | List valid project skills discovered under `.agents/skills`. |
| `load_codex_skill` | Load one skill's complete `SKILL.md` instructions by exact directory name. |

FileMCP scans `.agents/skills` automatically whenever the local MCP server starts. If a requested skill was added after startup, `load_codex_skill` refreshes the registry once before reporting that the skill is missing.

The MCP tool and server descriptions define `/name` as a skill-routing convention. For example, when FileMCP is available to the ChatGPT message, entering `/speckit-analyze` is intended to cause the model to call `load_codex_skill(name="speckit-analyze")` before answering and then follow the returned `SKILL.md`. This is not registration of a native ChatGPT slash-menu command or autocomplete entry.

Skill loading is read-only and remains inside the configured shared directory. Skill names cannot contain path separators or traversal syntax, symlink/reparse-point escapes are refused, `SKILL.md` must be valid UTF-8, and a skill larger than 256 KB is rejected instead of being silently truncated. If the optional frontmatter `name` is present, it must exactly match the skill directory name.

Skill discovery and loading are written to the FileMCP Logs view with a `[Skills]` prefix. The contents of `SKILL.md` are not copied into the application log.
