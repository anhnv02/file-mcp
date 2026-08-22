# Contributing

Contributions are welcome. Because this project can read and mutate local files and optionally execute commands, changes should preserve the existing security boundaries rather than bypass them for convenience.

## Development requirements

### macOS

- macOS 12 or newer;
- Xcode or Xcode Command Line Tools with `swiftc`;
- the vendored `tunnel-client` binary for the current architecture.

Build and test:

```bash
./build_macos_app.sh
./tests/test_swift_runtime.sh
```

For a quicker parser-fuzz pass while developing:

```bash
MCP_HTTP_FUZZ_ITERATIONS=20 ./tests/test_swift_runtime.sh
```

### Windows

- Windows 10/11;
- .NET 8 SDK;
- Git for Windows;
- the vendored `tunnel-client.exe` for the target architecture.

Build and test from PowerShell:

```powershell
dotnet build windows/FileMCP.Windows.sln -c Release -warnaserror
./tests/test_windows_runtime.ps1
```

Build distributable packages with:

```powershell
./build_windows_app.ps1 -Architecture x64
./build_windows_app.ps1 -Architecture arm64
```

The Windows integration suite intentionally exercises Windows Credential Manager, junction/reparse-point containment, Job Object process cleanup, Git for Windows safe mode, raw MCP/HTTP behavior, and tunnel-runtime lifecycle.

## Change guidelines

- Inspect the owning code and existing tests before editing.
- Preserve equivalent MCP tool/protocol behavior across macOS and Windows unless a documented platform constraint makes equivalence impossible.
- Keep both the MCP listener and tunnel health/admin listener loopback-only unless the security model is deliberately redesigned and reviewed.
- Do not weaken shared-directory containment, symlink/reparse-point handling, Git metadata/config checks, MCP-local authentication, tunnel profile/environment isolation, process cleanup, request-size limits, or argument validation.
- Keep `run_command` opt-in and clearly destructive.
- Add or update platform-specific regression tests for behavior/security changes.
- Do not commit generated `build/`, `dist/`, `bin/`, or `obj/` output.
- Never commit API keys, OAuth stores, tokens, local Git credentials, Keychain/Credential Manager exports, `.env` files, or archives of a working directory.

## Vendored tunnel-client updates

When updating `vendor/tunnel-client`:

1. use an official `openai/tunnel-client` release;
2. verify every bundled platform archive against upstream `SHA256SUMS.txt`;
3. verify each extracted binary by SHA-256;
4. update `vendor/tunnel-client/VERSION` and its provenance documentation;
5. keep the upstream `LICENSE`, `NOTICE`, and platform third-party license evidence with each binary;
6. run the relevant macOS and Windows test/build jobs.

## Pull requests

Describe the behavior changed, security impact, affected platforms, and exact verification commands/results. Keep unrelated refactors out of security-sensitive patches so review remains auditable.
