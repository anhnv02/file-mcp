# Contributing

Contributions are welcome. Because this project can read and mutate local files and optionally execute commands, changes should preserve the existing security boundaries rather than bypass them for convenience.

## Development requirements

- macOS 12 or newer;
- Xcode or Xcode Command Line Tools with `swiftc`;
- the vendored `tunnel-client` binary for the current architecture.

Build the app:

```bash
./build_macos_app.sh
```

Run the integration suite:

```bash
./tests/test_swift_runtime.sh
```

For a quicker parser-fuzz pass while developing, reduce only the malformed HTTP iteration count:

```bash
MCP_HTTP_FUZZ_ITERATIONS=20 ./tests/test_swift_runtime.sh
```

The default remains the full fuzz count used for local verification.

## Change guidelines

- Inspect the owning code and existing tests before editing.
- Keep both the MCP listener and tunnel health/admin listener loopback-only unless the security model is deliberately redesigned and reviewed.
- Do not weaken shared-directory containment, symlink handling, Git metadata/config checks, MCP-local authentication, tunnel profile/environment isolation, process cleanup, request-size limits, or argument validation.
- Keep `run_command` opt-in and clearly destructive.
- Add or update tests for behavior changes, especially security-boundary changes.
- Do not commit generated `build/` or `dist/` output.
- Never commit API keys, OAuth stores, tokens, local Git credentials, Keychain exports, `.env` files, or archives of a working directory.

## Vendored tunnel-client updates

When updating `vendor/tunnel-client`:

1. use an official `openai/tunnel-client` release;
2. verify the platform archive against the upstream `SHA256SUMS.txt`;
3. verify the extracted binary byte-for-byte or by SHA-256;
4. update `vendor/tunnel-client/VERSION` and its provenance documentation;
5. keep the upstream `LICENSE`, `NOTICE`, and platform third-party license evidence with the binary;
6. run the full test suite and app build.

## Pull / merge requests

Describe the behavior changed, security impact, and commands used for verification. Keep unrelated refactors out of security-sensitive patches so review remains auditable.
