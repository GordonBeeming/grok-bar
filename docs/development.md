# Development and release guide

Contributor and maintainer details that don't belong in the README.

## Requirements

- macOS 15 or later on Apple Silicon
- Xcode with Swift 6.1 or later
- The Grok CLI installed and signed in with `grok login`, if you want live usage data

## Build and test

```sh
make test
```

That runs `swift build --build-tests`, then `xcrun xctest` on `GrokBarCoreTests.xctest`. On the Swift 6.4 toolchain, `swift test` only runs Swift Testing and reports zero tests even when the XCTest bundle built, so the Makefile and CI don't use it.

A release binary, without packaging:

```sh
make build
```

## Run and install

```sh
make run
```

`swift run` doesn't create an app bundle, so launch-at-login controls only work in an installed build.

```sh
make bundle
open dist/GrokBar.app
```

`make bundle` writes `dist/GrokBar.app`. `make install` does the same, then replaces `/Applications/GrokBar.app` and quits a running GrokBar first.

You can override the bundle metadata and signing:

```sh
make bundle VERSION=0.3 BUILD=42 CODESIGN_IDENTITY="Developer ID Application: YOUR_NAME (TEAM_ID)" CODESIGN_OPTS="--options runtime --timestamp"
```

## Project structure

- `Sources/GrokBarCore` holds billing models, usage mapping, formatting, severity thresholds, celebration detection, snapshot stabilization, and the telemetry encoder.
- `Sources/GrokBar` holds the CLI client, settings, menu-bar UI, reactions, launch-at-login, and the sparkle icon.
- `Tests/GrokBarCoreTests` covers the core behavior.
- `Packaging/Info.plist`, `Packaging/AppIcon.icns`, and `Makefile` build the app bundle. The bundle id is `com.gordonbeeming.GrokBar`. The URL scheme is `grokbar`.
- `.github/workflows/build.yml` runs CI and publishes releases.

## Release process

Releases use a `vX.Y` tag, for example `v0.1`. Publishing the GitHub release runs the release job, which:

1. Builds and tests all targets.
2. Imports the Developer ID certificate into a temporary keychain.
3. Builds and signs `GrokBar.app` with the hardened runtime and a timestamp.
4. Verifies the signature, submits the app for notarization, and staples the ticket.
5. Creates and uploads `GrokBar-X.Y.dmg`.
6. Updates `GordonBeeming/homebrew-tap` at `Casks/grok-bar.rb` with the version and SHA-256. The cask is arm64 and requires macOS Sequoia.
7. Signs that cask commit and pushes it with the tap's deploy key.

The `prod` GitHub environment has to exist on this repository before a release will succeed. It provides:

- `DEVELOPER_ID_CERTIFICATE` (base64-encoded `.p12`)
- `DEVELOPER_ID_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_PASSWORD`
- `HOMEBREW_TAP_DEPLOY_KEY`
- `COMMIT_SIGNING_KEY`

`COMMIT_SIGNING_KEY` has to be an OpenSSH private key. Git's SSH signing helper doesn't accept the PKCS#8 export some password managers produce. A release published before those secrets are on `prod` fails in the release job on purpose.
