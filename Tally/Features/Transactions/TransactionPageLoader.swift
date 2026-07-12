import Foundation
import OSLog
import SwiftData

struct TransactionPage {
    let transactions: [NormalizedTransaction]
    let totalCount: Int
    let matchedCount: Int
}

@MainActor
struct TransactionPageLoader {
    func load(
        in context: ModelContext,
        searchText: String,
        limit: Int
    ) throws -> TransactionPage {
        let startedAt = ContinuousClock.now
        let trimmedSearchText = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let totalCount = try context.fetchCount(FetchDescriptor<NormalizedTransaction>())
        var pageDescriptor = descriptor(searchText: trimmedSearchText)
        pageDescriptor.fetchLimit = max(1, limit)

        let matchedCount = try context.fetchCount(descriptor(searchText: trimmedSearchText))
        let transactions = try context.fetch(pageDescriptor)
        let elapsed = startedAt.duration(to: .now)

        transactionPagingLogger.notice(
            "transaction_page total=\(totalCount, privacy: .public) matched=\(matchedCount, privacy: .public) loaded=\(transactions.count, privacy: .public) elapsed_ms=\(elapsed.milliseconds, privacy: .public)"
        )

        return TransactionPage(
            transactions: transactions,
            totalCount: totalCount,
            matchedCount: matchedCount
        )
    }

    private func descriptor(
        searchText: String
    ) -> FetchDescriptor<NormalizedTransaction> {
        let sort = [SortDescriptor(\NormalizedTransaction.transactionDate, order: .reverse)]
        guard searchText.isEmpty == false else {
            return FetchDescriptor(sortBy: sort)
        }

        let query = searchText
        return FetchDescriptor(
            predicate: #Predicate { transaction in
                transaction.merchantNormalized.localizedStandardContains(query) ||
                    transaction.merchantRaw.localizedStandardContains(query) ||
                    (transaction.category?.localizedStandardContains(query) ?? false) ||
                    (transaction.memo?.localizedStandardContains(query) ?? false)
            },
            sortBy: sort
        )
    }
}

private extension Duration {
    var milliseconds: Double {
        let components = self.components
        return Double(components.seconds) * 1_000 +
            Double(components.attoseconds) / 1_000_000_000_000_000
    }
}

private let transactionPagingLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Tally",
    category: "TransactionPaging"
)
