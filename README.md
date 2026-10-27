![FileMCP — Your local workspace, connected to ChatGPT. On your terms.](assets/branding/filemcp-v2/readme-header.png)

<p align="center">
  <img src="https://img.shields.io/badge/macOS-12%2B-22293A?style=flat-square&logo=apple&logoColor=white" alt="macOS 12 or later">
  <img src="https://img.shields.io/badge/Windows-10%2F11-22293A?style=flat-square&logo=windows&logoColor=white" alt="Windows 10 and 11">
  <img src="https://img.shields.io/badge/license-Apache--2.0-DB0F30?style=flat-square" alt="Apache 2.0 license">
  <img src="https://img.shields.io/badge/open-source-30394E?style=flat-square" alt="Open source">
</p>

<p align="center">
  <a href="#quick-start"><strong>Get started</strong></a> ·
  <a href="#highlights">Features</a> ·
  <a href="#security-model">Security</a> ·
  <a href="#development-and-verification">Development</a>
</p>

FileMCP is a native **macOS and Windows** desktop application that gives ChatGPT controlled access to a local workspace through MCP. It can read and modify files, run Git operations, and—only when explicitly enabled—run local shell commands.

The MCP server stays bound to `127.0.0.1`. By default, FileMCP uses OpenAI [Secure MCP Tunnel](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels) to connect supported OpenAI products without a public MCP endpoint. On macOS, you can alternatively use your own Cloudflare Tunnel with a public HTTPS hostname and OAuth. Both options establish an outbound tunnel rather than opening an inbound router port.

> [!WARNING]
> FileMCP can modify or delete files inside the directory you choose. If command execution is enabled, it can also run processes with the permissions of your signed-in OS user. Use a narrowly scoped workspace and enable shell access only when you trust the workflow using it.

FileMCP is an independent open-source project. It is not an official OpenAI product.

## Highlights

- Native desktop implementations:
  - **Swift + AppKit** on macOS.
  - **C# + .NET 8 + WPF** on Windows.
- Shared core tools on both platforms: filesystem access, Git, Codex-history import, MCP protocol support, OpenAI tunnel integration and optional command execution. Provider choices and permission controls differ; see [Application settings](#application-settings).
- Compact macOS interface with a workspace overview, persistent connection controls and a saved light/dark appearance choice.
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

## Screenshots

Current native macOS interface, captured with sample settings and no live connection or real credentials. Cloudflare login status is simulated. Windows uses a separate WPF interface and is not pictured. Click any screenshot to view it at full size.

<table>
  <tr>
    <td align="center" valign="top"><strong>Overview</strong><br><a href="assets/screenshots/macos/overview-light.png"><img src="assets/screenshots/macos/overview-light.png" alt="macOS Overview in light appearance showing the sample folder, permissions and connection route" width="290"></a></td>
    <td align="center" valign="top"><strong>Workspace</strong><br><a href="assets/screenshots/macos/workspace-light.png"><img src="assets/screenshots/macos/workspace-light.png" alt="macOS Workspace in light appearance with file access and optional permissions" width="290"></a></td>
  </tr>
  <tr>
    <td align="center" valign="top"><strong>Connection</strong><br><a href="assets/screenshots/macos/connection-light.png"><img src="assets/screenshots/macos/connection-light.png" alt="macOS Connection in light appearance with OpenAI tunnel ID and runtime API key fields" width="290"></a></td>
    <td align="center" valign="top"><strong>Activity</strong><br><a href="assets/screenshots/macos/activity-light.png"><img src="assets/screenshots/macos/activity-light.png" alt="macOS Activity in light appearance with the empty log state and persistent Connect action" width="290"></a></td>
  </tr>
</table>

<details>
<summary>Dark appearance — all four tabs</summary>

<table>
  <tr>
    <td align="center" valign="top"><strong>Overview</strong><br><a href="assets/screenshots/macos/overview-dark.png"><img src="assets/screenshots/macos/overview-dark.png" alt="macOS Overview in dark appearance showing the sample folder, permissions and connection route" width="290"></a></td>
    <td align="center" valign="top"><strong>Workspace</strong><br><a href="assets/screenshots/macos/workspace-dark.png"><img src="assets/screenshots/macos/workspace-dark.png" alt="macOS Workspace in dark appearance with file access and optional permissions" width="290"></a></td>
  </tr>
  <tr>
    <td align="center" valign="top"><strong>Connection</strong><br><a href="assets/screenshots/macos/connection-dark.png"><img src="assets/screenshots/macos/connection-dark.png" alt="macOS Connection in dark appearance with OpenAI tunnel ID and runtime API key fields" width="290"></a></td>
    <td align="center" valign="top"><strong>Activity</strong><br><a href="assets/screenshots/macos/activity-dark.png"><img src="assets/screenshots/macos/activity-dark.png" alt="macOS Activity in dark appearance with the empty log state and persistent Connect action" width="290"></a></td>
  </tr>
</table>

</details>

<details>
<summary>Advanced settings and Cloudflare — light and dark</summary>

<table>
  <tr>
    <td align="center" valign="top"><strong>Workspace — Advanced options · Light</strong><br><a href="assets/screenshots/macos/workspace-advanced-light.png"><img src="assets/screenshots/macos/workspace-advanced-light.png" alt="Workspace — Advanced options in light appearance" width="290"></a></td>
    <td align="center" valign="top"><strong>Workspace — Advanced options · Dark</strong><br><a href="assets/screenshots/macos/workspace-advanced-dark.png"><img src="assets/screenshots/macos/workspace-advanced-dark.png" alt="Workspace — Advanced options in dark appearance" width="290"></a></td>
  </tr>
  <tr>
    <td align="center" valign="top"><strong>Cloudflare — dashboard token · Light</strong><br><a href="assets/screenshots/macos/connection-cloudflare-token-light.png"><img src="assets/screenshots/macos/connection-cloudflare-token-light.png" alt="Cloudflare — dashboard token in light appearance" width="290"></a></td>
    <td align="center" valign="top"><strong>Cloudflare — dashboard token · Dark</strong><br><a href="assets/screenshots/macos/connection-cloudflare-token-dark.png"><img src="assets/screenshots/macos/connection-cloudflare-token-dark.png" alt="Cloudflare — dashboard token in dark appearance" width="290"></a></td>
  </tr>
  <tr>
    <td align="center" valign="top"><strong>Cloudflare — cloudflared login · Light</strong><br><a href="assets/screenshots/macos/connection-cloudflare-login-light.png"><img src="assets/screenshots/macos/connection-cloudflare-login-light.png" alt="Cloudflare — cloudflared login in light appearance" width="290"></a></td>
    <td align="center" valign="top"><strong>Cloudflare — cloudflared login · Dark</strong><br><a href="assets/screenshots/macos/connection-cloudflare-login-dark.png"><img src="assets/screenshots/macos/connection-cloudflare-login-dark.png" alt="Cloudflare — cloudflared login in dark appearance" width="290"></a></td>
  </tr>
</table>

</details>

Use the **Dark / Light** button beside the app name to switch appearance. Screenshot sources and capture notes are documented in [assets/screenshots/README.md](assets/screenshots/README.md).

## Platform support

| Platform | App technology | Bundled `tunnel-client` | Command shell |
| --- | --- | --- | --- |
| macOS Apple Silicon | Swift / AppKit | `darwin-arm64` | User shell (`zsh`/`sh`) |
| Windows x64 | .NET 8 / WPF | `windows-amd64` | Windows PowerShell |
| Windows ARM64 | .NET 8 / WPF | `windows-arm64` | Windows PowerShell |

The macOS build scripts understand Intel (`darwin-amd64`), but that platform is not currently bundled in this repository. Add the matching official `tunnel-client` binary and license sidecar plus the matching official ripgrep binary before building for Intel macOS.

## Requirements

For ChatGPT use:

- An account/workspace that permits custom MCP server connections. Availability and administrative permissions depend on the account and workspace; follow OpenAI's current [connection guide](https://developers.openai.com/plugins/deploy/connect-chatgpt).
- Git installed if you want to use the built-in Git tools.

Choose one connection provider:

| Provider | Requirements |
| --- | --- |
| OpenAI Secure MCP Tunnel · macOS and Windows | A tunnel associated with the intended ChatGPT workspace, plus a restricted Platform runtime API key with **Tunnels Read + Use**. Creating or editing a tunnel requires **Tunnels Read + Manage**. See the [official tunnel guide](https://developers.openai.com/api/docs/guides/secure-mcp-tunnels). |
| Cloudflare Tunnel · macOS only | `cloudflared`, a Cloudflare tunnel and a public HTTPS hostname routed to the local server. Use a dashboard token or a locally authenticated named tunnel. This route does not require an OpenAI tunnel ID or Platform runtime key. |

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

For the default OpenAI provider:

1. Open **Connection** and enter the Secure MCP Tunnel ID and runtime API key. Saved keys go to macOS Keychain or Windows Credential Manager.
2. Open **Workspace** on macOS (**Settings** on Windows) and choose the local folder to share. File tools can read, edit and delete files in that folder; additional permissions are off by default on macOS.
3. Click **Connect** to save the current configuration and start the local server and tunnel. Wait for **Connected**, then add it to ChatGPT as described [below](#add-the-mcp-server-in-chatgpt).

On macOS, **Overview** summarizes the selected folder, enabled permissions and connection route. Use the top navigation for **Workspace**, **Connection** and **Activity**. The **Dark / Light** button remembers your appearance choice across launches; before a choice is saved, startup uses the system appearance.

The macOS connection control is available on every tab. Disconnect before changing the provider, shared folder or permissions. **Activity** contains runtime logs, follow/clear controls and a copy action for troubleshooting. On Windows, connection controls are in **Connection**, and runtime output is in **Logs**. Settings saved during an active Windows session take effect the next time it starts.

Closing the window keeps sharing active. Use **Disconnect** to stop sharing or **Quit FileMCP** to stop the app.

#### Alternative: Cloudflare Tunnel (macOS)

Expose FileMCP through your own [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/). Cloudflare support is currently macOS only; OAuth is the default authentication method.

1. Install `cloudflared` (`brew install cloudflared`). FileMCP looks next to the app binary, then in `MCP_CLOUDFLARED`, `/opt/homebrew/bin`, `/usr/local/bin`, and `PATH`. It is not bundled.
2. In Cloudflare Zero Trust, create a remotely-managed tunnel and a public hostname (for example `mcp.example.com`) routing to `http://127.0.0.1:<MCP port>` (default `8008`). Route the **entire hostname**, including `/oauth/*` and `/.well-known/*`, rather than only `/mcp`.
3. In **Connection**, choose *Cloudflare Tunnel (dashboard token)* and enter the tunnel token and public hostname. Alternatively, choose *Cloudflare Tunnel (log in with cloudflared)* to log in and select or create a tunnel. Named tunnels require a local credentials JSON; use dashboard-token mode when that file is unavailable.
4. Click **Connect** and wait for **Connected**. Copy the endpoint, `https://<hostname>/mcp`, into ChatGPT. Choose **OAuth** with **dynamic client registration (DCR)**; the authorization server advertises public-client authentication (`none`), so no static client secret is required.
5. When your FileMCP authorization page opens in the browser, review the client, callback and enabled permissions. Use **Copy login code** in the macOS app and paste the code into that page. Only authorize a connection you started, on your own FileMCP hostname. Keep this code private.

FileMCP uses authorization codes with PKCE S256. Access tokens expire after one hour; refresh tokens rotate on use and expire after seven days. A reused refresh token revokes its token family. Approved client registrations and hashed token records are kept in Keychain so an app restart preserves valid sessions. Changing the workspace, enabled permissions or login code requires fresh authorization. Disconnect and use the reset button next to the endpoint to revoke sessions and reset the login code for that hostname.

The Cloudflare tunnel token and login code are also kept in Keychain. The tunnel token is passed through a private `--token-file`, removed after connection; older `cloudflared` releases without that option fall back to the environment with a warning. Tunnel output is redacted across arbitrary stdout/stderr read boundaries.

**Migration:** older Cloudflare connectors using `/mcp/<secret>` must be reconfigured for OAuth. The optional **Compatibility: use a secret in the MCP URL** setting restores that legacy no-auth client flow only after an explicit warning. It is off by default and uses a separate credential from OAuth. Anyone with a compatibility URL can use the enabled tools, and external proxies or clients may log it. Prefer OAuth.

### Add the MCP server in ChatGPT

Follow OpenAI's current [Connect and test your plugin](https://developers.openai.com/plugins/deploy/connect-chatgpt) guide. In the current Plugins interface, open **Plugins → + → Add custom MCP server**; account and workspace policies still apply.

- For OpenAI Secure MCP Tunnel, choose **Tunnel** and select the configured tunnel or enter its tunnel ID.
- For Cloudflare, enter the full HTTPS endpoint, including `/mcp`, and configure OAuth as described above.

Review the connection warning and discovered tools before creating the plugin. Keep FileMCP connected while using it. Older ChatGPT interfaces may place custom MCP setup under Developer Mode; use the current official guide for your account.

On macOS, the HTTP server limits active connections to 32, imposes a fixed 15-second deadline for receiving a complete request and a 15-second response-write deadline, and closes active sockets at shutdown. Tool processing has its own existing operation limits; these deadlines apply to network reads/writes.

FileMCP does not listen on a public network interface; the local MCP endpoint remains on `127.0.0.1`.

## Application settings

The two platforms share the core MCP tools but have different interfaces:

| Interface | macOS | Windows |
| --- | --- | --- |
| Navigation | Overview, Workspace, Connection, Activity | Connection, Settings, Logs |
| Connection action | Available on every tab | In Connection |
| Appearance toggle | Saved Dark / Light choice | No in-app toggle |
| Providers | OpenAI and Cloudflare | OpenAI |
| Optional permissions | Shell, Git push and Codex history are separate | Shell control; no separate Git push/history switches |

Technical settings live under **Advanced options**.

On macOS, **Allow Git push to remote servers** and **Allow writing to Codex history** are separate Workspace permissions, both off by default. Disabled tools are omitted from the advertised list and rejected if a client calls a cached tool name. Git push can send repository content to configured remotes and use existing SSH identities. Codex history writes outside the shared folder. These switches do not sandbox shell commands: when shell access is enabled, commands retain the OS user's privileges. Windows retains its existing permission model.


| Setting | Purpose |
| --- | --- |
| Provider | `OpenAI Secure MCP Tunnel` (default), `Cloudflare Tunnel (log in with cloudflared)` or `Cloudflare Tunnel (dashboard token)` (macOS). |
| Tunnel / Tunnel token / Public hostname | Cloudflare providers only: a tunnel in the logged-in Cloudflare account or a dashboard tunnel token (stored in Keychain), and the public hostname that routes to the local MCP port. |
| Tunnel ID | Selects the OpenAI Secure MCP Tunnel; must match `tunnel_` followed by 32 lowercase letters or digits. |
| Runtime API key | Authenticates `tunnel-client`; stored in the platform credential store. |
| Shared directory | The only filesystem root exposed to MCP file tools. |
| Allow shell commands | Enables `run_command` and the command-session tools; disabled by default. |
| Allow Git push to remote servers | macOS: separately enables `git_push`; off by default. |
| Allow writing to Codex history | macOS: separately enables `save_conversation_to_codex`; off by default. |
| Dark / Light | macOS: changes app appearance and remembers the choice independently of connection settings. |
| Profile | OpenAI `tunnel-client` profile name; starts with a letter or number, then letters/numbers plus `.`, `_`, `-`, maximum 128 characters. |
| MCP port | Local loopback port used by the MCP server. |
| Health listener | Loopback-only `tunnel-client` health/admin listener. Port `0` requests an ephemeral port. |
| Git name / Git email | Optional Git identity used by `git_commit`. |

Closing the main window does not stop an active tunnel:

- macOS: reopen FileMCP from the Dock.
- Windows: FileMCP remains available in the system tray; double-click the tray icon or choose **Open FileMCP**.

Use **Quit FileMCP** on macOS or the Windows tray menu **Quit FileMCP** action to terminate the app and stop the runtime.

## Available MCP tools

### Filesystem

| Tool | Purpose |
| --- | --- |
| `list_files` | List entries in a directory. |
| `read_file` | Read a text file. |
| `read_file_range` | Read a targeted line range with range metadata. |
| `grep` | ripgrep-backed regex or literal content search with glob/type filters, `files_with_matches`/`content`/`count` output modes, context lines, and `head_limit`/`offset` pagination. |
| `glob` | ripgrep-backed file path search with gitignore-style globs, newest-modified first, with pagination. |
| `search_code` | Rank up to six literal code queries so declarations/whole identifiers surface ahead of incidental usages; ripgrep selects candidate files, then every matching line is ranked. |
| `repo_overview` | Return factual top-level structure, detected manifests, extension counts, exclusions, and coverage metadata. |
| `batch_read` | Combine up to 16 read-only file/search/Git inspections into one MCP round trip. |
| `write_file` | Create, replace, or append to a text file. |
| `delete_file` | Delete a file or a file-like link/reparse entry. |
| `delete_directory` | Recursively delete a real directory within the workspace. |

### Coding workflow

| Tool | Purpose |
| --- | --- |
| `workspace_context` | Start a coding task with the scoped working directory, Git status, applicable `AGENTS.md` files, bounded manifest contents, and top-level entries. |
| `edit_file` | Replace one exact, unique text occurrence in an existing UTF-8 file, with optional SHA-256 conflict protection and dry-run preview. |
| `apply_patch` | Apply 1–64 ordered exact-text changes across existing UTF-8 files as one conflict-checked batch, capped at 32 MB of aggregate source files. It validates the full batch before writing, supports original-file SHA-256 guards and dry-run previews, and rolls back already-written files best-effort if a later write fails. |

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

### Codex history

| Tool | Purpose |
| --- | --- |
| `save_conversation_to_codex` | Create a durable local Codex thread from supplied `user`/`assistant` messages and group it under **Projects** using the selected workspace path. Supported on macOS and Windows. The tool writes to the current user's Codex history outside the FileMCP workspace and verifies the imported turns through Codex app-server before reporting success. |

FileMCP discovers the Codex CLI from the normal platform installation paths and `PATH`. You can override discovery with `CODEX_BIN` on either platform; on Windows, `CODEX_CLI_PATH`, Codex Desktop resource locations under `%LOCALAPPDATA%\OpenAI\Codex`, and the standalone install under `%LOCALAPPDATA%\Programs\OpenAI\Codex\bin` / `%CODEX_HOME%\packages\standalone\current` are also recognized.

### Optional command execution

```text
run_command(command, cwd="", timeout_seconds=30)
```

`run_command` is exposed only when shell-command permission is enabled in FileMCP settings. It is intentionally not placed inside an OS-level sandbox. For longer coding jobs, FileMCP also exposes `start_command`, `read_command_output`, and `cancel_command`: one runtime-owned job can stream bounded output through cursors, report a terminal state and exit code, and be cancelled with descendant cleanup.

- macOS executes through the user's configured shell, falling back to `/bin/sh`.
- Windows executes through Windows PowerShell with `-NoProfile -NonInteractive`.

Only the working directory is constrained to the shared root. Once command execution is enabled, the command itself has the normal permissions of the signed-in user.

## Security model

FileMCP intentionally treats the local workspace as a privileged boundary.

### Local networking

- The MCP server binds only to `127.0.0.1`.
- Every runtime start creates a fresh 256-bit local token. With OpenAI Secure MCP Tunnel, `tunnel-client` resolves it through `env:FILEMCP_LOCAL_AUTH_TOKEN` and injects it on requests to the local MCP origin.
- In OpenAI tunnel mode, missing or incorrect local-auth tokens are rejected before request bodies are accepted, except bodyless `GET` requests to the OAuth Protected Resource Metadata discovery paths. That mode does not advertise OAuth and returns `404 Not Found` for those paths. The local token is not persisted in the generated tunnel profile and is redacted from logs/errors.
- In macOS Cloudflare OAuth mode, public discovery/authorization routes are served without the local token; MCP tool calls require a valid OAuth access token or the internal local token. The explicitly enabled legacy compatibility mode authenticates through the secret MCP URL instead. OAuth does not remove filesystem or tool-permission checks.
- The `tunnel-client` health/admin listener is restricted to `localhost`, `127.0.0.1`, or `[::1]`; FileMCP rejects public/LAN bind addresses.
- HTTP requires a valid `Host`, validates `Origin`, rejects malformed header names/values and inconsistent body framing, and bounds request headers/bodies.
- Processes running with the same OS-user privileges (or an administrator/root-equivalent context) remain inside the local trust boundary; the per-runtime token is defense in depth, not an OS sandbox.

### Filesystem containment

- Paths are canonicalized before access.
- macOS resolves symlink targets and validates existing ancestors against the configured workspace root.
- Windows resolves existing paths through Win32 handles (`GetFinalPathNameByHandleW`) so NTFS junctions, symbolic links, and other reparse-point escapes cannot be treated as ordinary in-root paths.
- Windows containment is case-insensitive and rejects rooted/UNC input supplied where a relative workspace path is required.
- Recursive search runs the bundled ripgrep with a fixed argument set (`--no-config`, no symlink following, no preprocessors or PCRE2). Patterns and globs are passed as single `--regexp=`/`--glob=` arguments, and every returned path is re-validated against the workspace root before it is reported or read.
- Individual file reads and writes are limited to **5 MB**. `apply_patch` additionally limits a batch to **32 MB** of aggregate source data; these limits do not imply whole-repository reads.
- Text responses and search previews are truncated to bounded sizes.
- Searches respect `.gitignore`/`.ignore` files, skip `.git`, and skip the default excluded directories (`.venv`, `__pycache__`, `build`, `dist`, `node_modules`) unless `include_ignored` is set; `.git` is always skipped, including when explicitly targeted. Explicitly targeting one of the other default excluded directories as the search path remains available.
- Search output, per-file size (1 MB), ripgrep subprocess runtime (30 s), `repo_overview` directory enumeration (50,000 entries), and `search_code` ranking budgets (2,000 files / 50 MB) are bounded. Results report `truncation_reasons` (for example `head_limit`, `preview_limit`, `output_limit`, `timeout`, `search_error`, `visited_limit`, `ignore_diagnostics_limit`) instead of silently implying complete coverage. Ranking scores are deterministic ordering heuristics, not confidence values.

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

- `run_command` defaults to **30 seconds** and is capped at **120 seconds**. The separate `start_command` session API defaults to **600 seconds**, with an allowed range of **1–3,600 seconds**; one job may run at a time.
- Synchronous `run_command` and Git results cap stdout and stderr at **100 KB per stream**. Command sessions use a separate bounded combined-output buffer and expose truncation/cursor metadata.
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
                         MCP client / ChatGPT
                                  │
                 ┌────────────────┴──────────────────┐
                 │                                   │
       OpenAI Secure MCP Tunnel          Cloudflare Tunnel (macOS)
         OpenAI tunnel-client                   cloudflared
                 │                                   │
                 └────────────────┬──────────────────┘
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

OAuth for the Cloudflare route is implemented by FileMCP; `cloudflared` forwards requests to the loopback server. The two platforms use native UI and process APIs while sharing the core MCP tool behavior; Cloudflare and separate Git push/history permission switches are macOS-specific.

## MCP protocol compatibility

Both platform implementations support modern discovery and legacy Streamable HTTP initialization used by supported MCP clients:

- Modern protocol: `2026-07-28`, including `server/discover` and per-request metadata.
- Legacy protocols: `2025-03-26`, `2025-06-18`, and `2025-11-25` through `initialize` negotiation.

Tool definitions include `outputSchema`, and successful tool responses provide structured output where applicable.

## Repository layout

```text
.
├── assets/
│   ├── branding/
│   └── screenshots/macos/    # Native UI captures for this README
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
│   ├── test_swift_ui.sh
│   ├── test_swift_agent_tools.sh
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

Runtime integration suite, native UI/log regression checks and coding-tool checks:

```bash
./tests/test_swift_runtime.sh
bash tests/test_swift_ui.sh
bash tests/test_swift_agent_tools.sh
```

The UI checks include both appearances, all provider modes and connection states, four-tab navigation, long paths, action-title fit and configuration locking. Tests use isolated sample data.

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

The Windows suite exercises Credential Manager, NTFS junction/reparse-point containment, Job Object process cleanup, Git for Windows safe mode, Codex-history import through a disk-backed fake app-server, legacy/modern MCP, and the full `tunnel-client` runtime lifecycle through an isolated fake tunnel client. To additionally exercise an installed real Codex app-server and delete the fixture afterward, set `FILEMCP_REAL_CODEX_E2E=1` before running the suite.

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
