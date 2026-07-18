import Foundation
import OSLog
import SwiftData

@MainActor
struct SubscriptionDetectionService {
    let intelligence: SubscriptionIntelligenceService

    init(
        intelligence: SubscriptionIntelligenceService = SubscriptionIntelligenceService(
            usage: .backgroundAutomation
        )
    ) {
        self.intelligence = intelligence
    }

    @discardableResult
    func rebuildSubscriptions(
        in context: ModelContext
    ) async throws -> SubscriptionDetectionReport {
        try Task.checkCancellation()
        let startedAt = Date()
        let transactions = try fetchTransactions(in: context)
        let detectionRun = DetectionRun(
            trigger: .rebuild,
            transactionCount: transactions.count
        )
        context.insert(detectionRun)
        let state = DetectionAccumulator()

        await prepareTransactions(transactions)
        try checkCancellationAndRollback(in: context)

        let debitTransactions = transactions.filter { $0.transactionAmount < 0 }
        try synchronizeDerivedMatchRules(in: context, transactions: debitTransactions)
        let environment = try makeEnvironment(in: context, detectionRun: detectionRun)
        await applyMatchRules(
            to: debitTransactions,
            environment: environment,
            state: state
        )
        try checkCancellationAndRollback(in: context)
        await runDetectionPasses(
            on: debitTransactions,
            environment: environment,
            state: state
        )
        try checkCancellationAndRollback(in: context)

        removeStaleSubscriptions(
            from: environment.existingSubscriptions,
            keeping: state.seenCanonicals,
            reviewRules: environment.rulesByCanonical,
            in: context
        )
        let finalSubscriptions = try context.fetch(FetchDescriptor<Subscription>())
        try reconcileOccurrences(
            for: finalSubscriptions,
            transactions: transactions,
            detectionRun: detectionRun,
            in: context
        )

        let report = SubscriptionDetectionReport(clusters: state.clusterReports)
        detectionRun.ruleMatchCount = state.ruleMatchCount
        detectionRun.candidateCount = state.candidateCount
        detectionRun.autoConfirmCount = state.autoConfirmCount
        detectionRun.autoSuppressCount = state.autoSuppressCount
        detectionRun.needsReviewCount = state.needsReviewCount
        detectionRun.llmEvaluationCount = state.llmEvaluationCount
        detectionRun.finishedAt = .now
        detectionTelemetryLogger.notice(
            """
            rebuild_subscriptions transactions=\(transactions.count, privacy: .public) \
            existing_subscriptions=\(environment.existingSubscriptions.count, privacy: .public) \
            resulting_clusters=\(report.clusters.count, privacy: .public) \
            elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
            """
        )

        return report
    }

    private func checkCancellationAndRollback(in context: ModelContext) throws {
        guard Task.isCancelled else { return }
        context.rollback()
        throw CancellationError()
    }

    @discardableResult
    func recordUserCorrection(
        canonicalName: String,
        isSubscription: Bool,
        cadence: SubscriptionCadence?,
        in context: ModelContext
    ) throws -> MerchantCorrection {
        let descriptor = FetchDescriptor<MerchantCorrection>(
            predicate: #Predicate { $0.canonicalName == canonicalName }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.isSubscription = isSubscription
            existing.correctedCadence = cadence
            existing.updatedAt = .now
            return existing
        }

        let created = MerchantCorrection(
            canonicalName: canonicalName,
            isSubscription: isSubscription,
            correctedCadence: cadence
        )
        context.insert(created)
        return created
    }
}

private let detectionTelemetryLogger = Logger(
    subsystem: "Tally",
    category: "Detection"
)
