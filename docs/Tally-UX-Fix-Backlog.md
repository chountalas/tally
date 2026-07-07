# Tally — UX/Quality Fix Backlog

Remaining items from the 2026-07-06 full-app audit (branch `audit/ux-flow-fixes`).
Everything reproducible and safely fixable was fixed on that branch; these need
either product intent, real-device validation, or a feature build.

## P1 — Feature gaps that cap detection quality

### 1. EventKit calendar write-sync is unimplemented
- **Today:** `RenewalCalendarService` only has `authorizationStatus()` and
  `clearSyncedEvents()`; no code ever creates an `EKEvent`.
  `Subscription.calendarEventIdentifier` is always nil. The in-app Calendar tab
  works, but nothing lands in Apple Calendar despite the PRD listing EventKit
  sync as done (tally-prd.md "Calendar tab with EventKit sync controls").
- **Acceptance:** enabling sync writes one event per upcoming renewal into a
  dedicated "Tally" calendar, re-sync is idempotent (update via
  `calendarEventIdentifier`, no duplicates), disabling removes them, permission
  denial surfaces a path to Settings.
- **Likely files:** `Tally/Services/Calendar/RenewalCalendarService.swift`,
  `SettingsView.swift`, `Subscription.swift`.

### 2. OFX / SimpleFIN bank-feed import is built but unreachable
- **Today:** `BankFeedTransactionAdapters.swift` + `TransactionSourceAdapter`
  are implemented and unit-tested (6 tests) but no UI path reaches them — no
  `.ofx` UTType in the file picker, no SimpleFIN connection UI.
- **Acceptance:** `.ofx`/`.qfx` selectable in the import picker and parsed
  through the existing adapter; SimpleFIN token setup in Settings (needs a
  product decision on scope).
- **Likely files:** `TransactionsView.swift:202` (allowed content types),
  `AppModel.swift` import branch, `SettingsView.swift`.

### 3. Copilot ("Ask Tally") AI is a paraphrase layer, not a reasoner
- **Today:** the answer (routing, evidence, actions, confidence) is fully
  deterministic; the model only rewrites `headline`/`summary`/`followUps` from
  a pre-digested `facts` string and can't answer novel questions
  (`SubscriptionIntelligenceService.swift:294-322`, routing at `:246-261` is
  substring matching).
- **Acceptance:** custom questions get grounded answers over real library data
  (subscriptions + recent transactions in the prompt within a token budget),
  with the deterministic engine kept as fallback and for action synthesis.
- **Likely files:** `SubscriptionIntelligenceService+Responses.swift`,
  `GemmaLocalIntelligenceGenerator.swift:105-125`,
  `FoundationModelsIntelligenceGenerator.swift`.

### 4. Few-shot examples in classification/evaluation prompts
- **Today:** all prompts are instruction-only; the small Gemma E4B model would
  benefit most from 3–5 exemplars per task (classification, recurring-cluster,
  single-charge). Untestable without the 5 GB model on a dev machine, so do it
  alongside a manual model-loaded validation session.
- **Likely files:** `GemmaLocalIntelligenceGenerator.swift` prompt strings; bump
  `SubscriptionIntelligenceResultCache.cacheVersion` when prompts change
  (it was last bumped 2026-04-14 and is already stale relative to prompt edits).

## P2 — Correctness/robustness polish

### 5. Import "Refresh my data" mislabel / refreshSubscriptionAnalysis orphan
- `AddUpdateSheet.swift:54` "Refresh my data" opens the file picker;
  `AppModel+DataMaintenance.refreshSubscriptionAnalysis` (re-classify + re-detect
  without a new file) has no UI caller. Decide intent: add a "Re-run detection"
  action (Settings or chooser) wired to it, or delete the dead path.

### 6. Two price-change detectors disagree
- `DashboardMetrics.priceChangedSubscriptions` uses stored
  `priceChangePercent > 0.05`; `DashboardMetricsSupport.hasPriceIncrease`
  recomputes from transactions with ≥ 0.08. Unify source + threshold.

### 7. App Intents build fresh ModelContainers per call and swallow errors
- `SubscriptionAppIntents.swift:287-305` (and `:148-150` builds two in one
  call): open failures return empty stores, so Siri/Shortcuts says "no
  subscriptions" instead of erroring. Share one container and surface failure.

### 8. Interactive intelligence service does filesystem I/O on first MainActor access
- `SubscriptionCopilotSheet.intelligence` (`:27`) and
  `ManualSubscriptionDraftAdvisor` construct the service (stat/GGUF header
  read/symlink) synchronously on the main actor. Move construction off-main or
  cache app-wide.

### 9. Gemma download integrity
- `GemmaModelManager.installDownloadedModel` validates only GGUF magic + size;
  add a checksum (HF provides SHA256) so a truncated 5 GB download fails fast.

### 10. Latin1 encoding fallback yields silent mojibake
- `ImportModels.swift:116`: Latin1 always decodes, so genuinely mis-encoded
  files import garbled merchant names with no warning. Add a mojibake heuristic
  (e.g. replacement-char/control-char density) and warn.

### 11. Header-row detection assumes row 0
- Bank exports with preamble rows mis-map columns
  (`CSVTransactionImporter.swift:9`). Detect the first row that parses as a
  header (or expose a "header row" stepper in the review sheet).

### 12. iOS / CloudKit validation pass (PRD "Pending")
- Real-device iPhone run, CloudKit sync between two devices, conflict behavior.
  Cannot be verified on this Mac alone.

## Notes
- A passcode-locked iPhone plugged into the build Mac stalls every `xcodebuild`
  invocation several minutes on device discovery.
