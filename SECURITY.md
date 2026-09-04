# Security Policy

FileMCP exposes powerful local capabilities: file access, Git operations, and optional shell command execution. Security reports are therefore treated as high priority.

## Supported versions

Security fixes are applied to the latest release and the current `main` branch. Older releases may not receive backports.

## Reporting a vulnerability

Do not open a public issue containing exploit details, secrets, tokens, private file contents, or sensitive logs.

Use GitHub's private vulnerability reporting or a private security advisory when available. If private reporting is unavailable, contact the maintainers through GitHub first and share technical details only after a private channel has been established.

Include, when relevant:

- the affected version or commit;
- operating system and architecture;
- the impacted tool or protocol path;
- reproduction steps with sanitized test data;
- expected versus observed behavior;
- whether the issue crosses the configured shared-directory boundary, executes unexpected commands, exposes credentials, or bypasses MCP/Git safety controls.

## Security model assumptions

- The MCP HTTP listener is loopback-only and requires a fresh 256-bit per-runtime token. Missing or incorrect tokens are rejected before request bodies are accepted. Processes with the same OS-user privileges (or administrator/root-equivalent privileges) remain inside the local trust boundary.
- The bundled tunnel health/admin listener is also loopback-only. FileMCP rejects public/LAN health bind addresses and passes the validated address explicitly to tunnel startup.
- Built-in filesystem and safe-mode Git tools enforce application-level containment, not an operating-system sandbox.
- macOS containment must account for symbolic links; Windows containment must account for case-insensitive paths, symbolic links, junctions, and other reparse points.
- Enabling `run_command` intentionally grants shell execution with the current OS user's permissions. Only the command working directory is constrained to the shared root; the command itself can access anything that user account can access.
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


## Codex project skills

Codex project skills are treated as workspace-controlled instructions, not trusted application code. FileMCP only discovers direct child skill directories under `.agents/skills` and loads the exact `SKILL.md` selected by name. Skill loading is read-only, refuses path traversal and symlink/reparse-point escapes, requires valid UTF-8, and rejects files larger than 256 KB instead of truncating them.

Loading a skill does not grant new capabilities by itself. A `SKILL.md` can ask the model to use existing FileMCP tools, including `run_command` when the user has explicitly enabled shell execution, so users should review skills in untrusted repositories before invoking them. FileMCP logs skill discovery/loading metadata but does not copy the full skill instructions into application logs.
