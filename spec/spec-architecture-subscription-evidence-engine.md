---
title: Tally Source-Agnostic Subscription Evidence Engine
version: 1.0
date_created: 2026-06-01
last_updated: 2026-06-01
owner: Connor Hountalas
tags: [architecture, data, detection, automation, local-llm, open-source]
---

# Introduction

This specification defines how Tally should evolve from a recurring-cluster detector into a source-agnostic subscription evidence engine. The goal is to make Tally highly accurate and highly automated without depending on Plaid production access or a hosted backend. Tally shall ingest transactions from many sources, normalize merchants, learn durable rules, project expected payment occurrences, reconcile actual charges, and use local LLMs as structured evidence evaluators rather than as uncontrolled decision makers.

## Goal Statement

Tally shall become an open-source, local-first subscription tracker that stays accurate with minimal manual upkeep. The system shall treat transactions as the source of truth, use deterministic evidence and local LLMs to understand messy merchant data, automatically maintain subscriptions through learned rules and expected-payment reconciliation, and ask the user only when evidence is ambiguous or materially risky.

## 1. Purpose & Scope

This specification applies to the native SwiftUI + SwiftData Tally app in this repository.

The scope includes:

- Transaction ingestion architecture for file imports, SimpleFIN-style bank feeds, optional Plaid, and receipt/email-derived transactions.
- Merchant identity and service profile modeling.
- Subscription rule generation and replay.
- Expected payment occurrence modeling.
- Evidence persistence and scoring.
- Local LLM integration using the existing Gemma and Apple Intelligence abstractions.
- Migration from the current cluster-first rebuild flow to a rule/evidence/occurrence flow.

The scope excludes:

- A hosted Plaid backend as a required path.
- Copying source code from GPL or AGPL projects inspected during research.
- UI redesign beyond the review surfaces needed to expose evidence and automation outcomes.

## 2. Definitions

- **Adapter**: A source-specific importer that converts external data into `NormalizedTransaction` records.
- **Canonical merchant**: The stable consumer-facing merchant or service name used by Tally for grouping, display, and rules.
- **Detection evidence**: A persisted explanation of why a candidate was detected, confirmed, suppressed, or flagged for review.
- **Evidence engine**: The combined pipeline that uses transactions, merchant identity, service profiles, rules, expected occurrences, actual charges, local LLM evaluations, and user corrections to maintain subscriptions.
- **Expected occurrence**: A projected billing instance for a subscription schedule, such as "ChatGPT expected on 2026-06-14."
- **Local LLM**: A model running on device through Tally's existing `GemmaLocalIntelligenceGenerator` or Apple's Foundation Models integration.
- **Merchant cluster**: A persistent group of related raw descriptors and transactions believed to represent the same merchant identity.
- **Rule replay**: Re-running learned rules over historical and newly imported transactions to link, unlink, confirm, suppress, or repair subscriptions.
- **Schedule expectation**: A durable description of a subscription's expected cadence, amount range, anchor date, and matching tolerances.
- **Service profile**: A local catalog entry for a known service, including aliases, domains, processor descriptors, category hints, price bands, and likely cadences.
- **Source-agnostic**: Detection behavior that works the same regardless of whether a transaction came from CSV, XLS/XLSX, QFX, OFX, SimpleFIN, Plaid, manual entry, or a receipt parser.

## 3. Requirements, Constraints & Guidelines

### 3.1 Current State Comparison

| Area | Current Tally capability | Gap | Target fit |
|------|--------------------------|-----|------------|
| Transaction model | `NormalizedTransaction` stores date, amount, source, raw merchant, normalized merchant, currency, account, category, memo, classification confidence, subscription affinity, `subscriptionID`, and external IDs. | Source values are limited to `manualImport` and `plaid`; duplicate identity and provider metadata are thin. | Keep `NormalizedTransaction` as the source-agnostic spine. Add source metadata and idempotent dedupe models around it. |
| Imports | CSV/XLS/XLSX import exists through `ImportModels`, `TabularTransactionDraftBuilder`, and importer services. | No QFX/OFX or SimpleFIN adapter. File imports appear to insert transaction rows rather than performing universal source-level reconciliation. | Add adapters that all feed the same transaction upsert and detection pipeline. |
| Classification | `MerchantAlias`, `MerchantClassification`, `MerchantCorrection`, cached classifications, and local/provider classification exist. | Corrections are mostly raw merchant to canonical name, not a persistent merchant identity graph with ranked descriptor tokens and collision handling. | Add `MerchantIdentity` and `MerchantIdentityMember`; keep current aliases/classifications as compatibility inputs. |
| Processor unmasking | `PaymentProcessorUnmasker` handles Apple, Stripe, PayPal, Google, Square, Shopify, Gumroad, Paddle, FastSpring. | Unmasking is rule-based and transient; unmask evidence is not persisted as a reusable identity signal. | Persist processor evidence into merchant identity and detection evidence records. |
| Detection pipeline | `rebuildSubscriptions` fetches all transactions, clears `subscriptionID`, refreshes processor-masked transactions, groups by `merchantNormalized`, clusters by amount/cadence, evaluates clusters, and removes stale subscriptions. | A confirmed subscription is still mostly a derived result of the latest rebuild. There is no durable expected occurrence ledger or executable rule set for every confirmed subscription. | Insert rule application, occurrence reconciliation, and evidence persistence before/after clustering. |
| Cadence | `SubscriptionCadence` supports monthly, annual, quarterly, semiannual, biweekly, weekly, unknown. Inference uses median intervals and occurrence counts. | Cadence does not store unit, interval, anchor day, end-of-month behavior, nth weekday, source confidence, or date tolerance. | Add `SubscriptionScheduleExpectation` with unit, interval, anchor policy, expected windows, and occurrence projection. |
| Review rules | `SubscriptionReviewRule` stores overrides for display name, status, cadence, price, currency, last charge, category, notes, false positive, and confirmation. | Rules do not store amount windows, merchant predicates, account/source hints, negative exclusions, evidence provenance, or replay statistics. | Add `SubscriptionMatchRule`; keep `SubscriptionReviewRule` as the user override surface and migrate confirmed reviews into match rules. |
| Evidence | `SubscriptionSummary`, `SubscriptionClusterReport`, and `detectionReason` explain current decisions in memory/string form. | Evidence is not durable, queryable, or reusable. It cannot prove why a rebuild made a decision. | Add `SubscriptionDetectionEvidence` and `DetectionRun` models. |
| Local LLM | `AIProviderKind` supports Gemma on macOS and Apple Intelligence where available. `SubscriptionIntelligenceGenerating` classifies merchants and evaluates recurring clusters/single charges. | LLM outputs are decision summaries, not structured evidence factors tied to rules, service profiles, occurrences, and replay. | Keep LLM calls behind structured protocols. Add richer inputs and require strict JSON evidence contributions. |
| Lifecycle | `Subscription` stores first charge, last charge, predicted next charge, price change percent, tenure, reminders, replacement ID, service ID, website, payment method. | No explicit expected-vs-observed history, missed renewal status, amount history, price history, or cancellation confidence. | Add `SubscriptionOccurrence`, `SubscriptionPriceObservation`, and lifecycle evidence derived from matched/missed occurrences. |

### 3.2 Functional Requirements

- **REQ-001**: Tally shall keep `NormalizedTransaction` as the canonical transaction input model for all ingestion sources.
- **REQ-002**: Tally shall support multiple transaction adapters without changing subscription detection logic.
- **REQ-003**: Tally shall not require Plaid for accurate automated tracking.
- **REQ-004**: Tally shall support SimpleFIN-style local bank sync as a first-class open-source-friendly adapter.
- **REQ-005**: Tally shall support optional Plaid only as an adapter requiring user-provided or hosted credentials.
- **REQ-006**: Tally shall add idempotent transaction upsert and delete/tombstone behavior keyed by source identity.
- **REQ-007**: Tally shall store merchant identity as a persistent graph, not only a raw merchant alias table.
- **REQ-008**: Tally shall store a local service profile catalog and use it as weak evidence, not as transaction truth.
- **REQ-009**: Tally shall convert confirmed subscriptions and user corrections into executable match rules.
- **REQ-010**: Tally shall apply match rules to new and historical transactions before running new candidate discovery.
- **REQ-011**: Tally shall project expected subscription occurrences from schedule expectations.
- **REQ-012**: Tally shall reconcile expected occurrences against actual transactions after every import, sync, correction, or rule replay.
- **REQ-013**: Tally shall score subscription confidence using schedule coverage, not only median intervals.
- **REQ-014**: Tally shall persist detection evidence for every created, updated, suppressed, or review-needed candidate.
- **REQ-015**: Tally shall auto-confirm high-confidence subscriptions, auto-suppress low-confidence false positives, and reserve review for ambiguous cases.
- **REQ-016**: Tally shall preserve user-confirmed rules and corrections through all rebuilds.
- **REQ-017**: Tally shall preserve existing manual subscriptions and manual library state behavior.
- **REQ-018**: Tally shall use local LLMs only for structured classification/evidence enrichment after deterministic features are computed.
- **REQ-019**: Tally shall make every LLM-assisted decision replayable from persisted inputs and outputs.
- **REQ-020**: Tally shall expose evidence in review UI and intelligence responses so the user can see why automation acted.

### 3.3 Open Source Constraints

- **CON-001**: Plaid cannot be a required dependency because production access requires approval and client secrets cannot be shipped in an open-source client.
- **CON-002**: All default tracking features shall work with file imports and at least one open-source-friendly bank feed path.
- **CON-003**: GPL/AGPL project research may inform architecture only; Tally shall not copy implementation code or seed data from GPL/AGPL repositories.
- **CON-004**: Source adapters shall not require a hosted Tally service to use the core evidence engine.
- **CON-005**: CloudKit sync shall remain compatible with SwiftData model additions or explicitly provide migration/reset handling.

### 3.4 Local LLM Guidelines

- **LLM-001**: The local LLM shall never be the sole source of truth for subscription creation, suppression, or deletion.
- **LLM-002**: The local LLM shall receive structured evidence, not raw unbounded app state.
- **LLM-003**: The local LLM shall return strict JSON with bounded enums and confidence values from 0 to 1.
- **LLM-004**: The app shall clamp and validate every LLM confidence and enum value before use.
- **LLM-005**: The app shall persist the LLM provider kind, prompt schema version, normalized input fingerprint, output, and validation result for any automated decision influenced by LLM output.
- **LLM-006**: The app shall degrade to deterministic scoring when Gemma or Apple Intelligence is unavailable.
- **LLM-007**: LLM prompts shall emphasize contradiction detection, processor ambiguity, service identity, trial-to-paid patterns, and false-positive categories.
- **LLM-008**: LLM output shall contribute evidence factors; final automation thresholds shall remain deterministic app logic.

## 4. Interfaces & Data Contracts

### 4.1 Existing Models To Retain

The following existing models remain part of the architecture:

- `ImportRecord`
- `ColumnMappingTemplate`
- `MerchantAlias`
- `MerchantClassification`
- `MerchantCorrection`
- `NormalizedTransaction`
- `Subscription`
- `SubscriptionReviewRule`
- `ManualSubscription`

### 4.2 New SwiftData Models

#### SourceTransactionIdentity

Purpose: Deduplicate and reconcile transactions across adapters before subscription detection.

```swift
@Model
final class SourceTransactionIdentity {
    var id: UUID
    var normalizedTransactionID: UUID?
    var sourceRawValue: String
    var externalTransactionID: String?
    var externalAccountID: String?
    var sourceReferenceID: String?
    var sourceFingerprint: String
    var pendingExternalTransactionID: String?
    var statusRawValue: String
    var firstSeenAt: Date
    var lastSeenAt: Date
}
```

Required uniqueness behavior:

- Prefer exact key: `sourceRawValue + externalTransactionID`.
- Fallback key: `sourceRawValue + externalAccountID + sourceFingerprint`.
- Fuzzy duplicate candidate key: same account, date within 2 days, exact signed amount, and high merchant identity similarity.

#### MerchantIdentity

Purpose: Persist canonical merchant identities across descriptor changes.

```swift
@Model
final class MerchantIdentity {
    var id: UUID
    var canonicalName: String
    var displayName: String
    var serviceProfileID: UUID?
    var confidence: Double
    var rankedTokensJSON: String
    var negativeTokensJSON: String
    var createdAt: Date
    var updatedAt: Date
}
```

#### MerchantIdentityMember

Purpose: Link raw descriptors, aliases, and transactions to a merchant identity.

```swift
@Model
final class MerchantIdentityMember {
    var id: UUID
    var merchantIdentityID: UUID
    var rawMerchant: String
    var normalizedMerchant: String
    var memoFingerprint: String?
    var accountName: String?
    var sourceRawValue: String?
    var firstSeenAt: Date
    var lastSeenAt: Date
    var evidenceCount: Int
    var confidence: Double
}
```

#### ServiceProfile

Purpose: Store local known-service priors.

```swift
@Model
final class ServiceProfile {
    var id: UUID
    var canonicalName: String
    var aliasesJSON: String
    var domainsJSON: String
    var processorPatternsJSON: String
    var categoryHint: String
    var merchantKindRawValue: String
    var commonCadencesJSON: String
    var priceBandsJSON: String
    var cancellationURL: String?
    var websiteURL: String?
    var logoIdentifier: String?
    var confidencePrior: Double
    var catalogVersion: Int
}
```

Rules:

- Service profile hits shall boost confidence but shall not create subscriptions without transaction evidence.
- Price bands shall be weak priors only.
- Catalog updates shall not overwrite user corrections.

#### SubscriptionScheduleExpectation

Purpose: Replace a single cadence enum as the full schedule truth for matching and occurrence projection.

```swift
@Model
final class SubscriptionScheduleExpectation {
    var id: UUID
    var subscriptionID: UUID
    var cadenceRawValue: String
    var interval: Int
    var anchorPolicyRawValue: String
    var anchorDay: Int?
    var anchorWeekday: Int?
    var anchorOrdinal: Int?
    var dateToleranceBeforeDays: Int
    var dateToleranceAfterDays: Int
    var gracePeriodDays: Int
    var confidence: Double
    var sourceRawValue: String
    var updatedAt: Date
}
```

Anchor policies:

- `exactDayOfMonth`
- `endOfMonth`
- `nthWeekday`
- `sameWeekday`
- `sameCalendarDate`
- `rollingInterval`
- `unknown`

#### SubscriptionMatchRule

Purpose: Apply durable rules generated from confirmed evidence.

```swift
@Model
final class SubscriptionMatchRule {
    var id: UUID
    var subscriptionID: UUID?
    var canonicalName: String
    var merchantIdentityID: UUID?
    var serviceProfileID: UUID?
    var allowedRawMerchantsJSON: String
    var requiredTokensJSON: String
    var excludedTokensJSON: String
    var amountMinimum: Decimal?
    var amountMaximum: Decimal?
    var amountMedian: Decimal?
    var amountTolerancePercent: Double
    var currencyCode: String?
    var accountHint: String?
    var sourceHintRawValue: String?
    var scheduleExpectationID: UUID?
    var priority: Int
    var confidence: Double
    var isNegativeRule: Bool
    var createdFromRawValue: String
    var lastReplayAt: Date?
    var replayMatchCount: Int
    var replayCollisionCount: Int
    var updatedAt: Date
}
```

Rule application order:

1. Negative rules from false positives.
2. User-confirmed exact rules.
3. Merchant identity rules.
4. Service profile rules.
5. Newly discovered candidate rules.

#### SubscriptionOccurrence

Purpose: Persist expected-vs-observed payment history.

```swift
@Model
final class SubscriptionOccurrence {
    var id: UUID
    var subscriptionID: UUID
    var scheduleExpectationID: UUID?
    var expectedDate: Date
    var windowStartDate: Date
    var windowEndDate: Date
    var matchedTransactionID: UUID?
    var statusRawValue: String
    var observedDate: Date?
    var observedAmount: Decimal?
    var expectedAmount: Decimal?
    var dateDeltaDays: Int?
    var amountDeltaPercent: Double?
    var matchConfidence: Double
    var evidenceID: UUID?
    var createdByDetectionRunID: UUID?
    var updatedAt: Date
}
```

Statuses:

- `pending`
- `matched`
- `missed`
- `late`
- `early`
- `priceChanged`
- `duplicateInCycle`
- `manualConfirmed`
- `manualRejected`

#### SubscriptionDetectionEvidence

Purpose: Store explainable automation evidence.

```swift
@Model
final class SubscriptionDetectionEvidence {
    var id: UUID
    var detectionRunID: UUID?
    var subscriptionID: UUID?
    var candidateKey: String
    var decisionRawValue: String
    var confidence: Double
    var deterministicScore: Double
    var llmScore: Double?
    var evidenceFactorsJSON: String
    var matchedTransactionIDsJSON: String
    var rejectedTransactionIDsJSON: String
    var ruleIDsJSON: String
    var serviceProfileID: UUID?
    var merchantIdentityID: UUID?
    var llmProviderRawValue: String?
    var llmPromptVersion: Int?
    var llmInputFingerprint: String?
    var llmOutputJSON: String?
    var reason: String
    var createdAt: Date
}
```

Decisions:

- `autoConfirmed`
- `autoSuppressed`
- `needsReview`
- `ruleMatched`
- `ruleRejected`
- `occurrenceMatched`
- `occurrenceMissed`
- `priceChanged`
- `merchantCollision`

#### DetectionRun

Purpose: Group evidence and replay results for imports/syncs/rebuilds.

```swift
@Model
final class DetectionRun {
    var id: UUID
    var triggerRawValue: String
    var startedAt: Date
    var finishedAt: Date?
    var transactionCount: Int
    var ruleMatchCount: Int
    var candidateCount: Int
    var autoConfirmCount: Int
    var autoSuppressCount: Int
    var needsReviewCount: Int
    var llmEvaluationCount: Int
    var errorMessage: String?
}
```

### 4.3 Transaction Adapter Interface

Every adapter shall output `NormalizedTransactionSeed` plus `SourceTransactionIdentity` metadata.

```swift
protocol TransactionSourceAdapter {
    var source: TransactionSource { get }
    func prepareTransactions() async throws -> [SourceTransactionDraft]
}

struct SourceTransactionDraft: Sendable {
    var seed: NormalizedTransactionSeed
    var externalTransactionID: String?
    var externalAccountID: String?
    var sourceReferenceID: String?
    var sourceFingerprint: String
    var pendingExternalTransactionID: String?
    var sourceMetadata: [String: String]
}
```

Required adapters:

- CSV adapter using existing CSV importer.
- XLS/XLSX adapter using existing spreadsheet importers.
- QFX adapter.
- OFX adapter.
- SimpleFIN adapter.

Optional adapters:

- Plaid adapter.
- Receipt parser adapter.
- Email export adapter.

### 4.4 Evidence Factor Schema

`SubscriptionDetectionEvidence.evidenceFactorsJSON` shall encode a stable array:

```json
[
  {
    "key": "merchant_identity_match",
    "weight": 0.18,
    "score": 0.94,
    "source": "merchant_identity",
    "description": "Raw descriptors map to OpenAI with high confidence."
  },
  {
    "key": "occurrence_coverage",
    "weight": 0.24,
    "score": 0.83,
    "source": "occurrence_reconciliation",
    "description": "5 of 6 expected monthly charges matched within window."
  }
]
```

Required factor keys:

- `merchant_identity_match`
- `service_profile_match`
- `processor_unmasked`
- `known_subscription_descriptor`
- `cadence_fit`
- `anchor_fit`
- `amount_stability`
- `amount_band_match`
- `occurrence_coverage`
- `missed_occurrence_penalty`
- `price_change_signal`
- `user_confirmed_rule`
- `user_negative_rule`
- `llm_subscription_judgment`
- `category_negative_signal`
- `merchant_collision_penalty`

### 4.5 Local LLM Evidence Interface

Add a new generator method without removing existing methods:

```swift
func evaluateSubscriptionEvidence(
    _ input: SubscriptionEvidenceEvaluationInput
) async throws -> SubscriptionEvidenceEvaluationResult
```

Input:

```swift
struct SubscriptionEvidenceEvaluationInput: Hashable, Sendable {
    var candidateKey: String
    var canonicalName: String
    var displayName: String
    var rawMerchantVariants: [String]
    var memoSamples: [String]
    var categorySamples: [String]
    var serviceProfileName: String?
    var merchantKind: MerchantKind
    var subscriptionAffinity: Double
    var scheduleSummary: String
    var occurrenceSummary: String
    var amountSummary: String
    var negativeSignals: [String]
    var userRuleSummary: String?
}
```

Output:

```swift
struct SubscriptionEvidenceEvaluationResult: Hashable, Sendable {
    var isSubscription: Bool
    var confidence: Double
    var likelyServiceName: String?
    var likelyPlanDescriptor: String?
    var positiveSignals: [String]
    var negativeSignals: [String]
    var reasonSummary: String
}
```

The deterministic engine shall combine this result with non-LLM factors. It shall not blindly accept LLM output.

## 5. Acceptance Criteria

- **AC-001**: Given identical transactions imported twice from the same source, when the adapter upsert runs, then no duplicate `NormalizedTransaction` records are created.
- **AC-002**: Given a pending transaction and later posted transaction from the same source, when reconciliation runs, then Tally links or replaces them without double-counting a subscription occurrence.
- **AC-003**: Given a confirmed monthly subscription with a match rule, when a new matching charge imports, then Tally links the transaction before clustering and records a matched occurrence.
- **AC-004**: Given a confirmed subscription with no matching charge after the grace window, when occurrence reconciliation runs, then Tally records a missed occurrence and lowers confidence without immediately deleting the subscription.
- **AC-005**: Given a false-positive merchant correction, when future similar transactions import, then Tally applies a negative rule and suppresses the candidate unless strong contradictory evidence exists.
- **AC-006**: Given Apple, Google, PayPal, Stripe, Paddle, or FastSpring descriptors with service clues, when merchant identity runs, then Tally stores processor-unmask evidence and maps descriptors to stable merchant identities.
- **AC-007**: Given one merchant with multiple subscriptions at different amounts, when detection runs, then Tally keeps separate candidates by amount band, descriptor tokens, and schedule expectation.
- **AC-008**: Given charges on Jan 31, Feb 29, Mar 31, and Apr 30, when schedule expectation is inferred, then Tally identifies an end-of-month anchor and does not penalize February or April as drift.
- **AC-009**: Given a known service profile hit without recurring transaction evidence, when detection runs, then Tally does not create a confirmed subscription from the catalog alone.
- **AC-010**: Given Gemma unavailable on macOS or Apple Intelligence unavailable on iOS, when detection runs, then deterministic scoring completes without throwing and records no LLM evidence factor.
- **AC-011**: Given an LLM result with invalid enum or out-of-range confidence, when validation runs, then the result is rejected or clamped and the evidence record marks validation status.
- **AC-012**: Given a user confirms, suppresses, merges, splits, or edits a subscription, when review action completes, then Tally creates or updates durable match rules and replays affected transactions.
- **AC-013**: Given a historical import and a new SimpleFIN sync covering overlapping dates, when source reconciliation runs, then Tally identifies likely duplicates and does not double-count spend.
- **AC-014**: Given a price increase within a learned tolerance, when the next charge matches date and merchant windows, then Tally updates price history and keeps the subscription active.
- **AC-015**: Given a price jump beyond tolerance, when the next charge imports, then Tally records a price-change occurrence and review evidence instead of silently overwriting the price.

## 6. Test Automation Strategy

### 6.1 Unit Tests

Add or extend tests in `TallyTests`:

- `SourceTransactionIdentityTests.swift`
- `MerchantIdentityGraphTests.swift`
- `ServiceProfileMatchingTests.swift`
- `SubscriptionMatchRuleTests.swift`
- `SubscriptionOccurrenceReconciliationTests.swift`
- `SubscriptionDetectionEvidenceTests.swift`
- `SubscriptionEvidenceLLMValidationTests.swift`
- `SimpleFINAdapterTests.swift`
- `QFXOFXImporterTests.swift`

### 6.2 Existing Tests To Extend

- `CSVTransactionImporterTests.swift`: verify source identity, duplicate imports, and adapter output.
- `CSVTransactionImporterTests+Detection.swift`: verify rule-first detection before clustering.
- `CSVTransactionImporterTests+DetectionEdgeCases.swift`: add multi-subscription same merchant, EOM anchors, trial-to-paid, and missed-renewal cases.
- `CSVTransactionImporterTests+ReviewRules.swift`: verify review actions create match rules and negative rules.
- `CadenceDetectionTests.swift`: add anchor policy and interval tests.
- `PaymentProcessorUnmaskerTests.swift`: verify persisted processor evidence and merchant identity membership.
- `SubscriptionIntelligenceServiceTests.swift`: verify LLM evidence validation and deterministic fallback.
- `AIProviderSelectionTests.swift`: verify Gemma/Apple provider fallback still works.

### 6.3 Fixture Scenarios

Required fixtures:

- OpenAI monthly via card export, then SimpleFIN duplicate.
- Apple.com/bill with iCloud and Apple One split by amount/memo.
- Google YouTube Premium and Google One split by descriptor.
- Stripe Linear, Stripe OpenAI, and Stripe unrelated purchase.
- PayPal Canva monthly and PayPal retail purchase false positive.
- Amazon Prime annual plus Amazon retail monthly purchases.
- Annual domain renewal with price increase.
- Trial-to-paid conversion with first low amount and later normal amount.
- End-of-month monthly billing.
- Missed renewal after cancellation.
- Foreign currency subscription with converted card statement amount drift.

### 6.4 Validation Commands

The implementation thread shall run the repo's current verification commands after code changes. At minimum:

```sh
git diff --check
xcodebuild -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' build
xcodebuild -project Tally.xcodeproj -scheme Tally -destination 'platform=iOS Simulator,name=iPhone 16' build
```

If exact simulator names differ, use an available iOS simulator and record the destination.

## 7. Rationale & Context

### 7.1 Why Not Plaid-First

Plaid is useful but not open-source-friendly as a default. Production access is gated, requires approval, and uses secrets that cannot ship in a public client. Tally should treat Plaid as an optional adapter. The core evidence engine must work from local files and open-source-friendly feeds.

### 7.2 Why This Fits Current Tally

Tally already has the hard starting pieces:

- A source-agnostic transaction model exists.
- CSV/XLS/XLSX import exists.
- Classification and alias caches exist.
- Local LLM provider selection exists.
- Gemma and Apple Intelligence implementations already classify merchants and evaluate clusters.
- Processor unmasking exists.
- Cadence detection and scoring exists.
- Review rules and merchant corrections exist.
- Rebuild/replay patterns exist.

The proposed engine does not discard these pieces. It inserts durable layers around them:

1. Source identity before transaction insert.
2. Merchant identity before merchant grouping.
3. Service profile priors before scoring.
4. Match rules before new discovery.
5. Occurrence reconciliation after schedule inference.
6. Evidence persistence around every automated decision.
7. Local LLM evidence enrichment after deterministic feature extraction.

### 7.3 Research Inputs From Inspected Repos

The following repositories were inspected as architectural research inputs. The implementation shall use these as conceptual references only. The implementation shall not copy source code or seed data from GPL or AGPL repositories unless Tally intentionally adopts compatible licensing.

| ID | Repo | Inspected commit | Tracking model | Why it matters for Tally | Add to Tally | Do not borrow |
|----|------|------------------|----------------|--------------------------|--------------|---------------|
| **SRC-001** | [actualbudget/actual](https://github.com/actualbudget/actual) | `000d9574537f544d89901ce82c32990d15bb1eec` | Schedules backed by transaction rules. Automatic schedule finding scans transaction history, matches approximate dates and amounts, and links transactions to schedules. | This is the strongest reference for accurate automated recurring detection because confirmed behavior becomes executable rules, not just a static record. | Add `SubscriptionMatchRule`; apply rules before clustering; use date windows and amount tolerances; derive future rules from review decisions. | Do not borrow the budgeting template/category system or require users to manually curate schedules as the main workflow. |
| **SRC-002** | [firefly-iii/firefly-iii](https://github.com/firefly-iii/firefly-iii) | `891f5cb` | Bills are first-class records with amount windows, cadence, generated rules, transaction linking, rescans, and expected-vs-actual enrichment. | This is the strongest reference for subscription lifecycle repair: expected charges, actual payments, overdue state, and full historical rescans. | Add `SubscriptionOccurrence`; add amount bands; add hidden/internal rescan; add rule preview statistics; reconcile expected-vs-observed charges after every import. | Do not borrow full accounting breadth, object groups, budgets, webhooks, liabilities, or manual rule complexity. |
| **SRC-003** | [monetr/monetr](https://github.com/monetr/monetr) | `17c26af` | Budgeting app with transaction clustering using raw descriptors, merchant names, TF-IDF-like tokenization, DBSCAN-style clustering, and Plaid sync. | Merchant identity is a major accuracy bottleneck in Tally. Descriptor clustering helps avoid brittle exact merchant strings. | Add `MerchantIdentity` and `MerchantIdentityMember`; persist ranked tokens, raw descriptors, centroid/canonical identity, source/account hints, and confidence. | Do not copy its incomplete recurring detector or Plaid-only assumptions. |
| **SRC-004** | [francescogabrieli/Spectra](https://github.com/francescogabrieli/Spectra) | `a5d65a2c8c656519382c565df679f73c4f06f2bf` | Transaction-history app that applies overrides/rules, local categorization, static subscription merchant detection, temporal recurrence, and feedback replay. | It demonstrates the correct order for ambiguous data: apply user memory, use known merchant priors, then temporal recurrence, then review. | Add `SubscriptionDetectionEvidence`; persist evidence factors; add feedback replay; use service/profile priors before temporal scoring. | Do not copy AGPL code, merchant lists, or category-only subscription detection. |
| **SRC-005** | [ellite/Wallos](https://github.com/ellite/Wallos) | `fdec995` | Manual subscription ledger with explicit cycles, next payment, auto-renew/manual renewal, inactive state, replacement subscriptions, reminders, and AI recommendations. | It shows lifecycle fields that Tally should infer automatically from transaction evidence. | Add lifecycle evidence for auto-renew, manual-renew, one-time, inactive, cancellation, replacement, and reminder state. | Do not borrow manual-entry-first tracking or simplistic renewal math as detection truth. |
| **SRC-006** | [ajnart/subs](https://github.com/ajnart/subs) | `a37cf93b9919c9783f27b0273988e3e40e9f24f0` | Manual subscription tracker with a large service template catalog, domain/category/region metadata, duplicate prompts, and import validation. | Known-service priors are valuable, especially for local-first detection where bank descriptors are messy. | Add `ServiceProfile` catalog with aliases, domains, processor patterns, likely categories, common cadences, price bands, logo IDs, and cancellation URLs. | Do not use static template prices as truth or exact domain-price duplicate fingerprints as the main matching rule. |
| **SRC-007** | [meceware/wapy.dev](https://github.com/meceware/wapy.dev) | `babaf66` | Manual subscription ledger with future payment dates, notification state, and durable `PastPayment` records when a user marks a payment as paid. | The useful primitive is an occurrence ledger: every expected payment can become matched, missed, late, early, or manually confirmed. | Add `SubscriptionOccurrence`; store expected date, matched transaction, status, date delta, amount delta, and confidence. | Do not make manual "mark paid" the source of truth; transactions should remain primary. |
| **SRC-008** | [bscott/subtrackr](https://github.com/bscott/subtrackr) | `e45847073f53c369caa1b2d3ec3750f8e074bf09` | Manual subscription ledger with interval schedules, no-overflow month-end date logic, share counts, reminders, and an MCP automation surface. | It highlights date correctness and interval schedules, especially end-of-month and every-N-month cases that median-day cadence can mis-score. | Add `SubscriptionScheduleExpectation` with unit, interval, anchor policy, end-of-month handling, and date tolerance. Add automation actions for confirm, merge, split, suppress, and correction. | Do not copy AGPL code, manual-first workflow, or current-price-only accounting. |
| **SRC-009** | [DennisBauer/RecurringExpenseTracker](https://github.com/DennisBauer/RecurringExpenseTracker) | `9f2f5d208b3e8f13024e402e24515122f0b42f03` | Manual recurring expense tracker that projects payment instances and stores per-occurrence paid/unpaid state. | It cleanly separates subscription definition from projected expected occurrences. Tally needs that same separation, but fed by transaction matching. | Project expected payment slots from schedule expectations; reconcile imported transactions into slots; score subscriptions by coverage. | Do not copy GPL code or manual-first expense tracking semantics. |

### 7.4 Why These Additions Are Required

| Addition | Source repos | Why Tally needs it now |
|----------|--------------|------------------------|
| `SourceTransactionIdentity` | Actual Budget, Spectra, monetr | Accurate automation requires duplicate-safe ingestion before detection. Without this, overlapping CSV/SimpleFIN/Plaid imports double-count spend and corrupt cadence evidence. |
| `MerchantIdentity` / `MerchantIdentityMember` | monetr, Spectra, Actual Budget | Merchant descriptors are unstable. Persistent identity is required for Apple, Google, PayPal, Stripe, Paddle, Amazon, domain registrars, and bank-specific descriptor variants. |
| `ServiceProfile` | Subs, Wallos, Spectra | Known-service priors reduce manual review for obvious SaaS, streaming, software, storage, and membership services while still requiring transaction evidence. |
| `SubscriptionMatchRule` | Actual Budget, Firefly III, Spectra | Confirmed subscriptions must become executable future behavior. A review action should teach Tally, not just update one record. |
| `SubscriptionScheduleExpectation` | Actual Budget, SubTrackr, RecurringExpenseTracker | `SubscriptionCadence` is too coarse for every-two-month, end-of-month, nth-weekday, annual-date, and grace-window logic. |
| `SubscriptionOccurrence` | Firefly III, Wapy.dev, RecurringExpenseTracker | The system should prove a subscription by matching expected charges to actual charges over time, and it should learn from missed or late charges. |
| `SubscriptionDetectionEvidence` | Spectra, Firefly III, Actual Budget | Automation needs auditability. Every auto-confirm, auto-suppress, and review recommendation must explain which evidence factors drove the decision. |
| Local LLM evidence interface | Current Tally, Spectra | Tally already has Gemma and Apple Intelligence. They should enrich structured evidence for messy descriptors and edge cases, while deterministic scoring remains authoritative. |

### 7.5 Automation Philosophy

The app should automate when evidence is strong and ask only when ambiguity matters. A rebuild should be deterministic, explainable, and replay-safe. A user correction should teach future imports. Local LLMs should help interpret messy descriptors and edge cases, but persisted rules and observed transactions should remain the source of truth.

## 8. Dependencies & External Integrations

### External Systems

- **EXT-001**: SimpleFIN-compatible feed - optional source adapter for read-only bank transaction sync.
- **EXT-002**: Plaid - optional source adapter only; not required for core functionality.
- **EXT-003**: Receipt/email export sources - optional adapters that generate normalized transaction drafts.

### Third-Party Services

- **SVC-001**: None required for core local-first functionality.
- **SVC-002**: Optional remote bank providers shall be adapter-bound and removable without changing the evidence engine.

### Infrastructure Dependencies

- **INF-001**: SwiftData with CloudKit-compatible model migration or clear reset/export fallback.
- **INF-002**: Local disk storage for source connection metadata that is safe to sync or intentionally excluded from sync where credentials are involved.

### Technology Platform Dependencies

- **PLT-001**: macOS Gemma local runtime via existing `GemmaRuntime`.
- **PLT-002**: Apple Foundation Models where available through existing `FoundationModelsIntelligenceGenerator`.
- **PLT-003**: Swift concurrency for adapter sync and detection runs.

### Data Dependencies

- **DAT-001**: Existing imported transactions.
- **DAT-002**: Existing merchant aliases and classifications.
- **DAT-003**: Existing review rules and merchant corrections.
- **DAT-004**: Local service profile catalog.

## 9. Examples & Edge Cases

### 9.1 Rule-First Match

```text
Existing confirmed subscription:
  canonicalName: OpenAI
  cadence: monthly
  expected amount band: 20.00 to 22.00 USD
  expected date window: day 14 +/- 3 days
  raw descriptors: OPENAI, CHATGPT, STRIPE* OPENAI

New transaction:
  date: 2026-06-15
  amount: -20.00
  merchantRaw: STRIPE* OPENAI
  memo: CHATGPT PLUS

Expected result:
  Tally applies SubscriptionMatchRule before clustering.
  Tally links the transaction to OpenAI.
  Tally records SubscriptionOccurrence status matched.
  Tally raises confidence from occurrence coverage.
```

### 9.2 Same Processor, Different Subscriptions

```text
Transactions:
  APPLE.COM/BILL -2.99 memo ICLOUD
  APPLE.COM/BILL -19.95 memo APPLE ONE

Expected result:
  Tally creates one MerchantIdentity for Apple processor if needed.
  Tally creates separate subscription candidates by service clue and amount band.
  Tally does not collapse iCloud and Apple One into one subscription.
```

### 9.3 Missed Renewal

```text
Confirmed subscription:
  expectedDate: 2026-05-10
  gracePeriodDays: 5
  no matching transaction through 2026-05-20

Expected result:
  Tally records a missed occurrence.
  Tally lowers confidence.
  Tally keeps the subscription unless repeated misses or strong cancellation evidence exists.
  Tally surfaces "possibly ended" with evidence.
```

### 9.4 Local LLM Evidence

```json
{
  "isSubscription": true,
  "confidence": 0.91,
  "likelyServiceName": "Linear",
  "likelyPlanDescriptor": "SaaS subscription",
  "positiveSignals": [
    "Stripe descriptor resolves to a SaaS brand",
    "Charges are monthly and amount-stable",
    "Memo contains plan language"
  ],
  "negativeSignals": [],
  "reasonSummary": "This appears to be a monthly SaaS subscription billed through Stripe."
}
```

The deterministic scorer may use this as one evidence factor. It shall still require transaction, rule, service profile, or occurrence evidence to auto-confirm.

## 10. Validation Criteria

- **VAL-001**: All new SwiftData models are registered in `ModelContainerFactory`.
- **VAL-002**: All new models have migration/reset behavior documented before merge.
- **VAL-003**: All source adapters use the same transaction upsert path.
- **VAL-004**: `SubscriptionDetectionService.rebuildSubscriptions` no longer clears links without first preserving or recomputing rule/occurrence evidence.
- **VAL-005**: Existing tests for CSV imports, cadence detection, payment processor unmasking, merchant correction, and AI provider selection continue to pass.
- **VAL-006**: New tests demonstrate duplicate import prevention, source overlap reconciliation, rule-first matching, occurrence projection, missed renewals, and deterministic fallback without LLM.
- **VAL-007**: Every auto-confirmed or auto-suppressed subscription has a `SubscriptionDetectionEvidence` record.
- **VAL-008**: Every LLM-influenced evidence record includes provider, prompt schema version, input fingerprint, output JSON, and validation state.
- **VAL-009**: False-positive rules prevent rediscovery on subsequent imports unless evidence exceeds a documented override threshold.
- **VAL-010**: Confirmed subscription corrections replay across historical transactions and future imports.

## 11. Related Specifications / Further Reading

- `Plaid Plan.md` - existing optional Plaid plan; should be revised so Plaid is not foundational.
- `docs/subscription-detection-evaluation.md` - existing detection evaluation context.
- `Tally/Services/Detection/SubscriptionDetectionService.swift` - current rebuild entry point.
- `Tally/Services/Detection/SubscriptionDetectionPipeline.swift` - current detection passes.
- `Tally/Services/Detection/SubscriptionDetectionService+Scoring.swift` - current scoring and LLM-assisted cluster evaluation.
- `Tally/Services/Intelligence/GemmaLocalIntelligenceGenerator.swift` - current local Gemma generator.
- `Tally/Services/Intelligence/FoundationModelsIntelligenceGenerator.swift` - current Apple Intelligence generator.
