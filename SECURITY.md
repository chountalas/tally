# Security Policy

## Reporting A Vulnerability

Please report security issues through GitHub Security Advisories if the repository is hosted on GitHub. Avoid opening public issues for vulnerabilities that include exploit details, private data, or credentials.

## Supported Scope

Security review should focus on:

- Local file import parsing for CSV, XLSX, and legacy XLS files.
- SwiftData persistence and CloudKit sync behavior.
- OSLog privacy annotations.
- App Sandbox and user-selected file entitlements on macOS.
- Optional local model download and validation.
- Third-party dependency and vendored binary provenance.

## Project Security Rules

- Never commit API keys, tokens, provisioning profiles, signing certificates, or personal `Config/Local.xcconfig` files.
- Do not ship Plaid, Auth0, Convex, or other service secrets in the client.
- Treat all imported transaction data as private user data.
- Keep local file import size limits and validation in place.
- Keep macOS sandbox entitlements enabled for app builds.
- Prefer local/on-device processing. Any future external service must be opt-in and documented in `PRIVACY.md`.

## Supply Chain Notes

The repo uses a `libxls` submodule and a prebuilt macOS `llama.framework`. The current `llama.framework` provenance and SHA-256 are recorded in `Vendor/llama-framework-source.md`. Before any update, verify the upstream source, license, and checksum for the replacement binary.
