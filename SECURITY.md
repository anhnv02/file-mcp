# Security Policy

FileMCP exposes powerful local capabilities: file access, Git operations, and optional shell command execution. Security reports are therefore treated as high priority.

## Supported versions

Security fixes are applied to the latest release and the current `main` branch. Older releases may not receive backports.

## Reporting a vulnerability

Do not open a public issue containing exploit details, secrets, tokens, private file contents, or sensitive logs.

Use GitHub's private vulnerability reporting or a private security advisory when available. If private reporting is unavailable, contact the maintainers through GitHub first and share technical details only after a private channel has been established.

Include, when relevant:

- the affected version or commit;
- macOS and architecture;
- the impacted tool or protocol path;
- reproduction steps with sanitized test data;
- expected versus observed behavior;
- whether the issue crosses the configured shared-directory boundary, executes unexpected commands, exposes credentials, or bypasses MCP/Git safety controls.

## Security model assumptions

- The MCP HTTP listener is loopback-only and requires a fresh 256-bit per-runtime token. Missing or incorrect tokens are rejected before request bodies are accepted. Processes with the same macOS user privileges, or root, remain inside the local trust boundary.
- The bundled tunnel health/admin listener is also loopback-only. FileMCP rejects public/LAN health bind addresses and passes the validated address explicitly to tunnel startup.
- Built-in filesystem and safe-mode Git tools enforce application-level containment, not an operating-system sandbox.
- Enabling `run_command` intentionally grants shell execution with the current macOS user's permissions. Only the command working directory is constrained to the shared root; the command itself can access anything that user account can access.
- Git safe mode validates worktree/Git/common/object/config/alternate metadata, rejects repository config includes and embedded-repository escapes, suppresses hooks/filters/external diffs/templates/signing, resets credential helpers, and disables SSH config-driven `ProxyCommand`/`ProxyJump`. ssh-agent/default SSH identities can still participate in an allowed SSH push.
- FileMCP-generated tunnel profiles live in an app-owned profile directory. `tunnel-client` receives an allowlisted child environment so ambient tunnel configuration cannot silently replace the local MCP target, health policy, or raw HTTP logging policy.

## Sensitive areas

Changes involving any of the following deserve explicit security review:

- path canonicalization and symlink handling;
- file deletion or write boundaries;
- Git worktree/Git/common/object/config metadata, alternates, embedded repositories, config includes, hooks, filters, credential helpers, transports, or external diff behavior;
- `run_command` and process-group lifecycle;
- HTTP framing, local-auth/Host/Origin validation, MCP protocol negotiation, and tool argument validation;
- Keychain storage, tunnel profile/environment isolation, health/admin binding, or secret propagation to `tunnel-client`;
- vendored `tunnel-client` updates and release checksum verification.

## Secrets in reports and tests

Use fake credentials in examples and tests. Never attach a real `.env`, `.oauth_store.json`, API key, tunnel credential, repository credential, Keychain export, or archive of a developer working directory.
