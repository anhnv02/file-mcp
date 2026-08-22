# Bundled tunnel-client

This directory contains the official OpenAI `tunnel-client` binary bundled with FileMCP.

## Current provenance

- Upstream repository: `https://github.com/openai/tunnel-client`
- Release: `v0.0.12`
- Upstream source commit: `881c9a8fed7cccbe6607cd419863bbca506b8215`
- Bundled target: `darwin-arm64/tunnel-client`
- Version output: `0.0.12+881c9a8fed7cccbe6607cd419863bbca506b8215`
- Official `darwin-arm64` release archive SHA-256: `42fb3138dc9c081d5777cb7e8bd1e041cc48b67c4978dbab3c5167ca1aabca02`
- Bundled `tunnel-client` binary SHA-256: `b1757220cf4722cec9085ee4a908cf0ee4c1a499a33bd99979b9a9c7669e29b1`

The archive checksum was verified against the release's official `SHA256SUMS.txt`, and the bundled executable is the `tunnel-client` binary extracted from that verified archive. The annotated `v0.0.12` tag resolves to source commit `881c9a8fed7cccbe6607cd419863bbca506b8215`.

## License evidence

The following files are preserved from the official release artifact:

- `LICENSE` — upstream Apache License 2.0 text.
- `NOTICE` — upstream OpenAI notice.
- `darwin-arm64/THIRD-PARTY-LICENSES.txt` — the platform-specific third-party license sidecar published with the `darwin-arm64` release.

`build_macos_app.sh` copies these legal notices into the application bundle when FileMCP is built for redistribution.

## Verification

For an update, download the platform ZIP and `SHA256SUMS.txt` from the same official GitHub release, then verify before replacing the vendored binary:

```bash
shasum -a 256 tunnel-client-v0.0.12-darwin-arm64.zip
shasum -a 256 vendor/tunnel-client/darwin-arm64/tunnel-client
vendor/tunnel-client/darwin-arm64/tunnel-client --version
```

The full `tunnel-client` is bundled rather than the run-only runtime artifact because FileMCP uses the `init`, `doctor`, and `run` commands.

The optional `cloudflared` binary included in upstream distribution archives is intentionally not bundled by FileMCP.

Add the matching official release binary and corresponding legal sidecars under another `<os>-<arch>` target before building that platform. `build_macos_app.sh` embeds only the binary for the current target and never downloads executables at runtime.
