# Bundled ripgrep

This directory contains official `ripgrep` (`rg`) binaries bundled with FileMCP. The `grep`, `glob`, `search_code`, and `repo_overview` tools run this executable with a fixed, validated argument set.

## Current provenance

- Upstream repository: `https://github.com/BurntSushi/ripgrep`
- Release: `15.2.0`
- Version output: `ripgrep 15.2.0 (rev e89fff89ac)`

| Target | Official release archive | Archive SHA-256 | Bundled executable SHA-256 |
| --- | --- | --- | --- |
| `darwin-arm64` | `ripgrep-15.2.0-aarch64-apple-darwin.tar.gz` | `3750b2e93f37e0c692657da574d7019a101c0084da05a790c83fd335bad973e4` | `a326a1fb48074202e9ad41e4cd1e389eeea372c8c6f7d7e80da81176d5d9430e` |
| `windows-amd64` | `ripgrep-15.2.0-x86_64-pc-windows-msvc.zip` | `71b2fef860abe467217a538ff31de02f5258807c0129f771846f87bd029aafc5` | `14231169855ec5205cf5a1b6f1db358ff4aed4247c86b69ce8aae647c77f6680` |
| `windows-arm64` | `ripgrep-15.2.0-aarch64-pc-windows-msvc.zip` | `e4abca10c3a64ebea742667dd7009449d49403db5460dd6873e389fa2945360f` | `d33a29a9ef03c9f4c03be9e8d88498e6e2d2e566d64cdbdef97f9afc8f13120c` |

Every archive checksum was verified against the `.sha256` file published with the same release, and each bundled executable was extracted from its verified archive.

## License evidence

ripgrep is dual-licensed under the Unlicense and MIT licenses. The following files are preserved from the official release archives:

- `COPYING` — upstream dual-license statement.
- `LICENSE-MIT` — MIT license text.
- `UNLICENSE` — Unlicense text.

The Windows archives contain the same text with CRLF line endings; the LF copies from the macOS archive are stored here. The macOS and Windows build scripts copy these notices into distributable application packages.

## Verification

For an update, download each platform archive and its `.sha256` file from the same official GitHub release, verify the archive, then verify the extracted executable before replacing the vendored copy. Update `VERSION`, this file, and the pinned checksums in `.github/workflows/verify.yml`.

macOS example:

```bash
gh release download 15.2.0 -R BurntSushi/ripgrep -p 'ripgrep-15.2.0-aarch64-apple-darwin.tar.gz*'
shasum -a 256 ripgrep-15.2.0-aarch64-apple-darwin.tar.gz
shasum -a 256 vendor/ripgrep/darwin-arm64/rg
vendor/ripgrep/darwin-arm64/rg --version
```
