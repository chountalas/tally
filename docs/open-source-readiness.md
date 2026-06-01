# Open Source Readiness Review

Date: 2026-06-01

## Current Tree Status

- No hardcoded production API keys, bearer tokens, private keys, or service credentials were found in the current tracked source scan.
- Private agent control-plane instructions were removed from public repo files.
- Apple signing team, bundle identifier, and iCloud container values are now contributor-configurable instead of hard-coded to a personal account.
- Public OSLog output no longer includes Gemma model paths or raw model-output previews.
- `.DS_Store`, build output, Xcode user state, local signing files, local automation state, and generated vendor binaries are ignored.

## Privacy Surfaces To Keep Documented

- SwiftData stores transaction and subscription data locally.
- CloudKit sync can copy that data through the user's iCloud account when configured.
- Notifications, Calendar, Spotlight, and App Intents can expose subscription names, prices, and renewal dates to local Apple platform features.
- Gemma model downloads contact Hugging Face, but inference is local after setup.
- Apple Foundation Models behavior follows Apple's platform implementation and user settings.

## Security Surfaces To Keep Reviewing

- Legacy `.xls` parsing uses the `libxls` submodule; keep file-size limits and parser tests.
- The macOS app uses sandbox entitlements and user-selected file access.
- The vendored `llama.framework` has recorded provenance and a SHA-256 in `Vendor/llama-framework-source.md`; verify replacements before committing.
- Optional Plaid or bank-sync work must keep secrets out of the client and cannot become required for core local workflows.

## Remaining Publication Gate

The current working tree has been sanitized, but this repository history is not publish-ready as-is. History checks found old commits containing removed `.DS_Store`/scorecard/internal planning artifacts, local absolute paths, and the previous Apple team identifier. The public launch path is to keep the existing private repository as an archive and publish a fresh public repository from the sanitized tree.
