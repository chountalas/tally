import Foundation
import Observation
import OSLog
import SwiftData

/// Tally "Add or update" flow. One sheet host swaps between the friendly chooser
/// and the real add/edit form, so the chooser → form hand-off is a single
/// `.sheet(item:)` identity change rather than a dismiss-then-present race.
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
    let metrics: DashboardMetrics
}

struct DashboardContentSnapshot {
    let revision: LibraryRevision
    let metrics: DashboardMetrics
    let reviewQueueSubscriptions: [Subscription]
    let upcomingRenewals: [Subscription]
    let probableRenewals: [Subscription]
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

    func snapshot(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        revision: LibraryRevision
    ) -> DashboardMetricsSnapshot {
        if let cachedSnapshot, cachedSnapshot.revision == revision {
            return cachedSnapshot
        }

        let startedAt = Date()
        let snapshot = DashboardMetricsSnapshot(
            revision: revision,
            metrics: DashboardMetrics(
                subscriptions: subscriptions,
                transactions: transactions
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
        if let cachedContentSnapshot, cachedContentSnapshot.revision == revision {
            return cachedContentSnapshot
        }

        let startedAt = Date()
        let metricsSnapshot = snapshot(
            subscriptions: subscriptions,
            transactions: transactions,
            revision: revision
        )
        let metrics = metricsSnapshot.metrics
        let activeSubscriptions = subscriptions
            .filter { $0.status == .active }
            .sorted {
                ($0.predictedNextChargeDate ?? .distantFuture)
                    < ($1.predictedNextChargeDate ?? .distantFuture)
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
        let contentSnapshot = DashboardContentSnapshot(
            revision: revision,
            metrics: metrics,
            reviewQueueSubscriptions: reviewQueueSubscriptions,
            upcomingRenewals: Array(metrics.upcomingRenewals.prefix(6)),
            probableRenewals: Array(metrics.probableRenewals.prefix(4)),
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

    func invalidate() {
        cachedSnapshot = nil
        cachedContentSnapshot = nil
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
            intelligence: backgroundAutomationIntelligence
        )
    }

    init(
        startupMessage: String? = nil,
        aiProviderPreferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        libraryResetService: LibraryResetService = LibraryResetService(),
        dashboardMetricsProvider: DashboardMetricsProvider? = nil,
        csvImporter: CSVTransactionImporter = CSVTransactionImporter(),
        xlsxImporter: XLSXTransactionImporter = XLSXTransactionImporter(),
        xlsImporter: XLSBinaryTransactionImporter = XLSBinaryTransactionImporter()
    ) {
        self.startupMessage = startupMessage
        self.aiProviderPreferences = aiProviderPreferences
        self.gemmaModelManager = gemmaModelManager
        self.libraryResetService = libraryResetService
        self.dashboardMetricsProvider = dashboardMetricsProvider ?? DashboardMetricsProvider()
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

            let seeds = try csvImporter.materializeTransactions(from: importDraft, mapping: mapping)
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
                seedCount: seeds.count,
                importFileName: importRecord.fileName,
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

private extension AppModel {
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
                category: resolvedTransactionCategory(
                    sourceCategory: seed.category,
                    classification: classification
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

    func resolvedTransactionCategory(
        sourceCategory: String?,
        classification: MerchantClassificationResult,
        preferClassification: Bool = false
    ) -> String? {
        let sourceCategory = sourceCategory?.nilIfBlank
        let classifiedCategory = classification.serviceCategory.nilIfBlank

        guard let classifiedCategory else {
            return sourceCategory
        }

        if preferClassification {
            return classifiedCategory
        }

        guard let sourceCategory else {
            return classifiedCategory
        }

        if sourceCategory == "Uncategorized" {
            return classifiedCategory
        }

        let shouldTrustClassification =
            classification.confidence >= 0.8 &&
            (
                classification.subscriptionAffinity >= 0.65 ||
                classification.merchantKind.isUsuallyNonSubscription == false
            )

        return shouldTrustClassification ? classifiedCategory : sourceCategory
    }

    func completeImportSuccess(
        seedCount: Int,
        importFileName: String,
        classificationLoadResult: ClassificationLoadResult,
        importSummary: SubscriptionDetectionImportSummary
    ) {
        importDraft = nil
        currentImportRecord = nil
        classificationStatusMessage = classifier.availabilitySummary(
            for: classificationLoadResult.strategy,
            uniqueMerchantCount: classificationLoadResult.uniqueMerchantCount
        )
        let baseMessage = "Imported \(seedCount) transactions from \(importFileName)."
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
        infoMessage = [baseMessage, detectionMessage, recoveredMessage, suppressedMessage]
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
        let summary = detectionReport.summary(for: importRecord.id)
        importRecord.detectedSubscriptionCount = summary.detectedCount
        importRecord.needsReviewSubscriptionCount = summary.needsReviewCount
        importRecord.suppressedRecurringCandidateCount = summary.suppressedCount
        importRecord.recoveredRecurringCandidateCount = summary.recoveredCount
    }

}
