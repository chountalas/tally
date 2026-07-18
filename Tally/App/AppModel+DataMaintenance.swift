import Foundation
import OSLog
import SwiftData

extension AppModel {
    func seedSampleDataIfNeeded(context: ModelContext) async {
        guard !isLoadingSampleData else {
            return
        }

        isLoadingSampleData = true
        defer { isLoadingSampleData = false }

        do {
            let existing = try context.fetchCount(FetchDescriptor<NormalizedTransaction>())
            guard existing == 0 else {
                infoMessage = "Sample data is only loaded into an empty library."
                return
            }

            let draft = try CSVTransactionImporter().makeDraft(
                fileName: "Sample Subscription Data.csv",
                csvText: Self.sampleDataCSV
            )
            importDraft = draft
            await commitImport(using: draft.suggestedMapping, into: context)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    func refreshSubscriptionAnalysis(in context: ModelContext) async {
        guard !isRefreshingAnalysis else {
            return
        }

        let startedAt = Date()
        classificationStatusMessage = nil
        importErrorMessage = nil
        isRefreshingAnalysis = true
        defer {
            isRefreshingAnalysis = false
            appMaintenanceLogger.notice(
                """
                refresh_subscription_analysis elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
                """
            )
        }

        do {
            let transactions = try fetchTransactionsForRefresh(in: context)
            guard transactions.isEmpty == false else {
                infoMessage = "No transactions are available to refresh."
                appMaintenanceLogger.notice("refresh_subscription_analysis skipped_empty_library")
                return
            }

            let seeds = refreshSeeds(from: transactions)
            let classificationLoadResult = try await loadClassifications(
                for: seeds,
                context: context,
                forceRefresh: false
            )
            await applyRefreshedClassifications(
                classificationLoadResult.results,
                to: transactions
            )
            _ = try await saveChangesAndRefreshSubscriptions(in: context)
            completeRefresh(
                transactionCount: transactions.count,
                classificationLoadResult: classificationLoadResult
            )
            appMaintenanceLogger.notice(
                """
                refresh_subscription_analysis completed transactions=\(transactions.count, privacy: .public) \
                unique_merchants=\(classificationLoadResult.uniqueMerchantCount, privacy: .public) \
                strategy=\(String(describing: classificationLoadResult.strategy), privacy: .public)
                """
            )
        } catch {
            appMaintenanceLogger.error(
                "refresh_subscription_analysis failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            importErrorMessage = error.localizedDescription
        }
    }
}

private let appMaintenanceLogger = Logger(
    subsystem: "Tally",
    category: "AppMaintenance"
)

private extension AppModel {
    static let sampleDataCSV = """
    Date,Merchant,Amount,Category,Account,Memo
    2025-01-04,Netflix,-15.49,Streaming,Checking,Standard plan
    2025-02-04,Netflix,-15.49,Streaming,Checking,Standard plan
    2025-03-04,Netflix,-15.49,Streaming,Checking,Standard plan
    2024-03-18,Spotify,-10.99,Music,Credit Card,Family plan
    2024-04-18,Spotify,-10.99,Music,Credit Card,Family plan
    2024-05-18,Spotify,-10.99,Music,Credit Card,Family plan
    2024-06-18,Spotify,-10.99,Music,Credit Card,Family plan
    2024-01-08,Adobe,-59.99,Software,Credit Card,Creative Cloud
    2024-02-08,Adobe,-59.99,Software,Credit Card,Creative Cloud
    2024-03-08,Adobe,-59.99,Software,Credit Card,Creative Cloud
    2024-07-02,Costco,-64.12,Groceries,Checking,Warehouse trip
    2023-11-12,Dropbox,-119.88,Software,Credit Card,Annual renewal
    2024-11-12,Dropbox,-119.88,Software,Credit Card,Annual renewal
    2023-09-22,Hulu,-7.99,Streaming,Checking,Bundle
    2023-10-22,Hulu,-7.99,Streaming,Checking,Bundle
    2023-11-22,Hulu,-7.99,Streaming,Checking,Bundle
    2024-01-22,Hulu,-7.99,Streaming,Checking,Bundle
    """

    func fetchTransactionsForRefresh(
        in context: ModelContext
    ) throws -> [NormalizedTransaction] {
        try context.fetch(
            FetchDescriptor<NormalizedTransaction>(
                sortBy: [SortDescriptor(\.transactionDate, order: .forward)]
            )
        )
    }

    func refreshSeeds(
        from transactions: [NormalizedTransaction]
    ) -> [NormalizedTransactionSeed] {
        transactions.map(\.classificationSeed)
    }

    func applyRefreshedClassifications(
        _ classifications: [String: MerchantClassificationResult],
        to transactions: [NormalizedTransaction]
    ) async {
        for (index, transaction) in transactions.enumerated() {
            let classification = refreshedClassification(
                for: transaction,
                classifications: classifications
            )

            transaction.merchantNormalized = classification.canonicalName
            transaction.classificationConfidence = classification.confidence
            transaction.merchantKind = classification.merchantKind
            transaction.merchantSubscriptionAffinity = classification.subscriptionAffinity
            transaction.category = classification.resolvedTransactionCategory(
                sourceCategory: transaction.category
            )
            if index.isMultiple(of: 250) {
                await Task.yield()
            }
        }
    }

    func refreshedClassification(
        for transaction: NormalizedTransaction,
        classifications: [String: MerchantClassificationResult]
    ) -> MerchantClassificationResult {
        classifications[transaction.merchantRaw] ?? MerchantClassificationResult(
            canonicalName: transaction.merchantNormalized.nilIfBlank ?? transaction.merchantRaw,
            serviceCategory: transaction.category ?? "Uncategorized",
            merchantKind: transaction.merchantKind,
            subscriptionAffinity: max(transaction.merchantSubscriptionAffinity, 0.2),
            confidence: max(transaction.classificationConfidence, 0.2)
        )
    }

    func completeRefresh(
        transactionCount: Int,
        classificationLoadResult: ClassificationLoadResult
    ) {
        classificationStatusMessage = classifier.availabilitySummary(
            for: classificationLoadResult.strategy,
            uniqueMerchantCount: classificationLoadResult.uniqueMerchantCount,
            fallbackReason: classificationLoadResult.fallbackReason
        )
        infoMessage = "Refreshed subscription analysis for \(transactionCount) transactions."
    }
}
