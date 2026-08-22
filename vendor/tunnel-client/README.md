# Bundled tunnel-client

This directory contains official OpenAI `tunnel-client` binaries bundled with FileMCP.

## Current provenance

- Upstream repository: `https://github.com/openai/tunnel-client`
- Release: `v0.0.12`
- Upstream source commit: `881c9a8fed7cccbe6607cd419863bbca506b8215`
- Version output: `0.0.12+881c9a8fed7cccbe6607cd419863bbca506b8215`

| Target | Official release archive SHA-256 | Bundled executable SHA-256 |
| --- | --- | --- |
| `darwin-arm64` | `42fb3138dc9c081d5777cb7e8bd1e041cc48b67c4978dbab3c5167ca1aabca02` | `b1757220cf4722cec9085ee4a908cf0ee4c1a499a33bd99979b9a9c7669e29b1` |
| `windows-amd64` | `2a2804933924e38a502d62b61f0266cb80d56d65744f4c29876b2bf9c1544356` | `6649169733686805ca16cccd91774594d0c017fd729c37ad4ce1cd18323d9ae8` |
| `windows-arm64` | `65ab54221554481bb1c23b6015b99abe0b7f79b08593f4fb17a9e2e25532281d` | `480684ec1031fc2985c7e87f9d669e7dfda4012a8ecdab21eabe1b5deafdd656` |

Every archive checksum was verified against the official release `SHA256SUMS.txt`, and each bundled executable was extracted from its verified archive. The annotated `v0.0.12` tag resolves to source commit `881c9a8fed7cccbe6607cd419863bbca506b8215`.

## License evidence

The following files are preserved from the official release artifacts:

- `LICENSE` — upstream Apache License 2.0 text.
- `NOTICE` — upstream OpenAI notice.
- `<target>/THIRD-PARTY-LICENSES.txt` — platform-specific third-party license sidecar published with the corresponding release archive.

The macOS and Windows build scripts copy the matching legal notices into distributable application packages.

## Verification

For an update, download each platform ZIP and `SHA256SUMS.txt` from the same official GitHub release, verify the archive, then verify the extracted executable before replacing the vendored copy.

macOS example:

```bash
shasum -a 256 tunnel-client-v0.0.12-darwin-arm64.zip
shasum -a 256 vendor/tunnel-client/darwin-arm64/tunnel-client
vendor/tunnel-client/darwin-arm64/tunnel-client --version
```

Windows example:

```powershell
Get-FileHash tunnel-client-v0.0.12-windows-amd64.zip -Algorithm SHA256
Get-FileHash vendor/tunnel-client/windows-amd64/tunnel-client.exe -Algorithm SHA256
vendor/tunnel-client/windows-amd64/tunnel-client.exe --version
```

The full `tunnel-client` is bundled rather than the run-only runtime artifact because FileMCP uses the `init`, `doctor`, and `run` commands.

The optional `cloudflared` binary included in upstream distribution archives is intentionally not bundled by FileMCP.

Add the matching official release binary and legal sidecar under another `<os>-<arch>` target before building a platform that is not currently bundled. Build scripts select only the executable for the target platform and never download executables at runtime.
