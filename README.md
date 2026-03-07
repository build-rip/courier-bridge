# Courier Bridge

A macOS bridge server that exposes Messages functionality via a REST API and WebSocket events, designed to be consumed by an Android companion app.

## Requirements

- macOS 14+
- Xcode / Swift 6.0+
- [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/) — for HTTPS tunneling during development
- [fswatch](https://github.com/emcrisostomo/fswatch) — for file watching during development

```bash
brew install cloudflared fswatch
```

## Development

### One-time tunnel setup

Create a named Cloudflare tunnel called `courier-bridge-dev` so the hostname stays stable across restarts (no re-pairing needed). This is separate from any "prod" tunnel, so both can run simultaneously:

```bash
cloudflared tunnel login
cloudflared tunnel create courier-bridge-dev
cloudflared tunnel route dns courier-bridge-dev courier-bridge-dev.build.rip
```

### Run

```bash
./dev.sh
```

This builds the server on port 7821, starts a named Cloudflare tunnel, and watches source files for changes. When you edit files under `Sources/` or `Package.swift`, the server automatically rebuilds and restarts while the tunnel stays alive — paired devices keep working without re-pairing.

The dev server runs on port 7821 (vs 7820 for prod) so both can run at the same time.

## Manual Run (no tunnel)

```bash
swift run courier-bridge
```

The server listens on `http://localhost:7820` by default. Set the `PORT` env var to override.

## Packaged App Builds

The bridge can be packaged as a background-only macOS app bundle that keeps the menu bar UI, supports launch at login, and can self-update from GitHub Releases.

### Build a local app archive

```bash
chmod +x ./Scripts/package_app.sh
./Scripts/package_app.sh
```

This creates:

- `dist/Courier Bridge.app`
- `dist/Courier-Bridge-<version>-<build>.zip`

Optional env vars:

- `COURIER_BRIDGE_VERSION_NAME=0.1.0`
- `COURIER_BRIDGE_BUILD_NUMBER=1001`
- `COURIER_BRIDGE_BUNDLE_ID=rip.build.courier.bridge`
- `COURIER_BRIDGE_CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`

### GitHub Actions prereleases

The bridge repo publishes prerelease app archives from `.github/workflows/publish-prerelease.yml`.

If you want the published build to be signed and notarized, add these repository secrets:

- `MACOS_DEVELOPER_ID_P12_B64`
- `MACOS_DEVELOPER_ID_P12_PASSWORD`
- `MACOS_DEVELOPER_ID_IDENTITY`
- `APPLE_NOTARY_API_KEY_B64`
- `APPLE_NOTARY_KEY_ID`
- `APPLE_NOTARY_ISSUER_ID`

Without those secrets, the workflow still publishes a prerelease `.zip`, but it will not be notarized.

### Runtime behavior

The packaged app runs as a menu bar app (`LSUIElement`) and defaults to launch at login. Choosing `Quit Until Restart` from the menu bar stops it until the next macOS login or manual relaunch.

## Permissions

The bridge requires two macOS permissions:

- **Full Disk Access** — to read the Messages database (`~/Library/Messages/chat.db`)
- **Accessibility** — to send messages and tapbacks via Messages.app UI automation (System Settings > Privacy & Security > Accessibility)
