import Foundation
import SwiftData
import Testing
@testable import Tally

@MainActor
struct SubscriptionDiscoveryImportTests {
    struct Scenario: Sendable {
        let name: String
        let rows: String
        let subscriptionCount: Int
        let linkedCount: Int
        let cadence: SubscriptionCadence?
    }

    nonisolated static let scenarios: [Scenario] = [
        Scenario(
            name: "missing_months",
            rows: """
            2026-05-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-06-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-08-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-10-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            """,
            subscriptionCount: 1, linkedCount: 4, cadence: .monthly
        ),
        Scenario(
            name: "changing_plan_wording",
            rows: """
            2026-07-01,Netflix,Streaming,Premium plan,-15.49,USD
            2026-08-01,Netflix,Streaming,Standard plan,-15.49,USD
            2026-09-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            """,
            subscriptionCount: 1, linkedCount: 3, cadence: .monthly
        ),
        Scenario(
            name: "latest_price_after_increase",
            rows: """
            2026-04-01,Netflix,Streaming,Monthly subscription,-13.00,USD
            2026-05-01,Netflix,Streaming,Monthly subscription,-13.00,USD
            2026-06-01,Netflix,Streaming,Monthly subscription,-13.00,USD
            2026-07-01,Netflix,Streaming,Monthly subscription,-25.00,USD
            2026-08-01,Netflix,Streaming,Monthly subscription,-25.00,USD
            2026-09-01,Netflix,Streaming,Monthly subscription,-25.00,USD
            """,
            subscriptionCount: 1, linkedCount: 6, cadence: .monthly
        ),
        Scenario(
            name: "concurrent_plans",
            rows: """
            2026-07-01,Netflix,Streaming,Premium plan,-24.99,USD
            2026-08-01,Netflix,Streaming,Premium plan,-24.99,USD
            2026-09-01,Netflix,Streaming,Premium plan,-24.99,USD
            2026-07-10,Netflix,Streaming,Basic plan,-7.99,USD
            2026-08-10,Netflix,Streaming,Basic plan,-7.99,USD
            2026-09-10,Netflix,Streaming,Basic plan,-7.99,USD
            """,
            subscriptionCount: 2, linkedCount: 6, cadence: .monthly
        ),
        Scenario(
            name: "separate_currencies",
            rows: """
            2026-07-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-08-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-09-01,Netflix,Streaming,Monthly subscription,-15.49,USD
            2026-07-01,Netflix,Streaming,Monthly subscription,-15.49,EUR
            2026-08-01,Netflix,Streaming,Monthly subscription,-15.49,EUR
            2026-09-01,Netflix,Streaming,Monthly subscription,-15.49,EUR
            """,
            subscriptionCount: 2, linkedCount: 6, cadence: .monthly
        ),
        Scenario(
            name: "brand_substring_retail",
            rows: """
            2026-07-01,Maxwell Market,Shopping,Order,-15.49,USD
            2026-08-01,Maxwell Market,Shopping,Order,-15.49,USD
            2026-09-01,Maxwell Market,Shopping,Order,-15.49,USD
            """,
            subscriptionCount: 0, linkedCount: 0, cadence: nil
        ),
        Scenario(
            name: "quarterly_is_not_monthly",
            rows: """
            2026-04-01,Patreon,Subscription,Quarterly membership,-30.00,USD
            2026-07-01,Patreon,Subscription,Quarterly membership,-30.00,USD
            2026-10-01,Patreon,Subscription,Quarterly membership,-30.00,USD
            """,
            subscriptionCount: 1, linkedCount: 3, cadence: .quarterly
        ),
        Scenario(
            name: "irregular_known_merchant",
            rows: """
            2026-07-01,Netflix,Streaming,Charge,-15.49,USD
            2026-07-03,Netflix,Streaming,Charge,-15.49,USD
            2026-08-22,Netflix,Streaming,Charge,-15.49,USD
            2026-10-01,Netflix,Streaming,Charge,-15.49,USD
            """,
            subscriptionCount: 0, linkedCount: 0, cadence: nil
        ),
        Scenario(
            name: "missing_months_retail",
            rows: """
            2026-05-01,Neighborhood Market,Shopping,Order,-15.49,USD
            2026-06-01,Neighborhood Market,Shopping,Order,-15.49,USD
            2026-08-01,Neighborhood Market,Shopping,Order,-15.49,USD
            2026-10-01,Neighborhood Market,Shopping,Order,-15.49,USD
            """,
            subscriptionCount: 0, linkedCount: 0, cadence: nil
        )
    ]

    @Test
    func bulkImportKeepsSubscriptionsAndReimportsWithoutDuplicates() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let noise = (0..<1200).map { index in
            "2026-09-15,Neighborhood Market \(index),Shopping,Order \(index),-12.34,USD"
        }.joined(separator: "\n")
        let rows = noise + """

        2026-07-01,Netflix,Streaming,Monthly subscription,-15.49,USD
        2026-08-01,Netflix,Streaming,Monthly subscription,-15.49,USD
        2026-09-01,Netflix,Streaming,Monthly subscription,-15.49,USD
        """
        let csv = "Date,Merchant,Category,Original Statement,Amount,Currency\n" + (try currentRows(rows))
        let draft = try CSVTransactionImporter().makeDraft(fileName: "synthetic-bulk.csv", csvText: csv)
        for pass in 0..<2 {
            let startedAt = Date()
            appModel.importDraft = draft
            await appModel.commitImport(using: draft.suggestedMapping, into: context)
            #expect(appModel.importErrorMessage == nil)
            #expect(try context.fetchCount(FetchDescriptor<NormalizedTransaction>()) == 1203)
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            #expect(subscriptions.count == 1)
            #expect(subscriptions.first?.canonicalName == "Netflix")
            print("bulk_import pass=\(pass) rows=1203 elapsed_ms=\(startedAt.distance(to: .now) * 1000)")
        }
    }

    @Test(arguments: scenarios)
    func discoversSubscriptionsThroughCSVImport(_ scenario: Scenario) async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let csv = "Date,Merchant,Category,Original Statement,Amount,Currency\n" + (try currentRows(scenario.rows))
        let draft = try CSVTransactionImporter().makeDraft(fileName: "synthetic.csv", csvText: csv)
        let startedAt = Date()

        for pass in 0..<2 {
            appModel.importDraft = draft
            await appModel.commitImport(using: draft.suggestedMapping, into: context)
            #expect(appModel.importErrorMessage == nil)

            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            #expect(subscriptions.count == scenario.subscriptionCount)
            #expect(Set(subscriptions.map(\.canonicalName)).count == subscriptions.count)
            #expect(transactions.filter { $0.subscriptionID != nil }.count == scenario.linkedCount)
            #expect(transactions.count == scenario.rows.split(separator: "\n").count)
            if let cadence = scenario.cadence {
                #expect(subscriptions.allSatisfy { $0.cadence == cadence })
                #expect(subscriptions.allSatisfy { $0.status == .active })
            }
            for subscription in subscriptions {
                let linked = transactions.filter { $0.subscriptionID == subscription.id }
                #expect(linked.isEmpty == false)
                #expect(Set(linked.compactMap(\.currency)).count == 1)
                #expect(linked.allSatisfy { $0.currency == subscription.priceCurrency })
                if let latest = linked.max(by: { $0.transactionDate < $1.transactionDate }) {
                    #expect(subscription.priceAmount == abs(latest.transactionAmount))
                }
                if pass == 0 {
                    subscription.isUserConfirmed = true
                }
            }
            try context.save()
        }

        print("discovery_import scenario=\(scenario.name) elapsed_ms=\(startedAt.distance(to: .now) * 1000)")
    }

    private func currentRows(_ rows: String) throws -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let now = Date()
        let monthOffset = (calendar.component(.year, from: now) - 2026) * 12 +
            calendar.component(.month, from: now) - 10
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return try rows.split(separator: "\n").map { row in
            let separator = try #require(row.firstIndex(of: ","))
            let date = try #require(formatter.date(from: String(row[..<separator])))
            let shifted = try #require(calendar.date(byAdding: .month, value: monthOffset, to: date))
            return formatter.string(from: shifted) + String(row[separator...])
        }.joined(separator: "\n")
    }
}
