## Summary

- 

## Verification

- [ ] `xcodegen generate`
- [ ] `git diff --check`
- [ ] `swiftlint lint --quiet`
- [ ] `xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived`

## Public Repo Check

- [ ] No real financial data, bank exports, personal screenshots, local paths, credentials, provisioning profiles, or private notes.
- [ ] No client-side secrets for optional integrations.
- [ ] Any new logs keep merchant names, memos, account names, file paths, prompts, and model outputs private or omitted.
