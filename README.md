# Tally

Tally is a local-first SwiftUI app for tracking subscriptions from manual entries and imported transaction files. It is designed for personal finance workflows: see what renews soon, spot price changes, audit overlap, and keep the data on devices the user controls.

## Privacy Model

- No hosted Tally backend.
- No third-party analytics, ad SDKs, or telemetry SDKs.
- Transaction and subscription data are stored with SwiftData.
- CloudKit sync is optional and uses the user's own Apple/iCloud account when a valid container is configured.
- CSV/XLS/XLSX imports are read from user-selected files.
- Optional local Gemma support downloads `gemma-4-E4B-it-Q4_K_M.gguf` from Hugging Face, then runs inference locally on macOS.

See [PRIVACY.md](PRIVACY.md) for the full data-flow notes.

## Install

Install the macOS app with Homebrew:

```sh
brew tap chountalas/tap
brew install --cask tally
```

Update it later with:

```sh
brew update
brew upgrade --cask tally
```

## Requirements

- Current Xcode with Swift 6 and the Apple platform SDKs used by `project.yml`
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Optional: SwiftLint

## Local Setup

Clone with submodules so the legacy XLS importer sources are present:

```sh
git clone --recurse-submodules https://github.com/chountalas/tally.git
cd tally
```

Generate the project:

```sh
xcodegen generate
```

Open `Tally.xcodeproj` in Xcode, or build from the command line:

```sh
xcodebuild build -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived
```

Run tests:

```sh
xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived
```

## Signing And iCloud

The repo ships local-only public defaults in [Config/Tally.xcconfig](Config/Tally.xcconfig). The macOS target signs to run locally and keeps App Sandbox enabled. For a real device build or CloudKit sync, copy the example config and set values owned by your Apple developer account:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Then edit `Config/Local.xcconfig`:

```xcconfig
TALLY_BUNDLE_IDENTIFIER = com.example.Tally
TALLY_DEVELOPMENT_TEAM = ABCDE12345
TALLY_ICLOUD_CONTAINER_IDENTIFIER = iCloud.com.example.Tally
```

`Config/Local.xcconfig` is intentionally ignored by git.

CloudKit entitlements are intentionally not enabled in the public defaults because they require a real Apple developer team and container. If you want iCloud sync, add the iCloud capability in Xcode using your own container, or copy the example entitlement files in `Tally/Resources/*.iCloud.*.entitlements.example` and point `CODE_SIGN_ENTITLEMENTS` at your local copies.

If CloudKit is not configured or cannot start, Tally falls back to local-only storage.

## Repository Hygiene

- Do not commit real bank exports or screenshots containing personal finance data.
- Do not commit provisioning profiles, certificates, local xcconfig overrides, or API credentials.
- Regenerate `Tally.xcodeproj` with `xcodegen generate` after changing `project.yml`.
- Keep third-party notices current when changing dependencies or bundled assets.

## License

Tally is available under the MIT License. Third-party libraries, assets, models, and trademarks remain under their respective licenses and owner terms; see [NOTICE.md](NOTICE.md).
