import SwiftData
import XCTest
@testable import Tally

@MainActor
final class TransactionPageLoaderTests: XCTestCase {
    func testLoadLimitsResultsAndReportsFullCountNewestFirst() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let calendar = Calendar(identifier: .gregorian)
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))

        for index in 0..<250 {
            context.insert(makeTransaction(
                day: index,
                start: start,
                merchant: "Merchant \(index)"
            ))
        }
        try context.save()

        let page = try TransactionPageLoader().load(
            in: context,
            searchText: "",
            limit: 100
        )

        XCTAssertEqual(page.transactions.count, 100)
        XCTAssertEqual(page.totalCount, 250)
        XCTAssertEqual(page.matchedCount, 250)
        XCTAssertEqual(page.transactions.first?.merchantNormalized, "Merchant 249")
        XCTAssertEqual(page.transactions.last?.merchantNormalized, "Merchant 150")
    }

    func testLoadSearchesMerchantCategoryAndMemoBeforeApplyingLimit() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let start = Date(timeIntervalSince1970: 1_700_000_000)

        context.insert(makeTransaction(day: 0, start: start, merchant: "StreamCo"))
        context.insert(makeTransaction(day: 1, start: start, merchant: "Corner Shop", category: "Streaming"))
        context.insert(makeTransaction(day: 2, start: start, merchant: "Utility", memo: "STREAMCO family plan"))
        context.insert(makeTransaction(day: 3, start: start, merchant: "Unrelated"))
        try context.save()

        let page = try TransactionPageLoader().load(
            in: context,
            searchText: "stream",
            limit: 2
        )

        XCTAssertEqual(page.transactions.count, 2)
        XCTAssertEqual(page.totalCount, 4)
        XCTAssertEqual(page.matchedCount, 3)
        XCTAssertEqual(page.transactions.map(\.merchantNormalized), ["Utility", "Corner Shop"])
    }

    private func makeTransaction(
        day: Int,
        start: Date,
        merchant: String,
        category: String? = nil,
        memo: String? = nil
    ) -> NormalizedTransaction {
        NormalizedTransaction(
            transactionDate: Calendar(identifier: .gregorian).date(
                byAdding: .day,
                value: day,
                to: start
            ) ?? start,
            transactionAmount: -9.99,
            merchantRaw: merchant,
            merchantNormalized: merchant,
            category: category,
            memo: memo
        )
    }
}
