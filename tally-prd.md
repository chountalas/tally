# Tally PRD

## Summary

Build Tally, a native, privacy-first subscription tracker for macOS and iOS that ingests Excel or CSV transaction history, uses Apple Intelligence to classify merchants and detect recurring subscriptions, classifies each as active, former, or needs review, predicts next renewal dates, integrates directly with Apple Calendar, and computes both monthly run-rate and historical spend.

The correct v1 is a native Swift app built with SwiftUI, stored locally with SwiftData, synced across devices via CloudKit, and enhanced with on-device Apple Intelligence for merchant classification. No cloud hosting. No App Store submission. Run directly from Xcode on Mac and iPhone.

## Build Status

Updated: March 13, 2026

### Done

- Native SwiftUI app shell for macOS and iOS from one codebase
- SwiftData local persistence and CloudKit-backed model container configuration
- Resilient app startup that falls back from CloudKit to local-only storage and then to an in-memory session instead of crashing on model container errors
- CSV import with schema detection, manual mapping, and preview
- `.xlsx` import with CoreXLSX and shared tabular normalization
- Legacy `.xls` import with on-device libxls conversion into the shared normalization pipeline
- Hardened import parsing for escaped CSV quotes, embedded newlines, BOM headers, and malformed Excel workbooks with readable error messages
- Merchant classification cache plus Apple Foundation Models classification fallback to heuristics when unavailable
- Subscription detection with cadence inference, active/former/needs-review states, renewal prediction, and normalized monthly run-rate
- Dashboard with monthly run-rate, annualized spend, billing mix, review count, monthly and yearly spend charts, savings opportunities, and act-now renewal list
- Subscriptions tab with active/former/review filtering and editable review workflow
- Persistent review rules for status, cadence, amount, category, notes, false positives, confirmation, and future alias learning
- Calendar tab with EventKit sync controls, permission status, graphical month picker, and upcoming renewals
- Local notification scheduling for renewal reminders, including cleanup when sync is turned off or data is deleted
- Imports history view with parsing states, row counts, mapping signatures, and persisted failure messages
- Transactions search and merchant drilldown
- JSON export and delete-all-data settings, including aliases, review rules, and synced reminder cleanup
- Automated test coverage for CSV parsing, XLSX parsing, XLS parsing, malformed workbook handling, review-rule preservation after re-import, and monthly/annual detection
- Design system with minimal "Content Is The Interface" aesthetic (Theme.swift)
- Subscription Audit mode with interactive optimization and AI reasoning
- Bulk alias merge workflows for merchant consolidation
- Enhanced monthly intelligence brief with overlap and price-change context
- Price-change detection and tenure tracking on subscription model
- All views redesigned with minimal, typography-driven layout

### Partial

- Apple Intelligence: merchant classification, intelligence brief, and audit one-liners use Foundation Models when available; fallback heuristics cover all paths
- CloudKit sync readiness: unchanged (needs real device validation)
- Alias learning: basic alias application and merge sheet are live, but richer auto-learning still needs work

### Pending

- Verify end-to-end on iPhone hardware with real signing and iCloud
- Large-file performance validation with real multi-year ledgers
- 30-day follow-up in Audit mode to track if cancellations actually stopped charging

## Product Recommendation

- Build native Swift from day one with SwiftUI.
- Store all data locally with SwiftData plus CloudKit sync.
- Use Apple Foundation Models for on-device merchant classification.
- Run from Xcode on Mac and iPhone. No App Store, no TestFlight, no signing overhead.
- Zero hosting costs. Zero API costs. Zero ongoing infrastructure.
- Build for personal use first, then decide whether to commercialize.

## Why This Direction

- The user wants zero cost, local-first, and an eventual path to iOS. Native Swift satisfies all three from day one.
- A hosted web app (Vercel + Supabase) introduces free-tier limits, third-party data storage, and a full rewrite cost when going native.
- Apple Intelligence provides free, private, on-device LLM inference that improves automatically with OS updates.
- CloudKit provides free cross-device sync through the user's own iCloud account, which is a stronger privacy story than any hosted database.
- EventKit replaces the entire ICS export feature with direct Apple Calendar integration and native notifications.
- Building native now means Phase 3 (App Store) requires polish, not a rewrite.

## Distribution

### V1: Xcode Direct Install

- **macOS**: Build and Run from Xcode. The app runs as a native macOS app immediately.
- **iOS**: Connect iPhone to Mac, select it as the run destination in Xcode, Build and Run. Requires a free Apple Developer account (Apple ID).
- **Free signing limitation**: Apps signed with a free account expire after 7 days on iOS. Re-deploy from Xcode to refresh. This is fine for personal use during development.
- **No App Store review, no TestFlight, no provisioning profiles needed in v1.**

### Later: Developer Program

- When ready for longer-lived installs or TestFlight sharing, join the Apple Developer Program at $99 per year.
- TestFlight builds last 90 days, no App Store review required.
- App Store submission is a separate, later decision.

## Goals

- Import 4 or more years of transactions from Excel or CSV.
- Use Apple Intelligence to classify merchants with high accuracy and zero manual rules.
- Detect likely subscriptions with high confidence.
- Show active, former, and uncertain subscriptions.
- Store the price and billing cadence for each subscription.
- Predict the next renewal date and integrate renewals directly into Apple Calendar.
- Show current monthly subscription run-rate.
- Break down monthly-billed versus annual-billed subscriptions.
- Show historical spend by month and by year.
- Surface savings opportunities, service overlaps, and price changes.
- Let the user manually correct errors and teach the system merchant rules over time.

## Non-Goals for V1

- Live bank sync via Plaid or similar
- Shared family budgeting
- In-app cancellation automation
- Public marketplace or referral mechanics
- App Store or TestFlight distribution
- Full accounting or tax tooling
- Android or web support
- Cloud hosting or server-side processing

## Users and Job To Be Done

Primary user: a privacy-conscious individual trying to understand recurring spend.

Job to be done: "Upload my transaction history, tell me what I subscribe to now, what I used to subscribe to, what is renewing next, and how much these subscriptions are actually costing me each month and year. Tell me what to do about it."

## Core User Flows

1. Open the app.
2. Import a `.xlsx`, `.xls`, or `.csv` file via the native file picker.
3. Let the system auto-detect columns.
4. If needed, map the minimum required fields for that import.
5. Apple Intelligence classifies each unique merchant string on-device.
6. Review parsed transactions and fix any obvious issues.
7. See detected subscription candidates with confidence scores and LLM classifications.
8. Confirm, merge, split, or dismiss candidates.
9. Land on the main dashboard:
   - Active subscriptions
   - Former subscriptions
   - Upcoming renewals (synced to Apple Calendar)
   - Monthly run-rate
   - Monthly-billed vs annual-billed breakdown
   - Historical spend charts by month and year
   - Savings opportunities and overlap alerts
10. Return later to import a newer statement and keep the model current.

## V1 Feature Set

- Native SwiftUI app for macOS and iOS
- Local data persistence with SwiftData
- CloudKit sync across devices
- Import wizard with automatic field detection
- Fallback column mapping for unfamiliar formats
- On-device Apple Intelligence merchant classification
- Merchant classification cache to avoid re-classifying known merchants
- Subscription detection engine
- Review queue for ambiguous merchants
- Active, former, and uncertain subscription states
- Renewal prediction
- Direct Apple Calendar integration via EventKit
- Native local notifications for upcoming renewals
- Dashboard cards:
  - Total monthly run-rate
  - Annualized subscription cost
  - Upcoming renewals in next 30 and 90 days
  - Monthly vs annual subscription mix
- Historical analytics:
  - Spend by month (Swift Charts)
  - Spend by year (Swift Charts)
  - Spend by merchant or subscription
- LLM Intelligence features:
  - Service category classification
  - Service overlap detection
  - Price change detection
  - Savings opportunities
- Manual edit workflows:
  - Override merchant name
  - Override cadence
  - Override amount
  - Mark canceled
  - Mark false positive
  - Merge aliases

## UX / Information Architecture

- Dashboard (Tab)
  - Monthly run-rate card
  - Annualized cost card
  - Active count
  - Upcoming renewals list
  - Savings opportunities
- Subscriptions (Tab)
  - Active
  - Former
  - Needs review
  - Detail view per subscription with history, intelligence, and edit controls
- Calendar (Tab)
  - Month view using EventKit data
  - Agenda list of upcoming renewals
- Transactions (Tab)
  - Raw imported ledger
  - Filters and merchant drilldown
- Imports (Tab or Sheet)
  - Upload history
  - Parsing status
  - Errors
- Settings (Tab or Sheet)
  - CloudKit sync status
  - Apple Calendar permissions
  - Notification preferences
  - Data export (JSON)
  - Delete all data

## Recommended Build Stack

### App Layer

- SwiftUI for all UI (macOS and iOS from one codebase)
- SwiftData for local persistence
- CloudKit for cross-device sync (via SwiftData CloudKit integration)
- Swift Charts for analytics visualizations
- EventKit for Apple Calendar read/write
- UserNotifications for local renewal alerts

### Import Processing

- CoreXLSX for `.xlsx` parsing
- Native Swift CSV parsing (or SwiftCSV package)
- `.xls` support via a lightweight Swift wrapper or conversion step

### LLM Intelligence

- Apple Foundation Models framework for on-device inference
- `@Generable` structs for type-safe merchant classification output
- Batch deduplication: classify unique merchant strings only, cache results in SwiftData

### No External Services

- No Vercel, no Supabase, no cloud functions, no API keys
- All processing happens on-device
- All data stored locally and synced via iCloud

## System Design

1. User selects a file via the native file picker (fileImporter).
2. App reads the file using CoreXLSX or CSV parser.
3. App attempts automatic column detection based on header names and data patterns.
4. If confidence is low, app presents a column mapping UI.
5. App extracts all unique merchant strings from the import.
6. App checks the local merchant classification cache in SwiftData.
7. For uncached merchants, app calls Apple Foundation Models on-device:
   - Input: raw merchant string, amount, frequency hint
   - Output: canonical name, category, subscription likelihood, confidence
8. App creates normalized transaction records in SwiftData.
9. Detection engine groups transactions by normalized merchant, identifies recurring patterns, creates subscription candidates.
10. System computes cadence, status, next renewal date, monthly run-rate.
11. UI surfaces candidates for review.
12. User corrections update the merchant classification cache and alias rules.
13. App writes renewal events to Apple Calendar via EventKit.
14. App schedules local notifications for upcoming renewals.
15. CloudKit syncs all SwiftData models to other devices.

## Import System Requirements

The import system must be schema-agnostic and tolerate different spreadsheets every time.

### Minimum Required Fields Per Transaction

- date
- amount
- vendor

### Accepted Inputs

- `.xlsx`
- `.xls`
- `.csv`

### Import Behavior

- Try automatic column detection on every upload.
- If confidence is low, prompt the user to map fields.
- Permit vendor extraction from:
  - explicit vendor or merchant column
  - description column
  - memo or reference column
- Normalize amount signs and refund behavior.
- Save optional per-format templates in SwiftData, but never rely on them as mandatory.

### Canonical Normalized Transaction Model

```swift
@Model
class NormalizedTransaction {
    var transactionDate: Date
    var transactionAmount: Decimal
    var merchantRaw: String
    var merchantNormalized: String
    var currency: String?
    var accountName: String?
    var category: String?
    var memo: String?
    var importRecord: ImportRecord
}
```

### Upload Mapping Principles

- Every upload is treated as potentially unique.
- The system should attempt auto-mapping first.
- The user should only be asked to confirm or fix mappings when confidence is low.
- The system should remember prior mappings for convenience without assuming future files match.
- If only date, amount, and description or vendor exist, that is sufficient to produce subscription candidates.

## Detection Logic

### Transaction Normalization

- Normalize date, amount sign, currency, merchant string, memo, and account if present.
- Treat debits as subscription candidates.
- Flag refunds, reversals, and one-off anomalies.

### Merchant Normalization

- Primary: Apple Intelligence classifies raw merchant strings into canonical names, categories, and subscription likelihood on-device.
- Cache: Classified merchants are stored in a `MerchantClassification` SwiftData model. Subsequent imports skip LLM calls for known merchants.
- Fallback: If Apple Intelligence is unavailable (older device, restricted mode), fall back to basic string normalization (lowercase, strip transaction IDs, trim whitespace) and flag more items as `needs_review`.
- Override: User-editable alias rules always take precedence over LLM classification.

### Apple Intelligence Classification Schema

```swift
@Generable
struct MerchantClassificationResult {
    var canonicalName: String
    var serviceCategory: String
    var isLikelySubscription: Bool
    var confidence: Double
}
```

### Cadence Inference

- Monthly: median interval 27 to 33 days, at least 3 charges
- Annual: median interval 330 to 390 days, at least 2 charges
- Quarterly, semiannual, and weekly supported internally, but monthly and annual are first-class in UI
- Amount tolerance default: plus or minus 10 percent
- Date drift tolerance: plus or minus 5 days monthly, plus or minus 21 days annual

### Status Inference

- Active: last charge is within one expected cycle plus grace window
- Former: last charge is overdue by more than 1.5 cycles and no newer evidence exists
- Needs review: cadence or merchant confidence is too low, or multiple merchants appear merged

### Renewal Prediction

- Predict next charge from last confirmed charge plus cadence
- Adjust for end-of-month drift and weekend drift using merchant history
- For annual subscriptions, preserve renewal month and day when possible

### Spend Metrics

- `monthlyRunRate`: monthly subscriptions at full price plus annual, quarterly, and semiannual subscriptions normalized to a monthly equivalent
- `annualizedTotal`: monthly run-rate times 12
- `historicalMonthlySpend`: actual billed cash outflow by calendar month
- `historicalYearlySpend`: actual billed cash outflow by calendar year
- `billingMix`: split between monthly-billed and annual-billed subscriptions

## LLM Intelligence Layer

### On-Device Merchant Classification

- Uses Apple Foundation Models framework.
- All inference happens on-device. No data leaves the phone or computer.
- Batch deduplication: a 4-year import may have 5,000+ transactions but only 150 to 300 unique merchant strings. Classify the unique set, cache results, apply mapping.
- Classification includes: canonical name, service category, subscription likelihood, confidence score.

### Savings Intelligence (Phase 2)

- Service overlap detection: flag when multiple subscriptions serve the same category (e.g., three music streaming services).
- Price change detection: compare current charge amount to historical amounts for the same subscription. Flag increases.
- Monthly intelligence brief: use Apple Intelligence to generate a natural-language summary of what changed, what is coming up, and one concrete savings action.

### Renewal Decision Engine (Phase 2)

- A ranked "Act Now" list for renewals in the next 30 days.
- Each upcoming subscription gets:
  - Renewal date
  - Price
  - Confidence
  - Price increase detection
  - Overlap detection with similar services
  - Suggested action: keep, review, or cancel
  - Notes field
- Uses Apple Intelligence to generate suggested actions based on usage patterns, price trajectory, and service overlap.

## Data Model (SwiftData)

### Core Models

- `ImportRecord` — metadata about each file import
- `ColumnMapping` — saved column mapping templates
- `NormalizedTransaction` — cleaned transaction records
- `MerchantClassification` — cached LLM classification results per unique merchant string
- `MerchantAlias` — user-defined merchant name overrides
- `Subscription` — detected or confirmed subscriptions
- `SubscriptionTransaction` — link between subscriptions and their transactions
- `RenewalPrediction` — predicted next charges
- `ReviewAction` — user review decisions (confirm, dismiss, merge)

### Key Fields On `Subscription`

```swift
@Model
class Subscription {
    @Attribute(.unique) var id: UUID
    var canonicalName: String
    var displayName: String
    var status: SubscriptionStatus
    var cadence: SubscriptionCadence
    var priceAmount: Decimal
    var priceCurrency: String
    var normalizedMonthlyAmount: Decimal
    var lastChargeDate: Date?
    var predictedNextChargeDate: Date?
    var confidenceScore: Double
    var isUserConfirmed: Bool
    var serviceCategory: String?
    var notes: String?
    var transactions: [SubscriptionTransaction]
}
```

### Intelligence Models (Phase 2)

- `SubscriptionIntelligence` — known pricing tiers, cancellation URL, overlap group, downgrade suggestion, last analyzed date
- `SpendInsight` — period, insight type (brief, savings, alert), generated content, generated date

## Swift Types

### Enums

```swift
enum SubscriptionStatus: String, Codable {
    case active
    case former
    case needsReview
}

enum SubscriptionCadence: String, Codable {
    case monthly
    case annual
    case quarterly
    case semiannual
    case weekly
    case unknown
}

enum ImportStatus: String, Codable {
    case queued
    case parsing
    case classifying
    case analyzed
    case failed
    case needsMapping
}
```

### Column Mapping

```swift
struct ColumnMappingConfig: Codable {
    var dateColumn: String
    var descriptionColumn: String?
    var amountColumn: String
    var merchantColumn: String?
    var categoryColumn: String?
    var accountColumn: String?
    var currency: String?
    var debitSignConvention: DebitSign
}

enum DebitSign: String, Codable {
    case negative
    case positive
}
```

## Security and Privacy

- All data stored on-device in SwiftData, synced through the user's own iCloud account.
- All LLM inference happens on-device via Apple Foundation Models. No transaction data is sent to any server.
- No third-party analytics, no ad SDKs, no telemetry.
- No cloud database, no server-side storage, no API keys.
- Original imported files can be deleted after normalization. SwiftData retains only normalized transaction records.
- Export all data as JSON from settings.
- Delete all data from settings.
- CloudKit data is encrypted in transit and at rest per Apple's iCloud security model.
- If the app is later published, add a privacy policy, App Privacy nutrition labels, and a data deletion flow per Apple guidelines.

## Notifications

V1:

- Direct Apple Calendar events via EventKit for upcoming renewals.
- Local notifications via UserNotifications for renewals in the next 7 days.
- Notification preferences configurable in settings.

Not in v1:

- Push notifications (requires server infrastructure)
- Email summaries
- SMS

## Phased Delivery

### Phase 0: Sample-Data Spike

- Build a minimal Swift command-line tool or SwiftUI prototype.
- Parse one real spreadsheet using CoreXLSX.
- Run Apple Intelligence classification on the extracted merchant strings.
- Validate column detection, normalization, and subscription detection against actual merchant noise.
- Success: 80 percent or more of obvious subscriptions detected from the sheet with no manual rules.

### Phase 1: MVP

- SwiftUI app running on macOS
- File import with automatic column detection
- Apple Intelligence merchant classification with caching
- Detection engine with cadence inference and status classification
- Manual review queue
- Dashboard with run-rate, annualized cost, active count, upcoming renewals
- Swift Charts for historical monthly and yearly spend
- EventKit calendar integration
- Local notifications for upcoming renewals
- SwiftData persistence with CloudKit sync
- Settings with data export and delete
- Success: the full 4-year file can be imported and produce a usable active and former view with calendar integration

### Phase 2: Product Hardening

- iOS companion layout (same codebase, adaptive SwiftUI)
- Renewal Decision Engine with Apple Intelligence reasoning
- Price-change detection and alerts
- Service overlap detection
- Savings opportunities surface
- Monthly intelligence brief generation
- Better alias learning from user corrections
- Duplicate-service warnings
- Import format memory improvements
- Success: weekly habit-forming use on both Mac and iPhone

### Phase 3: Distribution Decision

Skills to invoke: `/asc-signing-setup`, `/asc-xcode-build`, `/asc-testflight-orchestration`, `/asc-release-flow`, `/asc-submission-health`, `/asc-metadata-sync`

Only start if real usage proves the need.

Criteria:

- Weekly use for 6 or more weeks
- Import accuracy above 90 percent on at least 3 statement formats
- Calendar and notification workflows are sticky
- Privacy policy and data deletion flow are ready

Steps:

- Join Apple Developer Program ($99 per year)
- Set up bundle IDs and signing with `/asc-signing-setup`
- Archive and export with `/asc-xcode-build`
- Distribute via TestFlight first with `/asc-testflight-orchestration`
- Decide on public App Store release based on TestFlight feedback

## Testing and Acceptance Criteria

### Functional Tests

- Import a valid `.xlsx` file with standard columns
- Import a file with columns in a different order
- Import a file missing merchant or category columns and recover through mapping
- Apple Intelligence correctly classifies common merchants (Netflix, Spotify, Adobe, etc.)
- Apple Intelligence fallback works gracefully on unsupported devices
- Detect obvious monthly subscriptions correctly
- Detect annual renewals correctly across multi-year gaps
- Mark canceled or lapsed subscriptions as former
- Predict next renewal dates accurately within tolerance
- Compute monthly run-rate correctly from mixed monthly and annual subscriptions
- Write renewal events to Apple Calendar via EventKit
- Fire local notifications for upcoming renewals
- CloudKit sync delivers data to a second device
- Preserve user overrides after re-import

### Edge-Case Tests

- Merchant name variations like `NETFLIX`, `Netflix.com`, `Netflix *123`
- Price changes over time
- Free trials turning into paid subscriptions
- Duplicate same-day charges
- Refunds or reversed charges
- Paused subscriptions that later resume
- Multiple subscriptions from one vendor
- Leap-year and end-of-month renewal dates
- Apple Intelligence unavailable (test fallback path)
- Large import file (10,000+ transactions)
- CloudKit conflict resolution on simultaneous edits

### Acceptance Thresholds

- Precision for active subscriptions: target 90 percent after review rules
- Apple Intelligence merchant classification accuracy: target 95 percent on common merchants
- Renewal prediction accuracy: target 85 percent or more on confirmed subscriptions
- Import completion time: under 30 seconds for a typical personal file (on-device processing is faster than server roundtrip)
- Mobile usability: full dashboard and calendar usable on iPhone
- Zero data sent to external servers (all processing on-device)

## Risks and Mitigations

- Merchant ambiguity causes false positives
  - Mitigation: Apple Intelligence classification plus review queue, alias rules, confidence scoring
- Spreadsheet formats vary
  - Mitigation: mapping wizard with saved templates in SwiftData
- Annual subscriptions are harder to infer with sparse data
  - Mitigation: lower-confidence review state and user confirmation
- Apple Intelligence model quality may vary
  - Mitigation: classification cache means each merchant is only classified once, user overrides always win, fallback to basic string normalization
- Apple Intelligence requires recent hardware and OS
  - Mitigation: graceful degradation with more items routed to needs_review queue
- 7-day signing limit on free developer account
  - Mitigation: re-deploy from Xcode weekly, or upgrade to $99 Developer Program when ready
- CloudKit sync conflicts
  - Mitigation: SwiftData CloudKit integration handles merge conflicts automatically; user corrections are timestamp-ordered
- Scope creep into full budgeting
  - Mitigation: keep focus on subscriptions only

## Explicit Assumptions and Defaults

- V1 is for personal use first, not public App Store launch
- V1 is native Swift, not web
- V1 runs from Xcode, no App Store or TestFlight needed
- V1 is local-first with CloudKit sync, no cloud hosting
- V1 uses Apple Intelligence for merchant classification, no external API
- V1 supports manual file import only, not bank sync
- V1 integrates directly with Apple Calendar via EventKit, no ICS export needed
- Default currency is inferred from import or set in onboarding
- If cadence cannot be inferred confidently, the item goes to `needsReview`
- Monthly total shown on the dashboard is normalized run-rate, not just this month's billed cash
- Historical charts show actual billed cash by month and year
- If Apple Intelligence is unavailable, the app still works but routes more items to review

## Source Notes

Official Apple frameworks used in this architecture:

- SwiftUI: app UI framework for macOS and iOS
- SwiftData: local persistence with CloudKit sync
- Swift Charts: data visualization
- EventKit: Apple Calendar read and write
- UserNotifications: local notification scheduling
- Foundation Models: on-device LLM inference via Apple Intelligence
- CoreXLSX: third-party Swift package for Excel file parsing

Distribution references:

- Free Apple Developer account allows Xcode direct-to-device deployment
- Apple Developer Program ($99 per year) enables TestFlight and App Store distribution
- Apple Developer Program membership details: https://developer.apple.com/programs/whats-included/
- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
