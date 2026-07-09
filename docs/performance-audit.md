# Performance and responsiveness audit (Tally)

Scope: source audit plus implementation pass. This document records the
performance causes found in the current app, the fixes applied in this branch,
and the remaining validation work that still needs Instruments or real ledger
data.

## Summary

The slowness was not one isolated bug. The app had a few compounding patterns:

1. SwiftUI views fetched or scanned broad transaction arrays during ordinary
   view invalidations.
2. Several views rebuilt expensive grouping/filtering state directly from
   computed properties used by `body`.
3. Subscription detail loaded charge history synchronously through body-driven
   fetches.
4. Background detection could still do evidence-only AI work during import or
   refresh, even when deterministic scoring had enough data.
5. The review queue forced a binary "keep vs dismiss" decision, which made users
   choose the wrong persistence behavior for "mine, but not recurring" charges.

This pass focuses on immediate responsiveness and workflow correctness without
changing Tally's local-first architecture.

The follow-up UX audit also added a DEBUG-only in-memory launch path
(`TALLY_IN_MEMORY_STORE=1`) and preview routes for utility screens, so windowed
QA can be run without touching the user's persistent finance library.

## Fixes applied

### Smaller SwiftData query surfaces

- Dashboard, Insights, and Subscriptions now query only transactions already
  linked to subscriptions instead of pulling every normalized transaction into
  those views.
- Merchant drilldowns in Transactions now use a predicate-backed query per
  merchant instead of filtering a preloaded all-transaction array.

Primary files:

- `Tally/Features/Dashboard/DashboardView.swift`
- `Tally/Features/Insights/InsightsView.swift`
- `Tally/Features/Subscriptions/SubscriptionsView.swift`
- `Tally/Features/Transactions/TransactionsView.swift`

### Fewer repeated body computations

- Dashboard binds one `DashboardContentSnapshot` per render pass, and that
  snapshot now carries the review queue count used by the sidebar/tab badges.
- Subscriptions builds one `SubscriptionListSnapshot` containing active/former
  lists, review rows, counts, visible filters, groups, and monthly total.
- Calendar builds one `CalendarMonthSnapshot` per visible month and uses stable
  agenda row IDs.
- Subscription detail moves displayed charge-row loading into a task keyed by
  the subscription and library revision instead of fetching from `body`.

Primary files:

- `Tally/App/AppModel.swift`
- `Tally/Features/Calendar/CalendarView.swift`
- `Tally/Features/Subscriptions/SubscriptionDetailView.swift`
- `Tally/Features/Subscriptions/SubscriptionsView.swift`

### Less background AI pressure

- `SubscriptionIntelligenceService` now retains its usage mode.
- Background subscription detection skips evidence-only LLM contribution calls.
  Deterministic detection and the existing ambiguous-scoring gates remain in
  place, but import/refresh work no longer spends extra model calls just to add
  evidence prose.

Primary files:

- `Tally/Services/Intelligence/SubscriptionIntelligenceService.swift`
- `Tally/Services/Detection/SubscriptionDetectionService+EvidenceEngine.swift`

### Review-flow correction

- Suggested subscriptions now expose separate actions: keep, edit, mine but not
  a subscription, and not mine / wrong account.
- "Mine, not a subscription" teaches the detector a false-positive rule.
- "Not mine / wrong account" hides the suggestion without teaching Tally that
  the merchant is never a subscription.
- Hidden suggestions now survive future detection rebuilds.

### UX correctness hardening

- The transaction ledger pages beyond the initial 100 rows instead of hiding the
  rest behind static text.
- Import review disables impossible mappings before classification work starts.
- Manual creation avoids detector-only review states and guards duplicate saves.
- Subscription detail separates projected charge estimates from real imported
  charges and confirms cancellation before mutating reminders/calendar events.
- Settings dividers render as real hairlines rather than isolated center dots.

Primary files:

- `Tally/App/AppModel+Actions.swift`
- `Tally/Services/Detection/SubscriptionDetectionPersistence.swift`
- `Tally/Features/Subscriptions/SubscriptionsView.swift`
- `Tally/Features/Subscriptions/SubscriptionDetailView.swift`
- `TallyTests/UnifiedSubscriptionLibraryTests.swift`

## Remaining performance risks

### Full detection rebuilds still scale linearly

`SubscriptionDetectionService.rebuildSubscriptions` still fetches the full
transaction set and runs the pipeline on the main actor. This pass reduced view
jank and avoidable AI work, but large-ledger refresh/import performance still
needs a larger architecture pass: incremental detection inputs, off-main
orchestration, and tighter save boundaries.

### Copilot still has broad data surfaces

The copilot sheet and response cache can still inspect broad subscription and
transaction data. That is acceptable for small libraries, but it remains a
likely hotspot for large histories and should be profiled separately.

### Import classification can still make many model calls

Merchant classification still performs sequential model-backed work when AI is
available. This was not widened in this pass, but it remains a candidate for
call caps, batching policy changes, and progress-yield instrumentation.

### Runtime profiling is still required

This source-level pass does not replace:

- Time Profiler on a real large ledger.
- Swift Concurrency instrument for main-actor wait time.
- Hangs / responsiveness instrument while importing, refreshing analysis,
  scrolling lists, opening detail, and asking copilot questions.

## Instrumentation checklist

Use a Debug or Release build on real hardware with representative transaction
data.

1. Record cold launch, Dashboard, Subscriptions, Calendar, and Transactions
   scroll/tap flows in Time Profiler.
2. Run import and "Refresh analysis" with Swift Concurrency enabled; inspect
   main actor wait time and long tasks.
3. Count subscription detection AI calls per rebuild.
4. Profile Copilot open, cache-key lookup, and one custom question.
5. Re-run after unplugging or unlocking passcode-protected attached devices;
   Xcode repeatedly probes attached iOS devices during macOS test/build runs and
   those warnings can dominate command time.
