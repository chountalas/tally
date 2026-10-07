# Subscription detection

Tally identifies recurring billing from imported transactions. Detection runs locally and combines merchant recognition with charge timing, account, currency and description evidence. A merchant name alone does not identify a subscription: one merchant can bill several plans.

## Importing transaction history

The app accepts CSV, XLS, XLSX, OFX and QFX files. Tabular imports provide column mapping and a preview before committing transactions. Excel imports use the first worksheet. Files larger than 50 MiB are rejected. Parsing runs in a background task; imported transactions are then persisted and analyzed.

Importing three years of history can reveal annual billing, price changes and subscriptions that stopped charging. Overlapping exports are reconciled by transaction occurrence so repeated imports preserve genuine same-day charges. Re-scanning uses the transactions already in the local library.

## Distinguishing subscriptions

Recurring histories retain separate account, currency, description and billing-phase evidence. This allows two subscriptions from the same merchant to remain distinct when the transactions supply enough identifying information. Price changes within a continuing history do not automatically create another subscription.

When same-account charges have the same price, date and indistinguishable descriptions, transaction data may not establish how many plans exist. Tally should retain that uncertainty for review. Receipts or service account information would be needed to resolve it.

Review decisions are scoped to the detected history where possible. Keeping, excluding or cancelling one plan should not change a distinguishable sibling plan. Re-importing older transactions should retain the existing review decision and identity.

## Renewals and stopped billing

Renewal estimates use calendar billing schedules rather than a fixed number of days per month or year. Month-end histories retain their month-end anchor. Charge history remains available in subscription details, with an initial compact list and a control to reveal all charges.

A missing charge can suggest that billing stopped. Tally uses later transaction coverage from the same account before inferring an ended history; activity on another account is insufficient evidence. A billing gap does not confirm cancellation with the provider. A user-marked cancellation takes precedence over inferred status.

## Merchant recognition and AI

Known merchant evidence and deterministic recurring detection are available without an AI generator. Ambiguous results can enter the review queue. Optional on-device inference uses the selected available provider: the macOS Gemma runtime requires a compatible local model, and Apple Intelligence depends on system availability.

Provider availability and model quality are separate concerns. Passing import fixtures does not establish general model accuracy or responsiveness in the native app.

## Integration boundaries

Calendar renewal sync and reminders require the relevant system permissions. Deep links use `tally://subscription/<UUID>` and `tally://tab/<route>`. The public configuration supports local persistence; optional iCloud configuration must be supplied separately.

A SimpleFIN JSON adapter exists internally, but it has no connection screen, import entry point or polling job. Email, receipt and Plaid source labels do not provide working integrations. There is currently no authenticated email connection or email subscription discovery.

## Contributor verification

Use synthetic transactions and an isolated test store. The existing service tests exercise import materialization, overlapping exports, multiple histories, calendar renewals, observed lifecycle changes and review persistence. Relevant suites include:

- `MultiYearSubscriptionImportTests.swift`
- `SubscriptionDiscoveryImportTests.swift`
- `SubscriptionEvidenceEngineTests.swift`
- `CSVTransactionImporterTests+ReviewRules.swift`
- `AppRegistrationTests.swift`

Run the repository checks from its root:

```sh
bash -n scripts/*.sh
xcodegen generate
swiftlint lint --config .swiftlint.yml Tally TallyTests --quiet
TEST_RUNNER_TALLY_IN_MEMORY_STORE=1 xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .build/derived-release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ENABLE_HARDENED_RUNTIME=YES CODE_SIGNING_ALLOWED=NO
```

The debug in-memory store flag isolates financial persistence; it does not isolate every operating-system service or preference. Tests that touch those dependencies should inject test-owned implementations.

Service tests and bundle metadata checks do not verify native file selection, mapping presentation, review actions, complete charge-history disclosure, renewal navigation or actual URL dispatch. Verify those paths in the running app with synthetic data. Persistent-store migration, calendar writes, notification delivery and configured-account sync require their own runtime evidence. Keep screenshots and exports containing personal financial data out of the repository.
