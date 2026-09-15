# Changelog

All notable changes will be documented in this file from the first public release onward.

The repository has private development history from before its open-source publication. That history is intentionally not reconstructed here as release history.

## Unreleased

### Added

- Open-source project license and contribution/security documentation.
- GitHub Actions macOS and Windows CI verification.
- Reproducible source-archive packaging from tracked Git content only.
- Explicit provenance and checksum documentation for the vendored OpenAI `tunnel-client` binary.
- New FileMCP macOS app icon optimized for the Dock.
- Native Windows application with WPF UI, system-tray lifecycle, Windows Credential Manager storage, and x64/ARM64 release packaging.
- Windows parity integration coverage for filesystem containment, NTFS junction/reparse points, Git safe mode, Job Object process cleanup, MCP legacy/modern protocols, and tunnel runtime lifecycle.
- Cross-platform `save_conversation_to_codex` support for importing supplied conversations into Codex local history on macOS and Windows, with post-write app-server verification.
- Cross-platform `batch_read` support for combining up to 16 read-only file, search, and Git inspection operations into one MCP round trip.
- Cross-platform ranked `search_code` with multi-query single-pass scanning, transparent relevance signals, and coverage metadata.
- Cross-platform ripgrep-backed `grep` and `glob` tools modeled on coding-agent search: regex/literal patterns, glob and file-type filters, content/count/file output modes, context lines, newest-first file ordering, and `head_limit`/`offset` pagination.
- Bundled official ripgrep 15.2.0 binaries (macOS arm64, Windows x64/ARM64) with documented provenance, checksums, and license files.
- Per-tool-call timing and response-size log lines (tool name only; no arguments or content).
- Cross-platform `repo_overview` for factual repository structure, manifest, extension-count, exclusion, and scan-coverage context.
- Cross-platform `workspace_context` for scoped coding context, including Git status, applicable `AGENTS.md`, bounded manifest contents, and top-level workspace entries.
- Cross-platform conflict-checked `edit_file` and batched `apply_patch` tools with dry-run previews, SHA-256 guards, ordered multi-hunk edits, pre-write validation, and best-effort rollback of partial multi-file writes.
- Cross-platform session command tools (`start_command`, `read_command_output`, and `cancel_command`) with bounded cursor-based streaming, idempotent request IDs, timeout/cancellation states, retained output, and descendant-process cleanup.

### Changed

- Replaced the hand-written recursive scanners behind `search_code` and `repo_overview` with ripgrep, and replaced `search_content`/`search_filenames` with `grep`/`glob`. Searches now respect `.gitignore`/`.ignore` by default (opt out with `include_ignored`), always reject explicit `.git` targets, and avoid prematurely exhausting recursive-scan byte budgets on binary or build-output trees while reporting bounded/truncated coverage explicitly.

- Updated the bundled OpenAI `tunnel-client` to v0.0.12 with upstream NOTICE and third-party license evidence, including official Windows AMD64/ARM64 binaries.
- Rebranded the macOS app and MCP server identity from Local Files MCP to FileMCP.
- Updated the app bundle/executable names, default profile, default shared folder, documentation, and release artifact naming for FileMCP.
- Removed the persistent menu-bar status item; FileMCP now relies on the Dock and the standard macOS application menu.
- Moved the quit action into a fixed window footer and made advanced settings resize the window between compact and expanded states.
- Polished the native macOS UI with a wider layout, clearer connection-state actions, English labels/errors/runtime messages, collapsible advanced settings, and standard App/Edit/Window menus.
- Preserved the existing bundle identifier and Keychain namespace so local settings and saved runtime credentials continue to migrate safely across the rebrand.
- Hardened local HTTP parsing with required local authentication, strict `Host`/`Origin` and header syntax checks, bounded framing, and rejection of trailing body bytes.
- Added a fresh per-runtime 256-bit token between `tunnel-client` and the loopback MCP server; the token is referenced through an environment indirection, not persisted in generated tunnel profiles, and redacted from logs/errors.
- Restricted the `tunnel-client` health/admin listener to loopback, isolated FileMCP tunnel profiles under Application Support, and allowlisted the child tunnel environment to prevent ambient config overrides.
- Hardened Git safe mode across Git/config/common/object/alternate metadata, repository config includes, embedded repositories, external init templates, HTTP credential/TLS file settings, credential helpers, SSH config execution paths, and MCP-internal TOCTOU races.
- Hardened process execution by validating launch inputs before spawn and cleaning descendant process trees on parent exit, timeout, stop, and shutdown (POSIX process groups on macOS; Job Objects on Windows).
- HTTP malformed-request fuzz iterations can be reduced through `MCP_HTTP_FUZZ_ITERATIONS` for targeted development/CI runs while preserving the full default count.
- Scoped recursive filename search can reduce unnecessary local traversal when callers already know the relevant subdirectory, without changing default broad-search coverage.
- Content search now reports explicit truncation reasons so callers can distinguish result, preview, visited-entry, and byte-budget limits.
