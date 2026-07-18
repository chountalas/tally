import Foundation
import Observation
import OSLog
import SwiftData

enum AddOrEditSheet: Identifiable, Hashable {
    case chooser
    case create
    case edit(UUID)

    var id: String {
        switch self {
        case .chooser: "chooser"
        case .create: "create"
        case let .edit(subscriptionID): "edit-\(subscriptionID.uuidString)"
        }
    }
}

struct LibraryRevision: Equatable, Hashable, Sendable {
    let generation: UInt64
    let updatedAt: Date

    static let initial = LibraryRevision(generation: 0, updatedAt: .distantPast)

    func advanced(at date: Date = .now) -> LibraryRevision {
        LibraryRevision(generation: generation &+ 1, updatedAt: date)
    }
}

struct AIProviderStateResolution {
    let gemmaModelStatus: GemmaModelStatusSnapshot
    let providerStatus: AIProviderStatusSnapshot
}

struct AIProviderStateResolver {
    let gemmaModelManager: GemmaModelManager

    func resolve(
        providerKind: AIProviderKind,
        isDownloading: Bool,
        errorMessage: String?
    ) -> AIProviderStateResolution {
        let gemmaStatus = gemmaModelManager.statusSnapshot(
            isDownloading: isDownloading,
            errorMessage: errorMessage
        )

        return AIProviderStateResolution(
            gemmaModelStatus: gemmaStatus,
            providerStatus: AIProviderRegistry.statusSnapshot(
                for: providerKind,
                gemmaModelManager: gemmaModelManager,
                gemmaStatusSnapshot: gemmaStatus
            )
        )
    }
}

struct DashboardMetricsSnapshot {
    let revision: LibraryRevision
    let referenceDay: Date
    let metrics: DashboardMetrics
}

struct DashboardContentSnapshot {
    let revision: LibraryRevision
    let referenceDay: Date
    let metrics: DashboardMetrics
    let reviewQueueTotalCount: Int
    let reviewQueueSubscriptions: [Subscription]
    let upcomingRenewals: [Subscription]
    let activePreviewSubscriptions: [Subscription]
    let reviewPreviews: [UUID: MerchantLearningPreview]
}

private let dashboardMetricsLogger = Logger(
    subsystem: "Tally",
    category: "DashboardMetrics"
)

@MainActor
final class DashboardMetricsProvider {
    private var cachedSnapshot: DashboardMetricsSnapshot?
    private var cachedContentSnapshot: DashboardContentSnapshot?
    private let referenceDateProvider: () -> Date

    init(referenceDateProvider: @escaping () -> Date = { Date() }) {
        self.referenceDateProvider = referenceDateProvider
    }

    func snapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision
    ) -> DashboardMetricsSnapshot {
        let referenceDate = referenceDateProvider()
        let referenceDay = Self.referenceDay(for: referenceDate)
        return snapshot(
            subscriptions: subscriptions,
            transactions: transactions,
            revision: revision,
            referenceDate: referenceDate,
            referenceDay: referenceDay
        )
    }

    private func snapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision,
        referenceDate: Date,
        referenceDay: Date
    ) -> DashboardMetricsSnapshot {
        if let cachedSnapshot,
           cachedSnapshot.revision == revision,
           cachedSnapshot.referenceDay == referenceDay {
            return cachedSnapshot
        }

        let startedAt = Date()
        let snapshot = DashboardMetricsSnapshot(
            revision: revision,
            referenceDay: referenceDay,
            metrics: DashboardMetrics(
                subscriptions: subscriptions,
                transactions: transactions,
                referenceDate: referenceDate
            )
        )
        cachedSnapshot = snapshot
        dashboardMetricsLogger.notice(
            """
            dashboard_metrics_snapshot subscriptions=\(subscriptions.count, privacy: .public) \
            transactions=\(transactions.count, privacy: .public) \
            generation=\(revision.generation, privacy: .public) \
            elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
            """
        )
        return snapshot
    }

    func contentSnapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision,
        previewBuilder: (Subscription, [NormalizedTransaction]) -> MerchantLearningPreview
    ) -> DashboardContentSnapshot {
        let referenceDate = referenceDateProvider()
        let referenceDay = Self.referenceDay(for: referenceDate)
        if let cachedContentSnapshot,
           cachedContentSnapshot.revision == revision,
           cachedContentSnapshot.referenceDay == referenceDay {
            return cachedContentSnapshot
        }

        let startedAt = Date()
        let metricsSnapshot = snapshot(
            subscriptions: subscriptions,
            transactions: transactions,
            revision: revision,
            referenceDate: referenceDate,
            referenceDay: referenceDay
        )
        let metrics = metricsSnapshot.metrics
        let activeSubscriptions = DashboardMetrics.currentActiveSubscriptions(
            from: subscriptions,
            referenceDate: referenceDate
        )
            .sorted {
                (DashboardMetrics.currentRenewalDate(for: $0, referenceDate: referenceDate) ?? .distantFuture)
                    < (DashboardMetrics.currentRenewalDate(for: $1, referenceDate: referenceDate) ?? .distantFuture)
            }
        let reviewQueueSubscriptions = Array(
            subscriptions
                .filter { $0.status == .needsReview }
                .sorted {
                    if $0.confidenceScore == $1.confidenceScore {
                        return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                    }
                    return $0.confidenceScore > $1.confidenceScore
                }
                .prefix(5)
        )
        let reviewQueueTotalCount = subscriptions.reduce(into: 0) { count, subscription in
            if subscription.libraryState == .suggested {
                count += 1
            }
        }
        let contentSnapshot = DashboardContentSnapshot(
            revision: revision,
            referenceDay: referenceDay,
            metrics: metrics,
            reviewQueueTotalCount: reviewQueueTotalCount,
            reviewQueueSubscriptions: reviewQueueSubscriptions,
            upcomingRenewals: Array(metrics.upcomingRenewals.prefix(6)),
            activePreviewSubscriptions: Array(activeSubscriptions.prefix(8)),
            reviewPreviews: Dictionary(
                uniqueKeysWithValues: reviewQueueSubscriptions.map { subscription in
                    (subscription.id, previewBuilder(subscription, transactions))
                }
            )
        )
        cachedContentSnapshot = contentSnapshot
        dashboardMetricsLogger.notice(
            """
            dashboard_content_snapshot review_queue=\(reviewQueueSubscriptions.count, privacy: .public) \
            active_preview=\(contentSnapshot.activePreviewSubscriptions.count, privacy: .public) \
            generation=\(revision.generation, privacy: .public) \
            elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
            """
        )
        return contentSnapshot
    }

    private static func referenceDay(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }
}

@MainActor
@Observable
final class AppModel {
    var selectedTab: SidebarTab = .dashboard
    /// Tally shell: subscription shown in the full-pane detail overlay (nil = list/tab).
    var tallySelectedSubscriptionID: UUID?
    /// Tally shell: list filter survives opening and closing full-pane detail.
    var selectedSubscriptionFilter: SubsFilter = .all
    /// Tally shell: the add / update flow sheet (chooser → create/edit). nil = closed.
    var addOrEditSheet: AddOrEditSheet?
    /// Tally shell: set true to ask the Transactions screen to open the file
    /// importer as soon as it appears (drives "Drop in a statement" / "Refresh").
    var pendingImportFilePicker = false
    var importDraft: TransactionImportDraft?
    var importErrorMessage: String?
    var infoMessage: String?
    var isPreparingImport = false
    var isLoadingSampleData = false
    var isRefreshingAnalysis = false
    var classificationStatusMessage: String?
    var startupMessage: String?
    var pendingSubscriptionNavigationID: UUID?
    var pendingSubscriptionLibraryState: SubscriptionLibraryState?
    var pendingSubscriptionLibraryImportRecordID: UUID?
    var navigationToken = UUID()
    var intelligenceProviderKind: AIProviderKind
    var intelligenceProviderStatus: AIProviderStatusSnapshot
    var gemmaModelStatus: GemmaModelStatusSnapshot
    var isDownloadingGemmaModel = false
    var gemmaDownloadProgress: Double?
    var gemmaDownloadStatusMessage: String?
    var gemmaSetupErrorMessage: String?
    var libraryRevision: LibraryRevision = .initial

    var currentImportRecord: ImportRecord?
    var importPreparationToken = UUID()
    @ObservationIgnored private let csvImporter: CSVTransactionImporter
    @ObservationIgnored private let xlsxImporter: XLSXTransactionImporter
    @ObservationIgnored private let xlsImporter: XLSBinaryTransactionImporter
    @ObservationIgnored let libraryResetService: LibraryResetService
    @ObservationIgnored let spotlightIndexer = SubscriptionSpotlightIndexer()
    @ObservationIgnored var spotlightReindexTask: Task<Void, Never>?
    @ObservationIgnored let aiProviderPreferences: AIProviderPreferences
    @ObservationIgnored let gemmaModelManager: GemmaModelManager
    @ObservationIgnored let aiProviderStateResolver: AIProviderStateResolver
    @ObservationIgnored let dashboardMetricsProvider: DashboardMetricsProvider
    @ObservationIgnored let calendarEventCleaner: ([Subscription], ModelContext) throws -> Void
    @ObservationIgnored let calendarEventCleanupFailureRecorder: ([String]) -> Void

    @ObservationIgnored
    private var backgroundAutomationIntelligence: SubscriptionIntelligenceService {
        SubscriptionIntelligenceService(
            usage: .backgroundAutomation,
            preferences: aiProviderPreferences,
            gemmaModelManager: gemmaModelManager
        )
    }

    @ObservationIgnored
    var detector: SubscriptionDetectionService {
        SubscriptionDetectionService(
            intelligence: backgroundAutomationIntelligence
        )
    }

    @ObservationIgnored
    var classifier: MerchantClassificationEngine {
        MerchantClassificationEngine(
            preferences: aiProviderPreferences,
            gemmaModelManager: gemmaModelManager,
            intelligence: backgroundAutomationIntelligence
        )
    }

    init(
        startupMessage: String? = nil,
        aiProviderPreferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        libraryResetService: LibraryResetService = LibraryResetService(),
        dashboardMetricsProvider: DashboardMetricsProvider? = nil,
        calendarEventCleaner: @escaping ([Subscription], ModelContext) throws -> Void = { subscriptions, context in
            try RenewalCalendarService().clearSyncedEvents(for: subscriptions, context: context)
        },
        calendarEventCleanupFailureRecorder: @escaping ([String]) -> Void = { identifiers in
            PendingCalendarEventCleanupStore.record(identifiers)
        },
        csvImporter: CSVTransactionImporter = CSVTransactionImporter(),
        xlsxImporter: XLSXTransactionImporter = XLSXTransactionImporter(),
        xlsImporter: XLSBinaryTransactionImporter = XLSBinaryTransactionImporter()
    ) {
        self.startupMessage = startupMessage
        self.aiProviderPreferences = aiProviderPreferences
        self.gemmaModelManager = gemmaModelManager
        self.libraryResetService = libraryResetService
        self.dashboardMetricsProvider = dashboardMetricsProvider ?? DashboardMetricsProvider()
        self.calendarEventCleaner = calendarEventCleaner
        self.calendarEventCleanupFailureRecorder = calendarEventCleanupFailureRecorder
        self.csvImporter = csvImporter
        self.xlsxImporter = xlsxImporter
        self.xlsImporter = xlsImporter
        aiProviderStateResolver = AIProviderStateResolver(
            gemmaModelManager: gemmaModelManager
        )

        let selectedProvider = aiProviderPreferences.selectedKind
        intelligenceProviderKind = selectedProvider
        let providerState = aiProviderStateResolver.resolve(
            providerKind: selectedProvider,
            isDownloading: false,
            errorMessage: nil
        )
        gemmaModelStatus = providerState.gemmaModelStatus
        intelligenceProviderStatus = providerState.providerStatus
    }

    func clearSyncedCalendarEventsIfNeeded(
        for subscriptions: [Subscription],
        in context: ModelContext
    ) throws {
        let syncedSubscriptions = subscriptions.filter { $0.calendarEventIdentifier != nil }
        guard syncedSubscriptions.isEmpty == false else { return }
        try calendarEventCleaner(syncedSubscriptions, context)
    }

    func dashboardMetricsSnapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision? = nil
    ) -> DashboardMetricsSnapshot {
        dashboardMetricsProvider.snapshot(
            subscriptions: subscriptions,
            transactions: transactions,
            revision: revision ?? libraryRevision
        )
    }

    func dashboardContentSnapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision? = nil
    ) -> DashboardContentSnapshot {
        let resolvedRevision = revision ?? libraryRevision
        return dashboardMetricsProvider.contentSnapshot(
            subscriptions: subscriptions,
            transactions: transactions,
            revision: resolvedRevision
        ) { [self] subscription, allTransactions in
            merchantLearningPreview(
                for: subscription,
                proposedDisplayName: subscription.displayName,
                applyAliasToFutureImports: false,
                isFalsePositive: false,
                transactions: allTransactions
            )
        }
    }

    func advanceLibraryRevision() {
        libraryRevision = libraryRevision.advanced()
    }

    func prepareImport(from url: URL, into context: ModelContext) {
        let importRecord = ImportRecord(
            fileName: url.lastPathComponent,
            sourceType: url.pathExtension.lowercased(),
            status: .parsing,
            mappingSignature: "pending"
        )
        context.insert(importRecord)
        currentImportRecord = importRecord
        importDraft = nil
        importErrorMessage = nil
        isPreparingImport = true

        let preparationToken = UUID()
        importPreparationToken = preparationToken
        try? context.save()

        if let source = bankFeedTransactionSource(for: url) {
            Task { [url, importRecordID = importRecord.id] in
                let outcome = await Task.detached(priority: .userInitiated) {
                    await BankFeedImportPreparationService.prepareDrafts(from: url, source: source)
                }.value

                guard preparationToken == self.importPreparationToken else {
                    return
                }

                await self.finishBankFeedImportPreparation(
                    outcome,
                    importRecordID: importRecordID,
                    source: source,
                    into: context
                )
            }
            return
        }

        Task { [url, importRecordID = importRecord.id] in
            let outcome = await Task.detached(priority: .userInitiated) {
                ImportPreparationService.prepareDraft(from: url)
            }.value

            guard preparationToken == self.importPreparationToken else {
                return
            }

            self.finishImportPreparation(outcome, importRecordID: importRecordID, into: context)
        }
    }

    func commitImport(using mapping: ColumnMappingConfig, into context: ModelContext) async {
        guard let importDraft else {
            return
        }

        classificationStatusMessage = nil

        do {
            let importRecord = prepareImportRecord(
                for: importDraft,
                mapping: mapping,
                context: context
            )
            importRecord.status = .classifying
            importRecord.mappingSignature = mapping.signature
            importRecord.errorMessage = nil

            let materialized = try csvImporter.materializeSeeds(from: importDraft, mapping: mapping)
            let seeds = materialized.seeds
            let classificationLoadResult = try await loadClassifications(for: seeds, context: context)
            importRecord.status = .analyzed
            importRecord.importedTransactionCount = seeds.count

            let upsertSummary = try await upsertImportedTransactions(
                seeds,
                classifications: classificationLoadResult.results,
                importRecordID: importRecord.id,
                into: context
            )
            importRecord.importedTransactionCount = upsertSummary.reconciledCount
            try upsertTemplate(from: mapping, context: context)
            let detectionReport = try await saveChangesAndRefreshSubscriptions(in: context)
            applyImportSummary(
                from: detectionReport,
                to: importRecord
            )
            try context.save()
            completeImportSuccess(
                importFileName: importRecord.fileName,
                upsertSummary: upsertSummary,
                skippedRowCount: materialized.skippedRowCount,
                classificationLoadResult: classificationLoadResult,
                importSummary: detectionReport.summary(for: importRecord.id)
            )
        } catch {
            handleCommitImportFailure(
                error,
                importDraft: importDraft,
                mapping: mapping,
                context: context
            )
        }
    }

    func dismissImport(into context: ModelContext) {
        importPreparationToken = UUID()
        isPreparingImport = false
        importDraft = nil

        if let currentImportRecord, shouldDiscardImportRecord(currentImportRecord) {
            context.delete(currentImportRecord)
            try? context.save()
        }

        currentImportRecord = nil
    }

}

private enum BankFeedImportPreparationService {
    static func prepareDrafts(
        from url: URL,
        source: TransactionSource
    ) async -> BankFeedImportPreparationOutcome {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try validateImportFileSize(at: url)
            let data = try Data(contentsOf: url)
            guard let text = decodeImportText(from: data) else {
                throw BankFeedImportPreparationError.unreadableContent
            }

            let drafts = try await OFXTransactionSourceAdapter(
                text: text,
                source: source
            ).prepareTransactions()
            guard drafts.isEmpty == false else {
                throw BankFeedImportPreparationError.noUsableTransactions
            }
            return .success(drafts)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func validateImportFileSize(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > ImportPreparationService.maxImportFileSizeBytes {
            throw BankFeedImportPreparationError.fileTooLarge(
                actualBytes: fileSize,
                maxBytes: ImportPreparationService.maxImportFileSizeBytes
            )
        }
    }

    private static func decodeImportText(from data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .windowsCP1252,
            .macOSRoman,
            .isoLatin1,
            .unicode,
            .utf16LittleEndian,
            .utf16BigEndian
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding),
               containsBankFeedTags(text) {
                return text
            }
        }

        return nil
    }

    private static func containsBankFeedTags(_ text: String) -> Bool {
        let uppercaseText = text.uppercased()
        return uppercaseText.contains("<OFX")
            || uppercaseText.contains("<STMTTRN")
            || uppercaseText.contains("<BANKMSGSRSV")
            || uppercaseText.contains("<CREDITCARDMSGSRSV")
    }
}

private enum BankFeedImportPreparationOutcome: Sendable {
    case success([SourceTransactionDraft])
    case failure(String)
}

private enum BankFeedImportPreparationError: LocalizedError {
    case unreadableContent
    case noUsableTransactions
    case fileTooLarge(actualBytes: Int64, maxBytes: Int64)

    var errorDescription: String? {
        switch self {
        case .unreadableContent:
            return "The selected OFX/QFX file could not be decoded."
        case .noUsableTransactions:
            return "The selected OFX/QFX file did not contain any usable transactions."
        case let .fileTooLarge(actualBytes, maxBytes):
            let actualMB = Double(actualBytes) / 1_000_000
            let maxMB = Double(maxBytes) / 1_000_000
            return "The selected file is \(actualMB.formatted(.number.precision(.fractionLength(1)))) MB. Tally supports imports up to \(maxMB.formatted(.number.precision(.fractionLength(0)))) MB."
        }
    }
}

private extension AppModel {
    func bankFeedTransactionSource(for url: URL) -> TransactionSource? {
        switch url.pathExtension.lowercased() {
        case "ofx":
            return .ofx
        case "qfx":
            return .qfx
        default:
            return nil
        }
    }

    func finishBankFeedImportPreparation(
        _ outcome: BankFeedImportPreparationOutcome,
        importRecordID: UUID,
        source: TransactionSource,
        into context: ModelContext
    ) async {
        defer { isPreparingImport = false }

        let importRecord: ImportRecord?
        do {
            importRecord = try self.importRecord(withID: importRecordID, in: context)
        } catch {
            currentImportRecord = nil
            importErrorMessage = "Failed to load import record: \(error.localizedDescription)"
            return
        }

        guard let importRecord else {
            currentImportRecord = nil
            if case let .failure(message) = outcome {
                importErrorMessage = message
            }
            return
        }

        switch outcome {
        case let .success(drafts):
            await commitBankFeedImport(
                drafts,
                importRecord: importRecord,
                source: source,
                context: context
            )
        case let .failure(message):
            importRecord.status = .failed
            importRecord.mappingSignature = "\(source.rawValue)_adapter"
            importRecord.errorMessage = message
            try? context.save()

            currentImportRecord = nil
            importErrorMessage = message
        }
    }

    func commitBankFeedImport(
        _ drafts: [SourceTransactionDraft],
        importRecord: ImportRecord,
        source: TransactionSource,
        context: ModelContext
    ) async {
        classificationStatusMessage = nil
        importDraft = nil

        do {
            importRecord.status = .classifying
            importRecord.mappingSignature = "\(source.rawValue)_adapter"
            importRecord.errorMessage = nil

            let seeds = drafts.map(\.seed)
            let classificationLoadResult = try await loadClassifications(
                for: seeds,
                context: context
            )
            let materializations = sourceMaterializations(
                for: drafts,
                classifications: classificationLoadResult.results
            )
            let upsertSummary = try await SourceTransactionUpsertService().upsert(
                materializations,
                importRecordID: importRecord.id,
                into: context
            )
            importRecord.status = .analyzed
            importRecord.importedTransactionCount = upsertSummary.reconciledCount

            let detectionReport = try await saveChangesAndRefreshSubscriptions(in: context)
            applyImportSummary(
                from: detectionReport,
                to: importRecord
            )
            try context.save()
            completeImportSuccess(
                importFileName: importRecord.fileName,
                upsertSummary: upsertSummary,
                skippedRowCount: 0,
                classificationLoadResult: classificationLoadResult,
                importSummary: detectionReport.summary(for: importRecord.id)
            )
        } catch {
            importRecord.status = .failed
            importRecord.errorMessage = error.localizedDescription
            try? context.save()

            currentImportRecord = nil
            importErrorMessage = error.localizedDescription
        }
    }

    func sourceMaterializations(
        for drafts: [SourceTransactionDraft],
        classifications: [String: MerchantClassificationResult]
    ) -> [SourceTransactionMaterialization] {
        drafts.map { draft in
            let classification = transactionClassification(
                for: draft.seed,
                classifications: classifications
            )

            return SourceTransactionMaterialization(
                draft: draft,
                merchantNormalized: classification.canonicalName,
                category: classification.resolvedTransactionCategory(
                    sourceCategory: draft.seed.category
                ),
                merchantKind: classification.merchantKind,
                merchantSubscriptionAffinity: classification.subscriptionAffinity,
                classificationConfidence: classification.confidence
            )
        }
    }

    func prepareImportRecord(
        for importDraft: TransactionImportDraft,
        mapping: ColumnMappingConfig,
        context: ModelContext
    ) -> ImportRecord {
        if let currentImportRecord {
            return currentImportRecord
        }

        let importRecord = ImportRecord(
            fileName: importDraft.fileName,
            sourceType: URL(fileURLWithPath: importDraft.fileName).pathExtension.lowercased(),
            status: .queued,
            mappingSignature: mapping.signature
        )
        context.insert(importRecord)
        currentImportRecord = importRecord
        return importRecord
    }

    func upsertImportedTransactions(
        _ seeds: [NormalizedTransactionSeed],
        classifications: [String: MerchantClassificationResult],
        importRecordID: UUID,
        into context: ModelContext
    ) async throws -> SourceTransactionUpsertSummary {
        let sourceReferenceIDs = manualImportSourceReferenceIDs(for: seeds)
        let materializations = seeds.enumerated().map { index, seed in
            let classification = transactionClassification(
                for: seed,
                classifications: classifications
            )

            return SourceTransactionMaterialization(
                draft: SourceTransactionDraft(
                    seed: seed,
                    source: .manualImport,
                    sourceReferenceID: sourceReferenceIDs[index],
                    sourceMetadata: ["adapter": "tabular_import"]
                ),
                merchantNormalized: classification.canonicalName,
                category: classification.resolvedTransactionCategory(
                    sourceCategory: seed.category
                ),
                merchantKind: classification.merchantKind,
                merchantSubscriptionAffinity: classification.subscriptionAffinity,
                classificationConfidence: classification.confidence
            )
        }

        return try await SourceTransactionUpsertService().upsert(
            materializations,
            importRecordID: importRecordID,
            into: context
        )
    }

    func manualImportSourceReferenceIDs(for seeds: [NormalizedTransactionSeed]) -> [String] {
        var occurrenceCountsByFingerprint: [String: Int] = [:]

        return seeds.map { seed in
            let fingerprint = SourceTransactionDraft.fingerprint(for: seed)
            let occurrence = occurrenceCountsByFingerprint[fingerprint, default: 0]
            occurrenceCountsByFingerprint[fingerprint] = occurrence + 1
            return "fingerprint:\(fingerprint)#\(occurrence)"
        }
    }

    func transactionClassification(
        for seed: NormalizedTransactionSeed,
        classifications: [String: MerchantClassificationResult]
    ) -> MerchantClassificationResult {
        classifications[seed.merchantRaw] ?? MerchantClassificationResult(
            canonicalName: seed.merchantRaw,
            serviceCategory: "Uncategorized",
            merchantKind: .unknown,
            subscriptionAffinity: 0.2,
            confidence: 0.2
        )
    }

    func completeImportSuccess(
        importFileName: String,
        upsertSummary: SourceTransactionUpsertSummary,
        skippedRowCount: Int,
        classificationLoadResult: ClassificationLoadResult,
        importSummary: SubscriptionDetectionImportSummary
    ) {
        importDraft = nil
        currentImportRecord = nil
        classificationStatusMessage = classifier.availabilitySummary(
            for: classificationLoadResult.strategy,
            uniqueMerchantCount: classificationLoadResult.uniqueMerchantCount,
            fallbackReason: classificationLoadResult.fallbackReason
        )
        let baseMessage = importResultMessage(
            importFileName: importFileName,
            upsertSummary: upsertSummary
        )
        let skippedMessage = skippedRowCount > 0
            ? "Skipped \(skippedRowCount) rows (unreadable date or amount)."
            : nil
        let detectionMessage = """
        Found \(importSummary.detectedCount) subscriptions and \
        \(importSummary.needsReviewCount) items to review.
        """
        let recoveredMessage = importSummary.recoveredCount > 0
            ? "Recovered \(importSummary.recoveredCount) borderline recurring patterns."
            : nil
        let suppressedMessage = importSummary.suppressedCount > 0
            ? "Held back \(importSummary.suppressedCount) noisy recurring signals."
            : nil
        infoMessage = [baseMessage, skippedMessage, detectionMessage, recoveredMessage, suppressedMessage]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    func handleCommitImportFailure(
        _ error: Error,
        importDraft: TransactionImportDraft,
        mapping: ColumnMappingConfig,
        context: ModelContext
    ) {
        let failedRecord = currentImportRecord ?? ImportRecord(
            fileName: importDraft.fileName,
            sourceType: URL(fileURLWithPath: importDraft.fileName).pathExtension.lowercased(),
            status: .failed,
            mappingSignature: mapping.signature
        )

        if currentImportRecord == nil {
            context.insert(failedRecord)
        }

        failedRecord.status = .failed
        failedRecord.mappingSignature = mapping.signature
        failedRecord.errorMessage = error.localizedDescription
        try? context.save()

        currentImportRecord = nil
        importErrorMessage = error.localizedDescription
    }

    func applyImportSummary(
        from detectionReport: SubscriptionDetectionReport,
        to importRecord: ImportRecord
    ) {
        importRecord.apply(detectionReport.summary(for: importRecord.id))
    }

}
