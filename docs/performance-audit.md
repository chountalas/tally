# Performance and responsiveness audit (Tally)

**Scope:** Static codebase review only (two passes). **No code changes** in this document.

**Stack (from repo):** SwiftUI, SwiftData, on-device **Apple Foundation Models** (`FoundationModels` / `LanguageModelSession`) for classification, copilot copy, and detection “second pass” scoring.

---

## Executive summary

Slowness and “clicks not landing” are **very unlikely** to be a single bug. The app combines:

1. **Heavy, sequential on-device LLM work** during import, “refresh analysis,” and subscription detection when Apple Intelligence is available.
2. **MainActor-centered orchestration** (`AppModel`, `SubscriptionDetectionService`, copilot `respond`) so UI and long async work can **compete for the same actor** and leave the main runloop busy.
3. **Repeated O(N) work over the full transaction/subscription set** inside SwiftUI view bodies (notably the dashboard) and in copilot **cache key** computation.

**Verdict:** **Yes — Apple Intelligence reliance can explain freezes**, especially during/after import and “Refresh analysis,” not because the framework is “bad,” but because the app **awaits many model calls** in hot paths and gates wide score bands into those calls. **Yes — there are also “sloppy for scale” patterns** (full fetches, repeated scans, work in `body`) that will amplify jank as the library grows.

---

## Methodology (check once, check again)

**Pass 1 — Trace AI and async entry points:** Located `LanguageModelSession` usage, classification batching, copilot flow, and detection scoring hooks.

**Pass 2 — Confirm actors and UI coupling:** Re-checked `@MainActor` on [`Tally/Services/Detection/SubscriptionDetectionService.swift`](../Tally/Services/Detection/SubscriptionDetectionService.swift), [`Tally/Services/Intelligence/SubscriptionIntelligenceService.swift`](../Tally/Services/Intelligence/SubscriptionIntelligenceService.swift), [`Tally/App/AppModel.swift`](../Tally/App/AppModel.swift), and verified gating conditions for second-pass AI in [`Tally/Services/Detection/SubscriptionDetectionService+Signals.swift`](../Tally/Services/Detection/SubscriptionDetectionService+Signals.swift).

---

## Finding 1 — Apple Intelligence: many sequential awaits on hot paths (high impact)

**Merchant classification (import / refresh):**

- [`MerchantClassificationEngine`](../Tally/Services/Classification/MerchantClassificationEngine.swift) switches to **per-merchant** `classify` when unique merchants ≤ 25 (`foundationBatchThreshold`), which runs a loop calling `intelligence.classifyMerchant` **sequentially** (`individualBatchResult`).
- Above that threshold it uses batch Foundation Models calls (`foundationBatchResult`) but still **loops batches of 20** with `await` each time.

**Copilot:**

- [`SubscriptionCopilotSheetSupport.run`](../Tally/Features/Intelligence/SubscriptionCopilotSheetSupport.swift) sets loading state then `await intelligence.respond(...)`.
- [`SubscriptionIntelligenceService.respond` / `computeResponse`](../Tally/Services/Intelligence/SubscriptionIntelligenceService.swift) are **`@MainActor`** and, when a generator exists, **`await generator.generateCopy`** after building a draft — i.e. **LLM work is structured around main-actor-isolated orchestration**.

**Detection “second pass” (major insight):**

- [`SubscriptionDetectionService`](../Tally/Services/Detection/SubscriptionDetectionService.swift) is **`@MainActor`**.
- When `intelligence.generator != nil`, [`automaticRecurringClusterEvaluationEnabled`](../Tally/Services/Detection/SubscriptionDetectionService+Signals.swift) is **true**.
- [`shouldRunSecondPassAI`](../Tally/Services/Detection/SubscriptionDetectionService+Signals.swift) returns **true for `baseScore` in 0.25…0.92** — a wide band — so **many clusters** can each trigger `await intelligence.evaluateRecurringCluster` ([`SubscriptionDetectionService+Scoring.swift`](../Tally/Services/Detection/SubscriptionDetectionService+Scoring.swift)).
- Single-charge path similarly gates `await intelligence.evaluateSingleCharge` for **`baseScore` in 0.3…0.92** ([`shouldRunSingleChargeAI`](../Tally/Services/Detection/SubscriptionDetectionService+Signals.swift)).

**Why this matches your symptoms:** Import commit and “Refresh analysis” both call into classification + `saveChangesAndRefreshSubscriptions` → full detection rebuild ([`AppModel.commitImport`](../Tally/App/AppModel.swift), [`refreshSubscriptionAnalysis`](../Tally/App/AppModel+DataMaintenance.swift)). During that window, **dozens/hundreds of sequential model inferences** are plausible, which feels like **app-wide unresponsiveness** and **delayed tap handling**.

---

## Finding 2 — MainActor concentration vs. long-running work (high impact)

Structures/methods that anchor work on the main actor:

| Area | File | Risk |
|------|------|------|
| App shell | [`AppModel`](../Tally/App/AppModel.swift) `@MainActor @Observable` | Import commit, refresh, learning — coordinates heavy work |
| Detection | [`SubscriptionDetectionService`](../Tally/Services/Detection/SubscriptionDetectionService.swift) `@MainActor` | Full pipeline + awaits AI scoring |
| Copilot | [`SubscriptionIntelligenceService.respond`](../Tally/Services/Intelligence/SubscriptionIntelligenceService.swift) `@MainActor` | Draft + optional LLM |
| Spotlight | [`SubscriptionSpotlightIndexer`](../Tally/Services/Intelligence/SubscriptionSpotlightIndexer.swift) `@MainActor` | Index rebuild after saves |

Even when `await` **suspends**, **scheduling and UI updates** remain sensitive to how much work batches before the next yield. Detection runs long **async** functions **without** the same `Task.yield` cadence as import classification (which yields every 8 merchants / 100 seeds / 250 transactions in places).

---

## Finding 3 — SwiftUI: repeated full-library work in view bodies (high impact on scroll/taps)

**Dashboard** ([`DashboardView.swift`](../Tally/Features/Dashboard/DashboardView.swift)):

- Builds `DashboardMetrics(subscriptions:transactions:)` **inside `body`**. [`DashboardMetrics.init`](../Tally/Features/Dashboard/DashboardMetrics.swift) filters **all** transactions, builds grouping dictionaries, spend series, overlaps, etc. — **O(N)** on **every** invalidation.
- Builds `reviewPreviews` with `merchantLearningPreview` for up to four subscriptions; that helper filters the **full** `transactions` array per subscription ([`AppModel+Actions.swift`](../Tally/App/AppModel+Actions.swift) via `linkedTransactions` / filters).

**Copilot sheet** ([`SubscriptionCopilotSheet.swift`](../Tally/Features/Intelligence/SubscriptionCopilotSheet.swift)):

- Four `@Query` properties load **all** subscriptions, **all** transactions (sorted), aliases, classifications into memory for the sheet.

**Effect:** As data grows, **ordinary state changes** (animations, `Observable` updates, SwiftData change notifications) can trigger expensive body recomputation → **frame drops** and **input lag** that feels like “broken clicks.”

---

## Finding 4 — Copilot cache key is accidentally expensive (medium–high)

[`responseCacheKey`](../Tally/Services/Intelligence/SubscriptionIntelligenceService.swift) (also `@MainActor`) calls:

- `tooling.allSubscriptions()`, `allTransactions()`, `libraryOverview()`, etc., then scans for **min/max transaction dates** and stringifies library-wide stats — **on every cache lookup path**.

So copilot interactions can add **extra full-library scans** beyond what the draft response already does.

---

## Finding 5 — SwiftData “fetch everything” patterns (medium)

Examples:

- `fetchTransactions` / [`SubscriptionDetectionPipeline`](../Tally/Services/Detection/SubscriptionDetectionPipeline.swift): full transaction fetch for detection.
- [`applyMerchantLearning`](../Tally/App/AppModel+Actions.swift): `FetchDescriptor<NormalizedTransaction>()` with **no predicate** — loads **all** rows to compute previews and relink merchants.
- [`replayMerchantResolution`](../Tally/App/AppModel+Actions.swift): again fetches all transactions then filters.

These are **correct** for small libraries but **scale linearly** and amplify Main-thread/SwiftUI pressure when combined with Finding 3.

---

## Finding 6 — Asset catalog size (low confidence for runtime freezes)

The workspace contains a **very large** [`BrandLogos.xcassets`](../Tally/Resources/BrandLogos.xcassets) tree (thousands of JSON entries in glob results). That can hurt **build times and binary size**; **runtime** impact depends on whether the app enumerates or eagerly loads assets (not verified here). Mentioned as **secondary suspicion** only.

---

## Finding 7 — Unused / redundant AI API (informational)

[`AuditIntelligenceService.generateOneLiner`](../Tally/Services/Intelligence/AuditIntelligenceService.swift) appears **unused** in the feature code (audit UI uses `fallbackOneLiner` only in [`AuditView+Content.startAudit`](../Tally/Features/Audit/AuditView+Content.swift)). Not a performance bug today, but shows **surface area** for accidental future misuse.

---

## What this is *not* (without Instruments)

This audit **does not** replace **Time Profiler**, **Swift Concurrency**, or **Signpost** traces. Unknowns:

- Exact SwiftData fetch costs on device.
- Whether `LanguageModelSession.respond` always yields promptly off the runloop.
- Real concurrency logs (priority inversion, actor contention).

---

## Recommended next steps (implementation / product)

1. **Profile on device:** See [Instrumentation checklist](#instrumentation-checklist) below.
2. **Measure model call counts:** Log each `evaluateRecurringCluster` / `evaluateSingleCharge` / batch classify during one detection run — expect large numbers when AI is enabled.
3. **Architecture direction:** Move detection + classification orchestration off `@MainActor` where possible; keep only UI mutations on MainActor; batch/throttle AI; narrow `shouldRunSecondPassAI` bands or cap calls per run; cache `DashboardMetrics`; avoid full scans in `body`.

---

## File reference index (primary)

- [`Tally/Services/Detection/SubscriptionDetectionService.swift`](../Tally/Services/Detection/SubscriptionDetectionService.swift)
- [`Tally/Services/Detection/SubscriptionDetectionService+Scoring.swift`](../Tally/Services/Detection/SubscriptionDetectionService+Scoring.swift)
- [`Tally/Services/Detection/SubscriptionDetectionService+Signals.swift`](../Tally/Services/Detection/SubscriptionDetectionService+Signals.swift)
- [`Tally/Services/Classification/MerchantClassificationEngine.swift`](../Tally/Services/Classification/MerchantClassificationEngine.swift)
- [`Tally/Services/Intelligence/SubscriptionIntelligenceService.swift`](../Tally/Services/Intelligence/SubscriptionIntelligenceService.swift)
- [`Tally/Services/Intelligence/FoundationModelsIntelligenceGenerator.swift`](../Tally/Services/Intelligence/FoundationModelsIntelligenceGenerator.swift)
- [`Tally/Features/Dashboard/DashboardView.swift`](../Tally/Features/Dashboard/DashboardView.swift) + [`DashboardMetrics.swift`](../Tally/Features/Dashboard/DashboardMetrics.swift)
- [`Tally/Features/Intelligence/SubscriptionCopilotSheet.swift`](../Tally/Features/Intelligence/SubscriptionCopilotSheet.swift)
- [`Tally/App/AppModel.swift`](../Tally/App/AppModel.swift) + [`AppModel+DataMaintenance.swift`](../Tally/App/AppModel+DataMaintenance.swift) + [`AppModel+Actions.swift`](../Tally/App/AppModel+Actions.swift)

---

## Instrumentation checklist

Use Xcode **Instruments** on a **Debug or Release** build on real hardware (Foundation Models behavior is device-dependent).

1. **Time Profiler**
   - Attach to the running app.
   - Record while: cold launch → open Dashboard → scroll → tap “Refresh analysis” (or complete an import) → open Copilot → ask one question.
   - Sort by **Self** time and **call tree**; look for `DashboardMetrics.init`, SwiftData `fetch`, `LanguageModelSession`, and main-thread-heavy SwiftUI layout.

2. **Swift Concurrency instrument** (when available for your Xcode version)
   - Watch for **main actor wait** duration and long tasks that keep the main actor busy.
   - Correlate with periods of UI unresponsiveness.

3. **Hangs / responsiveness** (if available)
   - Captures main-thread stalls; good for “clicks don’t register” reports.

4. **Optional: os_signpost** (future code change)
   - Wrapping `rebuildSubscriptions`, `loadClassifications`, and each AI evaluation would give definitive counts and timings; not present in the codebase today.

5. **Hypothesis to validate**
   - During one “Refresh analysis,” expect **many** detection second-pass AI calls when Apple Intelligence is on (see Finding 1). Counting those in logs is the fastest way to confirm the hypothesis before larger refactors.
