# Native macOS screenshots

Captured on 2026-10-27 from the current `macos/FileMCPApp.swift` AppKit renderer, using the isolated `previewInterface()` fixture in `tests/SwiftUILogChecks.swift`.

The capture host was a temporary app bundle under ignored `build/readme-preview/`. It did not load saved settings, read Keychain or start a tunnel. The fixture disables credential, connection and account-management actions. Navigation, appearance, disclosure controls and provider selection use the actual native implementation.

All folder names, paths, hostnames and Cloudflare account status are sample data. Password fields are empty. Every screenshot shows a disconnected state; the Cloudflare “Logged in” label is fixture data, not proof of a live account session. Windows is not pictured.

## Coverage

Four tabs in both appearances:

- `overview-{light,dark}.png`
- `workspace-{light,dark}.png`
- `connection-{light,dark}.png` — default OpenAI provider
- `activity-{light,dark}.png` — empty activity state

Additional native configurations in both appearances:

- `workspace-advanced-{light,dark}.png`
- `connection-cloudflare-token-{light,dark}.png`
- `connection-cloudflare-login-{light,dark}.png`

## Capture notes

Screenshots were captured through native computer-use window screenshots, then losslessly saved as PNG. The top 64 device pixels (the 32pt title bar on this 2× display) were cropped to exclude the OS screen-sharing indicator. App content, colors and controls were not reconstructed or retouched. Window height follows the native page layout, so image heights differ by screen.

To refresh, build an isolated preview bundle from the current app source plus the fixture; navigate each tab/provider in light and dark, move the pointer into the title bar and capture the window. Keep all sharing and optional permissions off, never load production defaults, and visually review every image before replacing these files. Referenced files and captions in the root README must stay in sync.
