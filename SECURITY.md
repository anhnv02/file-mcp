# Security Policy

FileMCP exposes powerful local capabilities: file access, Git operations, and optional shell command execution. Security reports are therefore treated as high priority.

## Supported versions

Security fixes are applied to the latest release and the current `main` branch. Older releases may not receive backports.

## Reporting a vulnerability

Do not open a public issue containing exploit details, secrets, tokens, private file contents, or sensitive logs.

Use [GitHub private vulnerability reporting](https://github.com/anhnv02/file-mcp/security/advisories/new) when it is enabled. If that page is unavailable, do not post exploit details in a public issue; arrange a private channel with the repository maintainer before sharing details. Maintainers must enable and verify private reporting before announcing a public release.

Include, when relevant:

- the affected version or commit;
- operating system and architecture;
- the impacted tool or protocol path;
- reproduction steps with sanitized test data;
- expected versus observed behavior;
- whether the issue crosses the configured shared-directory boundary, executes unexpected commands, exposes credentials, or bypasses MCP/Git safety controls.

## Security model assumptions

- The MCP HTTP listener is loopback-only. OpenAI Secure MCP Tunnel mode uses a fresh 256-bit per-runtime local header token. Cloudflare on macOS uses OAuth by default; legacy URL-secret authentication is a separate, explicit compatibility option. Authentication is checked before processing MCP bodies. Processes with the same OS-user privileges (or administrator/root-equivalent privileges) remain inside the local trust boundary.
- On macOS, active HTTP sockets are capped at 32. A complete request must arrive within 15 seconds; response writes have a separate 15-second deadline. These absolute deadlines do not reset when a slow client sends another byte. Shutdown cancels all tracked connections. The Windows HTTP implementation has not received these macOS-specific resource-limit changes.
- Cloudflare OAuth uses public-client DCR, authorization-code grants with PKCE S256, explicit resource binding and exact registered callback matching. Authorization requires the app's independent 256-bit login code; that code never appears in the MCP endpoint or authorization page. Authorization codes last 60 seconds, access tokens one hour and rotating refresh tokens seven days. Refresh-token replay revokes the affected token family. Registrations, pending requests and token records are bounded; registration and login attempts are rate-limited.
- OAuth grant records are stored as token hashes in macOS Keychain. Restart preserves valid sessions. Changing workspace, enabled permissions, issuer or login code invalidates previous grants. Resetting the login code or all settings revokes the stored sessions. The OAuth authorization page uses a random form request identifier, explicit credential entry, frame restrictions and a same-origin referrer policy that suppresses cross-origin referrers while preserving the browser Origin on authorization form submissions. Responses disable caching.
- Legacy Cloudflare URL-secret compatibility is off by default and requires a warning before enabling. Its secret is separate from the OAuth login code. A copied URL grants all enabled MCP capabilities and may be captured by external client/proxy logs; FileMCP cannot redact third-party systems. Prefer OAuth.
- The bundled tunnel health/admin listener is also loopback-only. FileMCP rejects public/LAN health bind addresses and passes the validated address explicitly to tunnel startup.
- Built-in filesystem and safe-mode Git tools enforce application-level containment, not an operating-system sandbox.
- macOS containment must account for symbolic links; Windows containment must account for case-insensitive paths, symbolic links, junctions, and other reparse points.
- On macOS, Git push and Codex-history writing require independent Workspace permissions, both disabled by default. Disabled tools are neither advertised nor callable. `git_push` can transmit repository contents to a remote server and use allowed SSH identities. `save_conversation_to_codex` intentionally writes supplied messages to Codex history outside the shared root; it does not execute imported conversations. Windows retains its existing tool-permission model.
- Enabling shell tools (`run_command` and command sessions) intentionally grants shell execution with the current OS user's permissions. Only the command working directory is constrained to the shared root; the command itself can access anything that user account can access.
- Git safe mode validates worktree/Git/common/object/config metadata, alternates, embedded repositories, and config includes; suppresses hooks/filters/external diffs/templates/signing; resets credential helpers; and disables SSH config-driven `ProxyCommand`/`ProxyJump`. ssh-agent/default SSH identities can still participate in an allowed SSH push.
- FileMCP-generated tunnel profiles live in an app-owned profile directory. `tunnel-client` receives an allowlisted child environment so ambient tunnel configuration cannot silently replace the local MCP target, health policy, or raw HTTP logging policy.
- Runtime API keys belong in the platform credential store (macOS Keychain or Windows Credential Manager), never the plain settings file.

## Sensitive areas

Changes involving any of the following deserve explicit security review:

- path canonicalization, symbolic links, junctions, or reparse-point handling;
- file deletion or write boundaries;
- Git worktree/Git/common/object/config metadata, alternates, embedded repositories, config includes, hooks, filters, credential helpers, transports, or external diff behavior;
- `run_command`, process groups/Job Objects, and descendant-process lifecycle;
- HTTP framing, local-auth/Host/Origin validation, MCP protocol negotiation, and tool argument validation;
- Keychain/Credential Manager storage, tunnel profile/environment isolation, health/admin binding, or secret propagation to `tunnel-client`;
- vendored `tunnel-client` updates and release checksum verification.

## Secrets in reports and tests

Use fake credentials in examples and tests. Never attach a real `.env`, `.oauth_store.json`, API key, tunnel credential, repository credential, credential-store export, or archive of a developer working directory.

## Before publishing source

Run `bash tests/check_secrets.sh` with Gitleaks installed. The CI secret-scan job installs Gitleaks 8.30.1, fetches full Git history and scans reachable commits plus the publishable working tree. Reports are redacted; do not upload raw findings as public artifacts. Also review ignored files, archived releases and any host-side refs that are not present in your local clone. A passing pattern scan does not prove that all secrets or private data have been found.

If a real credential was committed, revoke or rotate it before considering history cleanup. Deleting the latest copy does not revoke a credential or erase prior commits. Never publish a working-directory ZIP containing local settings or credential files; use the tracked-source archive workflow after committing and reviewing the final tree.
