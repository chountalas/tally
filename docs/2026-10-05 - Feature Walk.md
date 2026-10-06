# Feature Walk: Tally

- **Date:** 2026-10-05
- **Repo:** Tally @ codex/tally-feature-cleanup (f2280d6; verified code revision)
- **Run environment:** macOS background hosted-app tests and hardened arm64 Release build. Native UI/OS dispatch NOT RUN under the requested background-only scope.
- **Ledger:** 92 protected coverage rows: 0 LIVE-WORKING, 0 LIVE-BROKEN, 1 BUILT-NOT-LIVE, 0 STUB, 91 UNVERIFIED.
- **Fixed this run:** 1 packaged URL registration defect.
- **Sources counted:** 7 routes, 74 buttons, 8 documented configuration controls, 12 integration categories, 4 macOS entitlement keys/0 iOS keys, 8 background trigger groups/0 external polling jobs, and 7 recent code commits. Detailed declaration counts appear below.

92 protected coverage rows: **91 UNVERIFIED end-user paths and 1 BUILT-NOT-LIVE implementation**. Background service verification passed. Native UI, OS dispatch and authenticated integrations were not exercised. A passing service check does not establish that its corresponding screen, dialog or permission flow works.

## Verification results

| Verification stage | Result |
|---|---|
| Baseline | Shell validation, XcodeGen, SwiftLint, 193 XCTest cases with 1 existing opt-in diagnostics skip, 84 Swift Testing cases, and hardened arm64 Release build passed. |
| Unused cleanup | Same complete verification sequence passed. |
| Shared cancellation/removal and model validation cleanup | Same complete verification sequence passed. |
| Packaged URL scheme registration | The hosted app test failed first on missing `CFBundleURLTypes`, then passed after the typed plist fix. Final full verification passed: 193 XCTest cases with 1 existing skip, 85 Swift Testing cases, and hardened arm64 Release build. Direct Debug/Release artifact checks confirmed the `tally` scheme, unchanged version 0.1.5/build 6 and existing metadata, and no plist copied as a resource. Actual OS dispatch remains UNVERIFIED. |

Tests cover real CSV/OFX import services and in-memory SwiftData persistence, multi-year plan separation, duplicate imports, calendar prediction, lifecycle observation, review learning, reset/export behavior and provider fallbacks. Notification tests use an injected notification center; calendar tests cover helpers and injected cleanup behavior. Actual system delivery, EventKit writes, persistent-library migration, CloudKit account sync and UI presentation remain UNVERIFIED.

Repeat the established verification commands from the repository root:

```sh
bash -n scripts/*.sh
xcodegen generate
swiftlint lint --config .swiftlint.yml Tally TallyTests --quiet
TEST_RUNNER_TALLY_IN_MEMORY_STORE=1 xcodebuild test -project Tally.xcodeproj -scheme Tally -destination 'platform=macOS' -derivedDataPath .build/derived
xcodebuild build -project Tally.xcodeproj -scheme Tally -configuration Release -destination 'generic/platform=macOS' -derivedDataPath .build/derived-release ARCHS=arm64 ONLY_ACTIVE_ARCH=YES ENABLE_HARDENED_RUNTIME=YES CODE_SIGNING_ALLOWED=NO
```

Test execution uses the existing debug in-memory store configuration. The complete result covers both test-framework summaries and the Release build. The optional diagnostics skip is preserved rather than treated as passing coverage.

## Protected feature ledger

Rows cover both product surfaces and the underlying services needed to preserve behavior. They are verification units, not a count of independent product features. Sources and existing checks are repository-relative.

| ID | Behavior or surface | State | Source | Reachability and gate | Service evidence | Fix |
|---|---|---|---|---|---|
| F001 | Cold start and local persistence | UNVERIFIED | Tally/App/ModelContainerFactory.swift:18 | Always; shared persistent SwiftData with automatic CloudKit then local fallback | TallyTests/AppIntentSubscriptionStoreTests.swift | — |
| F002 | Startup recovery and schema protection | UNVERIFIED | Tally/App/ModelContainerFactory.swift:18 | Always; shared persistent SwiftData with automatic CloudKit then local fallback | TallyTests/AppIntentSubscriptionStoreTests.swift | — |
| F003 | Home totals and spend chart | UNVERIFIED | Tally/Features/Dashboard/DashboardView.swift:4 | Home route; data-derived linked transaction totals | TallyTests/AuditEngineTests.swift | — |
| F004 | Upcoming renewal cards | UNVERIFIED | Tally/Features/Dashboard/DashboardView.swift:4 | Home route; data-derived linked transaction totals | TallyTests/AuditEngineTests.swift | — |
| F005 | Suggested subscription review queue | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionsView.swift:7 | Subscriptions route; chips conditionally include Review | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F006 | Subscription list filters (no search input) | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionsView.swift:7 | Subscriptions route; chips conditionally include Review | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F007 | Subscription filtering and counts | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionsView.swift:7 | Subscriptions route; chips conditionally include Review | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F008 | Subscription computed renewal/confidence ordering (no sort chooser) | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionsView.swift:7 | Subscriptions route; chips conditionally include Review | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F009 | Tidy up review queue | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionsView.swift:7 | Subscriptions route; chips conditionally include Review | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F010 | Subscription detail and back navigation | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F011 | Complete charge history disclosure | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F012 | Price change warning | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F013 | Manual add subscription | UNVERIFIED | Tally/Features/Dashboard/DashboardAddSubscriptionSheet.swift:4 | Add by hand or Edit details; Name/Price/Currency/Cadence/Status/Category/Date/Reminder/Payment/Website/Notes/Replacement | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F014 | Edit subscription details | UNVERIFIED | Tally/Features/Dashboard/DashboardAddSubscriptionSheet.swift:4 | Add by hand or Edit details; Name/Price/Currency/Cadence/Status/Category/Date/Reminder/Payment/Website/Notes/Replacement | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F015 | Suggest manual details with AI | UNVERIFIED | Tally/Features/Dashboard/DashboardAddSubscriptionSheet.swift:4 | Add by hand or Edit details; Name/Price/Currency/Cadence/Status/Category/Date/Reminder/Payment/Website/Notes/Replacement | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F016 | Keep suggested subscription | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F017 | Not a subscription learning | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F018 | Not mine exclusion | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F019 | Mark cancelled | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F020 | Remove subscription | UNVERIFIED | Tally/Features/Subscriptions/SubscriptionDetailView.swift:12 | Row/calendar/insight/renewal selection; status gates action choices | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift | — |
| F021 | Renewal reminder | UNVERIFIED | Tally/Services/Notifications/RenewalNotificationService.swift:36 | Explicit active detail reminder; OS authorization required | TallyTests/RenewalNotificationServiceTests.swift uses injected center, not actual OS delivery | — |
| F022 | Calendar month navigation | UNVERIFIED | Tally/Features/Calendar/CalendarView.swift:21 | Calendar route; date/month state and agenda | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/AuditEngineTests.swift | — |
| F023 | Calendar renewal agenda | UNVERIFIED | Tally/Features/Calendar/CalendarView.swift:21 | Calendar route; date/month state and agenda | TallyTests/UnifiedSubscriptionLibraryTests.swift; TallyTests/AuditEngineTests.swift | — |
| F024 | Insights overlap and price changes | UNVERIFIED | Tally/Features/Insights/InsightsView.swift:6 | Insights route; overlap/price/category/annual data gates | TallyTests/AuditEngineTests.swift | — |
| F025 | Insights detail links and category/annual spend summaries | UNVERIFIED | Tally/Features/Insights/InsightsView.swift:6 | Insights route; overlap/price/category/annual data gates | TallyTests/AuditEngineTests.swift | — |
| F026 | Transactions list and paging | UNVERIFIED | Tally/Features/Transactions/TransactionsView.swift:5 | Gear Transactions on Mac, Settings utility route on iOS; first 100 rows, 100 more, 180ms search debounce | TallyTests/TransactionPageLoaderTests.swift | — |
| F027 | Transaction merchant/category/memo text search (no separate filters) | UNVERIFIED | Tally/Features/Transactions/TransactionsView.swift:5 | Gear Transactions on Mac, Settings utility route on iOS; first 100 rows, 100 more, 180ms search debounce | TallyTests/TransactionPageLoaderTests.swift | — |
| F028 | Transactions sample data | UNVERIFIED | Tally/Features/Transactions/TransactionsView.swift:5 | Gear Transactions on Mac, Settings utility route on iOS; first 100 rows, 100 more, 180ms search debounce | TallyTests/TransactionPageLoaderTests.swift | — |
| F029 | CSV import file selection | UNVERIFIED | Tally/App/AppModel.swift:377 | Selected CSV/XLS/XLSX/OFX/QFX; 50MiB cap; background parse | TallyTests/CSVTransactionImporterTests.swift; TallyTests/OFXImportWiringTests.swift | — |
| F030 | XLS import | UNVERIFIED | Tally/App/AppModel.swift:377 | Selected CSV/XLS/XLSX/OFX/QFX; 50MiB cap; background parse | TallyTests/CSVTransactionImporterTests.swift; TallyTests/OFXImportWiringTests.swift | — |
| F031 | XLSX import | UNVERIFIED | Tally/App/AppModel.swift:377 | Selected CSV/XLS/XLSX/OFX/QFX; 50MiB cap; background parse | TallyTests/CSVTransactionImporterTests.swift; TallyTests/OFXImportWiringTests.swift | — |
| F032 | OFX/QFX import | UNVERIFIED | Tally/App/AppModel.swift:377 | Selected CSV/XLS/XLSX/OFX/QFX; 50MiB cap; background parse | TallyTests/CSVTransactionImporterTests.swift; TallyTests/OFXImportWiringTests.swift | — |
| F033 | Column mapping and preview | UNVERIFIED | Tally/Features/Transactions/ImportReviewSheet.swift:4 | Tabular draft; date/amount/merchant preview gates; optional category/account/currency/sign | TallyTests/CSVTransactionImporterTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F034 | Save column template | UNVERIFIED | Tally/Features/Transactions/ImportReviewSheet.swift:4 | Tabular draft; date/amount/merchant preview gates; optional category/account/currency/sign | TallyTests/CSVTransactionImporterTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F035 | Commit import and duplicate handling | UNVERIFIED | Tally/App/AppModel.swift:377 | Selected CSV/XLS/XLSX/OFX/QFX; 50MiB cap; background parse | TallyTests/CSVTransactionImporterTests.swift; TallyTests/OFXImportWiringTests.swift | — |
| F036 | Import history | UNVERIFIED | Tally/Features/Imports/ImportsView.swift:4 | Gear Import history; scoped review button when import has review count | TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F037 | Multi-year plan separation | UNVERIFIED | Tally/Services/Detection/SubscriptionDetectionService.swift:6 | Import/re-scan debit histories; account/currency/descriptor/calendar identity | TallyTests/SubscriptionDiscoveryImportTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift; TallyTests/SubscriptionEvidenceEngineTests.swift | — |
| F038 | Subscription renewal prediction | UNVERIFIED | Tally/Services/Detection/SubscriptionDetectionService.swift:6 | Import/re-scan debit histories; account/currency/descriptor/calendar identity | TallyTests/SubscriptionDiscoveryImportTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift; TallyTests/SubscriptionEvidenceEngineTests.swift | — |
| F039 | Cancellation inference with account coverage | UNVERIFIED | Tally/Services/Detection/SubscriptionDetectionService.swift:6 | Import/re-scan debit histories; account/currency/descriptor/calendar identity | TallyTests/SubscriptionDiscoveryImportTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift; TallyTests/SubscriptionEvidenceEngineTests.swift | — |
| F040 | Retain reviews across reimports | UNVERIFIED | Tally/Services/Detection/SubscriptionDetectionService.swift:6 | Import/re-scan debit histories; account/currency/descriptor/calendar identity | TallyTests/SubscriptionDiscoveryImportTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift; TallyTests/SubscriptionEvidenceEngineTests.swift | — |
| F041 | Processor and ambiguous merchant review | UNVERIFIED | Tally/Services/Detection/SubscriptionDetectionService.swift:6 | Import/re-scan debit histories; account/currency/descriptor/calendar identity | TallyTests/SubscriptionDiscoveryImportTests.swift; TallyTests/MultiYearSubscriptionImportTests.swift; TallyTests/SubscriptionEvidenceEngineTests.swift | — |
| F042 | Refresh subscription analysis | UNVERIFIED | Tally/App/AppModel+DataMaintenance.swift:32 | Add/update chooser or Settings re-scan | TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F043 | Copilot answer questions | UNVERIFIED | Tally/Features/Intelligence/SubscriptionCopilotSheet.swift:4 | Transactions/merchant Ask; custom/starter/follow-up questions and confirmed mutations | TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F044 | Copilot suggested questions | UNVERIFIED | Tally/Features/Intelligence/SubscriptionCopilotSheet.swift:4 | Transactions/merchant Ask; custom/starter/follow-up questions and confirmed mutations | TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F045 | Copilot proposed mutation and apply confirmation | UNVERIFIED | Tally/Features/Intelligence/SubscriptionCopilotSheet.swift:4 | Transactions/merchant Ask; custom/starter/follow-up questions and confirmed mutations | TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F046 | Appearance preferences | UNVERIFIED | Tally/Features/Settings/SettingsView.swift:140 | Settings; System/Light/Dark | TallyTests/ThemeTests.swift | — |
| F047 | AI provider choice and status | UNVERIFIED | Tally/Services/Intelligence/AIProviderSettings.swift:137 | Mac default Gemma; other platform Apple Intelligence; ready provider or deterministic fallback | TallyTests/AIProviderSelectionTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F048 | Gemma model download | UNVERIFIED | Tally/App/AppModel+AISettings.swift:76 | Settings explicit download/adopt/remove; 5GB pinned checksum model, macOS llama runtime | TallyTests/AIProviderSelectionTests.swift | — |
| F049 | Gemma model adoption | UNVERIFIED | Tally/App/AppModel+AISettings.swift:76 | Settings explicit download/adopt/remove; 5GB pinned checksum model, macOS llama runtime | TallyTests/AIProviderSelectionTests.swift | — |
| F050 | Gemma model removal | UNVERIFIED | Tally/App/AppModel+AISettings.swift:76 | Settings explicit download/adopt/remove; 5GB pinned checksum model, macOS llama runtime | TallyTests/AIProviderSelectionTests.swift | — |
| F051 | Apple Intelligence provider | UNVERIFIED | Tally/Services/Intelligence/AIProviderSettings.swift:137 | Mac default Gemma; other platform Apple Intelligence; ready provider or deterministic fallback | TallyTests/AIProviderSelectionTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F052 | Heuristic fallback with unavailable AI | UNVERIFIED | Tally/Services/Intelligence/AIProviderSettings.swift:137 | Mac default Gemma; other platform Apple Intelligence; ready provider or deterministic fallback | TallyTests/AIProviderSelectionTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F053 | Calendar sync | UNVERIFIED | Tally/Services/Calendar/RenewalCalendarService.swift:14 | Explicit Settings sync/removal; full EventKit access and entitlements required | TallyTests/UnifiedSubscriptionLibraryTests.swift tests date helpers/cleanup injection only | — |
| F054 | Remove synced calendar events | UNVERIFIED | Tally/Services/Calendar/RenewalCalendarService.swift:14 | Explicit Settings sync/removal; full EventKit access and entitlements required | TallyTests/UnifiedSubscriptionLibraryTests.swift tests date helpers/cleanup injection only | — |
| F055 | JSON export | UNVERIFIED | Tally/Services/Exporting/AppDataExporter.swift:39 | Settings JSON export followed by system save dialog | TallyTests/AppDataExporterTests.swift | — |
| F056 | Clear imported ledger | UNVERIFIED | Tally/Services/Library/LibraryResetService.swift:54 | Transactions Clear or Settings Delete, confirmation required | TallyTests/LibraryResetServiceTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F057 | Clear all library data | UNVERIFIED | Tally/Services/Library/LibraryResetService.swift:54 | Transactions Clear or Settings Delete, confirmation required | TallyTests/LibraryResetServiceTests.swift; TallyTests/CSVTransactionImporterTests+AppModel.swift | — |
| F058 | Deep links | UNVERIFIED | Tally/App/AppModel+Actions.swift:227 | Registered tally://subscription/<UUID> or tally://tab/<rawValue> | TallyTests/AppRegistrationTests.swift hosted-bundle check and direct Debug/Release plist assertions; OS dispatch untested | Typed URL scheme metadata restored; external dispatch remains UNVERIFIED |
| F059 | App Shortcuts and intents | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:235 | 4 published AppShortcuts; 3 entity query types | TallyTests/AppIntentSubscriptionStoreTests.swift store-retry only | URL registration dependency repaired; Shortcuts invocation remains UNVERIFIED |
| F060 | Spotlight indexing and navigation | UNVERIFIED | Tally/Services/Intelligence/SubscriptionSpotlightIndexer.swift:7 | Delayed root/revision index; actual indexing disabled under XCTest | TallyTests/SubscriptionIntelligenceServiceTests.swift index model helpers only | — |
| F061 | Optional iCloud sync | UNVERIFIED | Tally/App/ModelContainerFactory.swift:64 | Requires local user-owned team/container/entitlements; public CloudKit entitlement is absent | No actual CloudKit account sync tests | — |
| F062 | Background AI timeout and cancellation | UNVERIFIED | Tally/Services/Intelligence/SubscriptionIntelligenceService.swift:207 | Provider/classification task cancellation and timeouts; no complete import Cancel UI | TallyTests/AIProviderSelectionTests.swift; TallyTests/CSVTransactionImporterTests.swift | — |
| F063 | Debug preview and memory-store controls | UNVERIFIED | Tally/Shared/TallyPreview.swift:14 | DEBUG only: -PreviewScreen <screen>, -PreviewAppearance light/dark, and TALLY_IN_MEMORY_STORE=1 | TallyTests/ThemeTests.swift; model-container source only | — |
| F064 | Route: Home | UNVERIFIED | Tally/App/RootTabView.swift:382 | Primary route | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F065 | Route: Subscriptions | UNVERIFIED | Tally/App/RootTabView.swift:383 | Primary route | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F066 | Route: Insights | UNVERIFIED | Tally/App/RootTabView.swift:384 | Primary route | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F067 | Route: Calendar | UNVERIFIED | Tally/App/RootTabView.swift:385 | Primary route | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F068 | Route: Transactions | UNVERIFIED | Tally/App/RootTabView.swift:386 | Mac gear menu, iOS Settings/deep-link utility route | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F069 | Route: Import history | UNVERIFIED | Tally/App/RootTabView.swift:387 | Gear Import history on macOS; Settings or utility route on iOS | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F070 | Route: Settings | UNVERIFIED | Tally/App/RootTabView.swift:388 | Gear Settings on macOS; Settings tab on iOS | TallyTests/CSVTransactionImporterTests+AppModel.swift navigation model only | — |
| F071 | Add/update choice: Drop in a statement | UNVERIFIED | Tally/Features/Dashboard/AddUpdateSheet.swift:85 | Visible chooser button; Maybe later dismisses chooser | TallyTests/CSVTransactionImporterTests+AppModel.swift; TallyTests/UnifiedSubscriptionLibraryTests.swift | — |
| F072 | Add/update choice: Import a newer statement | UNVERIFIED | Tally/Features/Dashboard/AddUpdateSheet.swift:89 | Visible chooser button; Maybe later dismisses chooser | TallyTests/CSVTransactionImporterTests+AppModel.swift; TallyTests/UnifiedSubscriptionLibraryTests.swift | — |
| F073 | Add/update choice: Add one by hand | UNVERIFIED | Tally/Features/Dashboard/AddUpdateSheet.swift:87 | Visible chooser button; Maybe later dismisses chooser | TallyTests/CSVTransactionImporterTests+AppModel.swift; TallyTests/UnifiedSubscriptionLibraryTests.swift | — |
| F074 | Add/update choice: Re-scan my transactions | UNVERIFIED | Tally/Features/Dashboard/AddUpdateSheet.swift:91 | Visible chooser button; Maybe later dismisses chooser | TallyTests/CSVTransactionImporterTests+AppModel.swift; TallyTests/UnifiedSubscriptionLibraryTests.swift | — |
| F075 | Intent: Open Subscription | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:174 | Published AppShortcut; opens registered tally URL | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | URL registration dependency repaired; Shortcuts invocation remains UNVERIFIED |
| F076 | Intent: Upcoming Renewals with Days | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:189 | Published AppShortcut; opens registered tally URL | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | URL registration dependency repaired; Shortcuts invocation remains UNVERIFIED |
| F077 | Intent: Subscription Audit | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:211 | Published AppShortcut; opens registered tally URL | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | URL registration dependency repaired; Shortcuts invocation remains UNVERIFIED |
| F078 | Intent: Savings Opportunities | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:223 | Published AppShortcut; opens registered tally URL | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | URL registration dependency repaired; Shortcuts invocation remains UNVERIFIED |
| F079 | Entity query: SubscriptionEntityQuery | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:55 | AppIntents entity lookup/suggestions; shared persistent store | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | — |
| F080 | Entity query: RenewalEntityQuery | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:94 | AppIntents entity lookup/suggestions; shared persistent store | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | — |
| F081 | Entity query: AuditRecommendationEntityQuery | UNVERIFIED | Tally/App/SubscriptionAppIntents.swift:147 | AppIntents entity lookup/suggestions; shared persistent store | TallyTests/AppIntentSubscriptionStoreTests.swift tests store only | — |
| F082 | SimpleFIN JSON adapter (no app or connector wiring) | BUILT-NOT-LIVE | Tally/Services/Importing/BankFeedTransactionAdapters.swift:79 | No live caller; no JSON ImportFileFormat | TallyTests/BankFeedTransactionAdapterTests.swift 4 SimpleFIN tests passed in current full baseline | — |
| F083 | Transaction merchant drill-down and Ask | UNVERIFIED | Tally/Features/Transactions/TransactionsView.swift:286 | Select transaction row; opens merchant-scoped query | TallyTests/TransactionPageLoaderTests.swift; TallyTests/SubscriptionIntelligenceServiceTests.swift | — |
| F084 | Search/select/clear service identity | UNVERIFIED | Tally/Shared/ServiceLogoBadge.swift:371 | Inside add/edit form | TallyTests/ServiceLogoResolverTests.swift; TallyTests/ServiceLogoDatabaseTests.swift | — |
| F085 | Import-scoped Review items | UNVERIFIED | Tally/Features/Imports/ImportsView.swift:83 | Import needsReviewSubscriptionCount > 0 | TallyTests/CSVTransactionImporterTests+AppModel.swift:testOpenSubscriptionLibraryCanScopeNavigationToImportRecord | — |
| F086 | UI alerts/dialog acknowledgements and cancellation | UNVERIFIED | Tally/App/RootTabView.swift:36 | 12 alert hosts, 3 confirmation dialog hosts; source appendix enumerates every host | Model-level failure handling coverage; no dialog presentation test | — |
| F087 | Background preparation invalidation | UNVERIFIED | Tally/App/AppModel.swift:414 | Selected file; detached parsing with token invalidation | TallyTests/CSVTransactionImporterTests+AppModel.swift:testUnsupportedImportClearsPreviousPreparationState | — |
| F088 | Provider refresh on scene activation | UNVERIFIED | Tally/App/TallyApp.swift:18 | Active scene phase | TallyTests/AIProviderSelectionTests.swift model-level only | — |
| F089 | Spotlight delayed coalesced reindex | UNVERIFIED | Tally/App/AppModel+Actions.swift:148 | Root 2s delay and revisions; skips actual index in XCTest | TallyTests/SubscriptionIntelligenceServiceTests.swift helpers only | — |
| F090 | iOS utility route/detail/import sheet presentation | UNVERIFIED | Tally/App/RootTabView.swift:163 | Non-macOS compilation only; hidden utilities rendered in cover | No iOS runtime suite | — |
| F091 | Hidden AI generation-disable preference | UNVERIFIED | Tally/Services/Intelligence/AIProviderSettings.swift:53 | UserDefaults intelligence_generation_disabled; default false; no UI toggle | TallyTests/AIProviderSelectionTests.swift uses isolated defaults | — |
| F092 | Public sandbox/network/selected-file/calendar entitlements | UNVERIFIED | Tally/Resources/Tally.macOS.entitlements:5 | Mac target; iOS entitlements empty; no CloudKit default capability | Parent hardened arm64 Release build passed; no permission exercise | — |

## Source inventory

The following counts were rechecked after cleanup. They count source declarations; generic component definitions and multiple modal hosts can serve the same behavior.

| Declaration | Count |
|---|---|
| button_definitions | 74 |
| sheet_hosts | 5 |
| full_screen_cover_hosts | 1 |
| file_importer_hosts | 2 |
| file_exporter_hosts | 1 |
| alert_hosts | 12 |
| confirmation_dialog_hosts | 3 |
| swiftui_task_modifiers | 8 |
| on_change_modifiers | 4 |
| navigation_links | 1 |
| pickers | 8 |
| user_defaults_feature_keys | 2 |
| app_storage_properties | 2 |
| app_intents | 4 |
| app_entity_queries | 3 |
| app_shortcut_declarations | 4 |
| swift_source_files | 91 |
| feature_swift_files | 15 |
| routes | 7 |
| primary_routes | 4 |
| add_update_choices | 4 |
| supported_import_formats | 5 |
| protected_coverage_rows | 92 |

Repeatable inventory commands:

```sh
rg --files Tally --glob '*.swift' | wc -l
rg --files Tally/Features --glob '*.swift' | wc -l
rg -n '\bButton(?:\s*\(|\s*\{)' Tally --glob '*.swift' | wc -l
rg -n '\.sheet\(' Tally --glob '*.swift' | wc -l
rg -n '\.fullScreenCover\(' Tally --glob '*.swift' | wc -l
rg -n '\.fileImporter\(' Tally --glob '*.swift' | wc -l
rg -n '\.fileExporter\(' Tally --glob '*.swift' | wc -l
rg -n '\.alert\(' Tally --glob '*.swift' | wc -l
rg -n '\.confirmationDialog\(' Tally --glob '*.swift' | wc -l
rg -n '\.task\b' Tally --glob '*.swift' | wc -l
rg -n '\.onChange\b' Tally --glob '*.swift' | wc -l
rg -n '\bNavigationLink(?:\s*\(|\s*\{)' Tally --glob '*.swift' | wc -l
rg -n '\bPicker\(' Tally --glob '*.swift' | wc -l
rg -n 'static let .*DefaultsKey' Tally --glob '*.swift' | wc -l
rg -n '@AppStorage\(' Tally --glob '*.swift' | wc -l
rg -n '^struct .*: AppIntent' Tally --glob '*.swift' | wc -l
rg -n '^struct .*: EntityQuery' Tally --glob '*.swift' | wc -l
rg -n '^\s*AppShortcut\(' Tally --glob '*.swift' | wc -l
rg -n '^    case (dashboard|subscriptions|audit|calendar|transactions|imports|settings)$' Tally/App/RootTabView.swift
rg -n 'SheetChoice\(kind:' Tally/Features/Dashboard/AddUpdateSheet.swift
```

## Flags, defaults and configuration

| Control | Default and gate | Source |
|---|---|---|
| Appearance | System; selectable Light/Dark persisted as `appearanceMode`. | `Tally/App/TallyApp.swift`, `Tally/Features/Settings/SettingsView.swift` |
| Intelligence provider | Gemma on macOS, Apple Intelligence on other platforms; selection persisted as `intelligence_provider_kind`. | `Tally/Services/Intelligence/AIProviderSettings.swift` |
| Hidden generation disable | `intelligence_generation_disabled` defaults false; no settings toggle exists. | `Tally/Services/Intelligence/AIProviderSettings.swift` |
| Automatic recurring/single-charge AI evaluation | Enabled only when `intelligence.generator` exists; deterministic detection remains available without a generator. | `Tally/Services/Detection/SubscriptionDetectionService+Signals.swift` |
| Debug memory store | `TALLY_IN_MEMORY_STORE=1`; DEBUG only. | `Tally/App/ModelContainerFactory.swift` |
| Debug preview | `-PreviewScreen <screen>` and `-PreviewAppearance light/dark`; inert in Release. | `Tally/Shared/TallyPreview.swift` |
| Spotlight test gate | Actual indexing is skipped when `XCTestConfigurationFilePath` exists. | `Tally/App/AppModel+Actions.swift` |
| Signing/iCloud overrides | Public local defaults in `Config/Tally.xcconfig`; user-owned ignored local override and optional iCloud entitlement examples. | `Config/Tally.xcconfig`, `Tally/Resources/*.iCloud.*.entitlements.example` |

## Integrations and entitlements

| Capability | Implementation and verification boundary |
|---|---|
| CSV/XLS/XLSX | File-selection path and import services exist; first worksheet for Excel formats; no sheet selector. Service fixtures pass; native file selection remains UNVERIFIED. |
| OFX/QFX | Wired from `AppModel.prepareImport` to account-aware source adapter; service import fixtures pass. |
| SimpleFIN | Complete JSON adapter with four passing adapter cases, but no app caller, connection UI, JSON import format or polling. **BUILT-NOT-LIVE**; implementation preserved. |
| Gemma | macOS bundled llama runtime plus compatible managed model; explicit adoption/download/removal. Managed model download is checksum-pinned. Real model/runtime availability and user setup were not changed; general inference quality remains UNVERIFIED. |
| Apple Intelligence | System model gated by eligible device, enabled Apple Intelligence and available assets; deterministic/provider fallback retained. System model execution remains UNVERIFIED. |
| Calendar | Full EventKit access required for explicit renewal sync/removal. macOS public calendar entitlement and usage-description settings are present. Real permission and event writes remain UNVERIFIED. |
| Notifications | Explicit reminder action, saved lead time and stale request cleanup. Injected-center tests pass; actual authorization and delivery remain UNVERIFIED. |
| Spotlight | Delayed/coalesced indexing and subscription/renewal identifiers; actual index writes and clicked-result continuation remain UNVERIFIED. |
| App Shortcuts | Four published intents and three entity-query types. Actual Shortcuts invocation and OS dispatch remain UNVERIFIED. |
| Deep links | `tally://subscription/<UUID>` and all seven `tally://tab/<rawValue>` routes. Typed scheme registration is verified in Debug and Release; OS dispatch remains UNVERIFIED. No native URL was opened. |
| CloudKit | Compatible model configuration and optional user-owned entitlement examples; public entitlements do not enable iCloud. Actual configured-account sync remains UNVERIFIED. Local/in-memory stores are exercised separately. |
| Plaid, receipts and email export | Source enum labels only; no adapter, parser, OAuth, live connection, route or tests. These are **not built integrations**. |

Public macOS entitlements enable App Sandbox, selected-file read/write, client networking and calendar access. Public iOS entitlements are empty. No mail account, bank account, credential or external service was accessed for verification.

## Background work

| Work | Trigger and gate |
|---|---|
| Import preparation | User-selected file; detached parser; token prevents a superseded preparation from applying. |
| Import materialization/classification/detection | Committed mapping or bank-file import; service task cancellation and AI fallback retained. |
| Re-scan | Explicit Add/update or Settings action; reuses stored transactions. |
| Provider health | Scene activation and Settings provider/model actions. |
| Spotlight | Initial delayed root task and library revisions; coalesced/cancelled prior tasks; actual test indexing disabled. |
| Transaction search | 180ms debounce, reset page limit to 100; SwiftUI request task reloads page after revision or search. |
| Copilot/manual advisor | Explicit Ask, starter/follow-up or Suggest details actions. |
| Calendar/notification cleanup | Explicit deactivation/reset/sync, with recorded deferred calendar cleanup when access is unavailable. |

No authenticated email polling, bank polling or scheduled external connector job exists.

## Remaining verification gaps

- Every native screen, sheet, acknowledgement, confirmation and permission flow remains UNVERIFIED because this pass used background service checks.
- Persistent startup/recovery/migration, actual CloudKit account sync, real calendar writes, real notification delivery, Spotlight open and iOS utility-cover presentation need runtime evidence.
- Upcoming Renewals accepts a `Days` parameter, but source sends only the calendar tab URL. That ignored parameter is a runtime verification gap; it has not been classified as a confirmed live failure.
- Subscription lists have filter chips and fixed ordering, with no search input or sort chooser. Transactions has text search and paging, with no separate filter control. Insights links to details; it does not expose an Apply savings mutation.
- Same-account/same-price/same-date indistinguishable plans remain ambiguous without receipt/account evidence. A lack of observed charges can suggest ended billing; it cannot confirm cancellation with the provider.

## Cleanup preservation check

Source tracing after both cleanup commits found the protected routes, action gates, optional providers and SimpleFIN adapter still present. Removed symbols had no callers. Cancellation/removal still save local state before external cleanup, retain deferred cleanup when calendar access fails, and then update library revision and Spotlight scheduling. The consolidated model-validation catch logs and rethrows the same error. Full existing suites and Release validation passed after each changed cleanup stage; source tracing does not replace UI runtime verification.

## Recent commits

The seven most recent code commits inspected:

- `f2280d6 fix: declare Tally URL scheme in packaged app metadata`
- `b666b1e cleanup: share subscription deactivation and validation handling`
- `e6dbccd cleanup: remove unused helpers and fields verified by Periphery`
- `c12c35b Improve multi-year subscription discovery and lifecycle tracking`
- `c37e4a2 ci: defer hosted checks until review all-clear (#9)`
- `1573d73 chore: release Tally 0.1.5`
- `63fe373 Harden launch paths and guard regressions (#8)`

## Product decisions

SimpleFIN: keep the tested adapter internal for now? **Recommended: yes**, until a connection/import flow is deliberately designed. This is an optional product decision; no response is needed to complete the verified changes. Email/receipt/Plaid integration requires a separate implementation and account authorization design.


## Fix details

`f2280d6` moves the nested URL registration from an unsupported scalar build setting to `targets.Tally.info.properties`, producing `Config/Tally-Info.plist`; the generated project references it for both configurations. The failure-first `AppRegistrationTests` case reads the real hosted application bundle. Native URL opening and Launch Services registration were not performed.
