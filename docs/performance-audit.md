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

## Round 2 measurements (July 12, 2026)

The installed app was still the July 8 v0.1.3 release and did not contain the
merged PR #6 code. The installed build reached
accessible Home content in 1,516 ms on the first measured launch, then 1,129 ms
and 1,031 ms on warm launches. The merged debug build reached Home in 501–563
ms against its developer store and 521–745 ms with the DEBUG in-memory store.
These are launch-to-accessible-content measurements, not window-creation
timings, and they log no merchant or account data.

The launch binary also links the optional 9.5 MB `llama.framework` eagerly.
Because Swift directly imports its C module, removing that launch dependency
requires a dedicated dynamic-runtime boundary (`dlopen`/typed symbol wrappers
or a helper process). This pass records that architectural work instead of
shipping an unverified linker flag that could break local Gemma at runtime.

A release-optimized in-memory SwiftData smoke run with 25,000 synthetic
transactions measured the new 100-row initial page at 18.8 ms. Fetching all
25,000 model objects in the same process took 870.9 ms before SwiftUI created
any rows, roughly 46× longer. Database-side search found three cross-field
matches and materialized only the requested two-row limit.

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
- The Transactions root now uses database-backed paging. Opening the screen
  materializes at most 100 rows initially instead of every transaction in the
  ledger; Show More raises the fetch limit in 100-row steps, and debounced
  search is applied by SwiftData before the limit.

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
- Service-logo resolution now memoizes complete lookup keys and explicit asset
  existence probes. A resolved manifest asset is no longer loaded once to
  prove it exists and then loaded again by the same row render.

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

### Optional Gemma runtime is still an eager launch dependency

`GemmaRuntime.swift` directly imports the bundled llama C module, so dyld loads
`llama.framework` even when the selected provider is not Gemma. A future pass
should isolate the C API behind a dynamically loaded adapter or helper process,
then compare cold-launch traces and verify inference, unload, and missing-
framework behavior before changing the shipping link model.
