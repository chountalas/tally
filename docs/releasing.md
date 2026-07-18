# Releasing Tally for macOS

The repository supports two packaging paths:

- `./scripts/package_release.sh` builds arm64 ZIP and DMG artifacts in `dist/`. It uses ad-hoc signing by default, which is suitable for local artifact inspection but not public distribution.
- `./scripts/release.sh` signs with a Developer ID certificate, submits the app and disk image to Apple for notarization, staples the tickets, and verifies Gatekeeper acceptance. Running it contacts Apple and must be an intentional release action.

The signed release path requires all four values to be supplied explicitly:

```sh
export CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export NOTARY_PROFILE='your-notarytool-keychain-profile'
export TALLY_RELEASE_BUNDLE_IDENTIFIER='com.example.Tally'
export TALLY_RELEASE_DEVELOPMENT_TEAM='TEAMID'
./scripts/release.sh
```

Set `VERSION` only when intentionally overriding `MARKETING_VERSION` from `project.yml`.

Before publishing the generated files, confirm that tests, SwiftLint, the hardened arm64 Release build, checksum verification, code-signature verification, notarization, stapling, and Gatekeeper acceptance all succeeded. Uploading artifacts and updating the Homebrew cask remain separate, explicit actions.
