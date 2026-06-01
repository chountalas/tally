# Subscription Detection Evaluation

The repo includes a deterministic subscription-detection fixture harness in:

- `TallyTests/SubscriptionDetectionFixtureHarness.swift`
- `TallyTests/SubscriptionDetectionEvaluationHarnessTests.swift`

This harness is intentionally heuristic-first and deterministic. It exercises the fallback classifier path directly, which means it is useful both as a regression suite for the detection pipeline and as a guardrail for the "Apple Intelligence unavailable" degraded path described in the PRD.

## Current harness shape

- `20` total fixtures
- `15` positive expectations
  - `14` confirmed positives
  - `1` review-positive candidate
- `5` negative expectations

The test target now also records fixture labels and identity-set matching so the suite can catch:

- missing expected services
- extra unexpected services
- processor-unmasking regressions
- cadence-specific regressions hidden by aggregate precision/recall

## Fixture coverage

The expanded suite covers the original 13 scenarios plus these missing prompt edge cases:

- merchant-name variations collapsing into one canonical service
- price changes over time without splitting a subscription
- refunds / reversed charges not suppressing a true subscription
- additional processor-masked merchants beyond Stripe / PayPal / Apple
- multiple subscriptions from the same vendor family in one ledger
- leap-year and end-of-month monthly renewals
- quarterly cadence detection

### Label inventory

Representative labels now present in the suite:

- `annual`
- `apple_masked`
- `creator_membership`
- `end_of_month`
- `google_masked`
- `leap_year`
- `merchant_variation`
- `multi_subscription_vendor`
- `non_monthly_cadence`
- `paypal_masked`
- `price_change`
- `processor_masked`
- `quarterly`
- `refund_reversal`
- `review_candidate`
- `saas`
- `streaming`
- `stripe_masked`
- `trial_to_paid`
- `variable_amount`

## Added fixtures

These scenarios were added to reduce fragility in the harness:

| Fixture ID | Expected result | Why it matters |
|---|---|---|
| `netflix_merchant_variants` | confirmed positive | Ensures `NETFLIX`, `NETFLIX.COM`, and suffixed merchant strings still normalize to `Netflix`. |
| `figma_price_increase` | confirmed positive | Protects against price-rise regressions splitting one subscription into multiple clusters. |
| `dropbox_refund_reversal` | confirmed positive | Confirms refunds/reversals do not erase an obvious recurring service. |
| `google_youtube_premium_masked` | confirmed positive | Extends processor-mask coverage to Google-originated charges. |
| `apple_multi_service_same_vendor` | confirmed positive | Verifies one vendor family can surface multiple services (`Apple Music` + `iCloud`) in the same import. |
| `hulu_end_of_month_leap_year` | confirmed positive | Covers February/leap-year drift for monthly billing. |
| `patreon_quarterly_plan` | confirmed positive | Adds non-monthly cadence coverage for quarterly recurring charges. |

## Metrics and reporting model

The harness still reports precision / recall, false positives, false negatives, review overflow, and identity mismatches. It now also exposes:

- expected outcome counts (`confirmedPositive`, `reviewPositive`, `negative`)
- label coverage counts
- surfaced canonical names per fixture
- missing expected canonical names per fixture
- unexpected surfaced canonical names per fixture

That means the suite can fail not only when a subscription disappears, but also when detection starts over-surfacing or collapsing distinct services.

## Verification status

### Last fully observed run before this expansion

The previously verified 13-case suite produced:

- precision: `1.0000`
- recall: `1.0000`
- false positives: `0`
- false negatives: `0`
- review overflow: `0`
- identity mismatches: `0`

### Fresh observed run after expansion

A fresh targeted run now succeeds against the expanded `20`-case suite:

- command:
  `xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/tally-tests-targeted -only-testing:TallyTests/SubscriptionDetectionEvaluationHarnessTests`
- total cases: `20`
- positive cases: `15`
- surfaced cases: `15`
- true positives: `15`
- false positives: `0`
- false negatives: `0`
- review overflow: `0`
- identity mismatches: `0`
- precision: `1.0000`
- recall: `1.0000`

The observed run also confirms the new fixture additions are behaving as intended:

- merchant variation normalization still collapses to one canonical service
- price increases do not split a subscription
- refunds do not suppress true subscriptions
- Google / Apple / Stripe / PayPal masking scenarios remain stable
- multiple services from the same vendor family can surface together
- leap-year / end-of-month cadence drift is tolerated
- quarterly cadence remains detectable

## Notes

- This document is intentionally scoped to the evaluation harness and reporting surface only.
- No app-source files were changed as part of this update.
