# Tally UX and quality backlog

Current status after the performance and UX flow pass.

## Fixed in this pass

### Review queue decisions

The review queue no longer forces a binary "mine" / "not mine" style choice.
Suggested rows and detail pages now support:

- Keep: this is a real subscription.
- Edit: correct amount, cadence, status, category, or notes.
- Mine, not a subscription: suppress this merchant as a recurring false
  positive.
- Not mine / wrong account: hide this suggestion from this library without
  creating a merchant-level false-positive rule.

The "not mine / wrong account" path is covered by a regression test to ensure
the hidden suggestion does not come back as `suggested` after detection rebuilds.

### Responsiveness in core browsing flows

The Home, Insights, Subscriptions, Calendar, Transaction merchant detail, and
Subscription detail flows now do less repeated full-library work during render.
This should make ordinary tab switches, scrolls, taps, and detail opens feel
substantially less glitchy on larger libraries.

The Transactions root now fetches only the visible page from SwiftData rather
than loading the entire ledger before showing 100 rows. Logo rows also reuse
resolved brand matches and catalog-existence results across view invalidations.
At 25,000 synthetic rows, the bounded fetch took 18.8 ms versus 870.9 ms for
the prior all-row fetch shape in the same optimized smoke process.

### Layout resilience

Subscription detail review actions now wrap through `ViewThatFits`, so the
expanded action set can fit compact windows without button overlap.

Review rows now wrap their action controls at compact widths, so Edit, Dismiss,
and Keep remain reachable without crowding the service name.

### Import and transaction flow polish

- Transactions no longer hard-stop at the first 100 rows; the ledger now pages
  forward with an explicit "Show more" control.
- CSV, Excel, OFX, and QFX support is reflected consistently in Transactions
  and Imports empty states.
- The import review sheet now blocks impossible mappings before import when no
  parseable rows, usable merchants, or debit rows are present.

### Manual and detail flow polish

- Manual creation now offers Active and Former only. The detector-only "Needs
  Review" state remains available when editing an existing suggested item.
- Manual save is guarded against duplicate taps, website URLs require a real
  http/https host, and the form scrolls clear of the fixed Save/Cancel bar.
- Subscription detail now labels inferred charge rows as projected instead of
  presenting them as imported charge history.
- Marking a subscription cancelled now asks for confirmation before clearing
  renewal reminders and synced calendar events.
- The detail back link now says "Back" because detail can be opened from Home,
  Calendar, Insights, or Subscriptions.

### Visual QA support

Debug builds now support `TALLY_IN_MEMORY_STORE=1` plus `-PreviewScreen` routes
for Home, Subscriptions, Insights, Calendar, Transactions, Imports, Settings,
Add/update, and manual create. This allows safe app-window screenshots without
opening the user's real finance library.

### Settings visual cleanup

The editorial divider no longer renders as stray coral dots in light mode; it is
a quiet full-width hairline.

## Remaining P1 work

### 1. Profile a real large ledger

Source inspection found and fixed obvious hot paths, but the app still needs an
Instruments pass with representative data before claiming performance is
finished. Test flows: launch, Home, Subscriptions, Calendar, Transactions search,
merchant drilldown, subscription detail, import, refresh analysis, and Copilot.

The July 12 synthetic regression coverage now exercises transaction paging at
250 rows. The 5,000- and 25,000-row timing fixtures below remain necessary for
stable performance budgets rather than correctness-only coverage.

### 2. Move detection rebuild work off the main actor

Detection still fetches all transactions and runs a full rebuild on the main
actor. The next architectural performance pass should make detection
incremental where possible and move non-UI orchestration off the main actor.

### 3. Reduce Copilot's broad data pulls

Copilot still has wide library access for answer generation and cache keys.
Keep deterministic grounded answers, but add a narrower retrieval layer before
feeding large histories into response generation.

### 4. Add performance fixtures

Add repeatable local fixtures for:

- 500 transactions / 20 subscriptions.
- 5,000 transactions / 80 subscriptions.
- 25,000 transactions / 200 subscriptions.

Use them for timing detection rebuilds, Dashboard snapshot creation,
subscription-list snapshot creation, and transaction search.

## Remaining P2 work

### 5. Real-device and iCloud validation

Validate iPhone, iPad, and Mac sync behavior with private test data only.
Exercise import, edits, review decisions, calendar sync settings, and conflict
behavior.

### 6. AI call budgeting

Add visible counters or signposts around merchant classification, recurring
cluster evaluation, single-charge evaluation, evidence contribution, and Copilot
generation. Use those counts to set per-run caps.

### 7. Brand asset runtime check

The brand asset catalog is large. Confirm with Instruments whether asset lookup
or image decoding contributes to launch or list-scroll cost before pruning or
lazy-loading assets.

Lookup and existence checks are now cached, but the compiled asset catalog is
still about 10.8 MB and must be measured before pruning.

### 8. Lazy-load the optional llama runtime

The macOS executable currently links the bundled 9.5 MB `llama.framework`
eagerly. Introduce and verify a dynamic C-runtime boundary so non-Gemma launches
do not pay that dyld cost while preserving local inference and clear missing-
runtime errors.

### 9. Realistic live flow QA

An in-memory empty-library screen walk has been completed safely. Still run a
manual screen walk with a realistic private test library:

- Import statement.
- Review suggestions using all four review actions.
- Edit a suggested subscription.
- Search transactions.
- Open merchant history.
- Open subscription detail.
- Switch calendar months.
- Ask Copilot about a subscription.

Capture only the app window if screenshots are needed.
