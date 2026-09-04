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
- Codex project-skill discovery and loading from `.agents/skills/<name>/SKILL.md` through the read-only `list_codex_skills` and `load_codex_skill` MCP tools.
- Skill lifecycle logging with `[Skills]` messages for scan, discovery, loading, validation failures, and missing skills.

### Changed

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
- Improved the macOS Logs view so buffered runtime and skill logs render reliably after connecting or switching to the Logs tab.
