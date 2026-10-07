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

    @Test(arguments: [1, 7, 16, 28])
    func fixtureClockPreservesEachPhase(day: Int) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        for year in [2027, 2028] {
            let reference = try #require(calendar.date(from: DateComponents(year: year, month: 2, day: day, hour: 12)))
            let rows = """
            2026-07-01,Netflix,Streaming,Premium plan,-13.00,USD
            2026-09-16,Netflix,Streaming,Basic plan,-7.99,USD
            2026-08-01,Netflix,Streaming,Standard plan,-25.00,USD
            2026-10-16,Netflix,Streaming,Basic plan,-7.99,USD
            2026-10-01,Netflix,Streaming,Monthly subscription,-25.00,USD
            2026-10-01,Netflix,Streaming,Euro plan,-21.00,EUR
            2026-09-30,Patreon,Subscription,Membership,-20.00,USD
            2026-10-31,Patreon,Subscription,Membership,-20.00,USD
            """
            try verifyFixtureRows(rows, reference: reference, calendar: calendar)
            for scenario in Self.scenarios {
                try verifyFixtureRows(scenario.rows, reference: reference, calendar: calendar)
            }
        }
    }

    private func verifyFixtureRows(_ rows: String, reference: Date, calendar: Calendar) throws {
        let shifted = try currentRows(rows, reference: reference, calendar: calendar)
        let originals = rows.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        let actual = shifted.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
        #expect(originals.count == actual.count)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var phases: [String: [(Date, Date)]] = [:]
        var buckets: [String: [(Date, Date)]] = [:]
        for (before, after) in zip(originals, actual) {
            #expect(Array(before.dropFirst()) == Array(after.dropFirst()))
            let old = try #require(formatter.date(from: before[0]))
            let new = try #require(formatter.date(from: after[0]))
            #expect(new <= reference)
            let key = "\(before[1])|\(before[5])|\(calendar.component(.day, from: old))"
            phases[key, default: []].append((old, new))
            buckets["\(before[1])|\(before[5])", default: []].append((old, new))
        }
        for bucket in buckets.values {
            let dayGroups = Dictionary(grouping: bucket) { calendar.component(.day, from: $0.0) }
            let clockGroups = dayGroups.values.allSatisfy { $0.count >= 2 } ? Array(dayGroups.values) : [bucket]
            for group in clockGroups {
                let latest = try #require(group.max { $0.0 < $1.0 })
                let nextMonth = try #require(calendar.date(byAdding: .month, value: 1, to: latest.1))
                let nextActual = calendar.dateByClamping(day: calendar.component(.day, from: latest.0), inMonthOf: nextMonth)
                #expect(nextActual > reference)
                let offsets = try group.map { old, new in
                    let oldMonth = try #require(calendar.dateInterval(of: .month, for: old)?.start)
                    let newMonth = try #require(calendar.dateInterval(of: .month, for: new)?.start)
                    return try #require(calendar.dateComponents([.month], from: oldMonth, to: newMonth).month)
                }
                #expect(Set(offsets).count == 1)
            }
        }
        for pairs in phases.values {
            let ordered = pairs.sorted { $0.0 < $1.0 }

            for (first, second) in zip(ordered, ordered.dropFirst()) {
                let oldStart = try #require(calendar.dateInterval(of: .month, for: first.0)?.start)
                let oldEnd = try #require(calendar.dateInterval(of: .month, for: second.0)?.start)
                let newStart = try #require(calendar.dateInterval(of: .month, for: first.1)?.start)
                let newEnd = try #require(calendar.dateInterval(of: .month, for: second.1)?.start)
                #expect(
                    calendar.dateComponents([.month], from: oldStart, to: oldEnd).month ==
                    calendar.dateComponents([.month], from: newStart, to: newEnd).month
                )
            }
        }
    }

    @Test
    func fixtureClockPreservesIrregularHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let scenario = try #require(Self.scenarios.first { $0.name == "irregular_known_merchant" })
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let references = ["2026-10-07"] + [2027, 2028].flatMap { year in
            [1, 7, 16, 28].map { String(format: "%04d-02-%02d", year, $0) }
        }
        for value in references {
            let reference = try #require(formatter.date(from: value))
            try verifyFixtureRows(scenario.rows, reference: reference, calendar: calendar)
            let shifted = try currentRows(scenario.rows, reference: reference, calendar: calendar)
            let oldRows = scenario.rows.split(separator: "\n").map { $0.split(separator: ",").map(String.init) }
            let newRows = shifted.split(separator: "\n").map { $0.split(separator: ",").map(String.init) }
            var offsets: [Int] = []
            for (old, new) in zip(oldRows, newRows) {
                let oldDate = try #require(formatter.date(from: old[0]))
                let newDate = try #require(formatter.date(from: new[0]))
                #expect(calendar.component(.day, from: oldDate) == calendar.component(.day, from: newDate))
                #expect(Array(old.dropFirst()) == Array(new.dropFirst()))
                let oldMonth = try #require(calendar.dateInterval(of: .month, for: oldDate)?.start)
                let newMonth = try #require(calendar.dateInterval(of: .month, for: newDate)?.start)
                offsets.append(try #require(calendar.dateComponents([.month], from: oldMonth, to: newMonth).month))
            }
            #expect(Set(offsets).count == 1)
            if value == "2026-10-07" { #expect(shifted == scenario.rows) }
        }
    }

    @Test
    func denseDailyHistoryRetainsEveryCharge() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2023, month: 1, day: 1)))
        let charges = try (0..<1000).map { index in
            RecurringCharge(id: UUID(), date: try #require(calendar.date(byAdding: .day, value: index, to: start)), amount: 10)
        }
        let histories = RecurringHistoryAnalyzer.histories(in: charges, calendar: calendar)
        #expect(histories.count == 7)
        #expect(histories.allSatisfy { $0.schedule.cadence == .weekly })
        let ids = histories.flatMap(\.transactionIDs)
        #expect(ids.count == 1000)
        #expect(Set(ids) == Set(charges.map(\.id)))
    }

    @Test(arguments: ["UTC", "America/Boise", "Pacific/Apia", "Australia/Lord_Howe"])
    func monthlyHistoryRetainsMonthEndAnchor(zone: String) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let start = try #require(calendar.date(from: DateComponents(year: 2023, month: 1, day: 31)))
        let charges = try (0..<10).map { index in
            RecurringCharge(
                id: UUID(), date: try #require(calendar.date(byAdding: .month, value: index, to: start)),
                amount: index < 5 ? 10 : 15
            )
        }
        let histories = RecurringHistoryAnalyzer.histories(in: Array(charges.reversed()), calendar: calendar)
        #expect(histories.count == 1)
        let history = try #require(histories.first)
        #expect(history.transactionIDs == charges.map(\.id))
        #expect(history.schedule.cadence == .monthly)
        #expect(history.schedule.isMonthEnd)
        #expect(history.schedule.anchor == calendar.startOfDay(for: start))
        #expect(history.consistency == 1)
    }

    private func currentRows(
        _ rows: String, reference: Date = .now, calendar suppliedCalendar: Calendar? = nil
    ) throws -> String {
        var calendar = suppliedCalendar ?? Calendar(identifier: .gregorian)
        if suppliedCalendar == nil { calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        struct Phase: Hashable {
            let merchant: String
            let currency: String
            let day: Int
        }
        let parsed = try rows.split(separator: "\n").map { row in
            let separator = try #require(row.firstIndex(of: ","))
            let date = try #require(formatter.date(from: String(row[..<separator])))
            let fields = row.split(separator: ",", omittingEmptySubsequences: false)
            try #require(fields.count == 6)
            let phase = Phase(merchant: String(fields[1]), currency: String(fields[5]), day: calendar.component(.day, from: date))
            return (date: date, suffix: String(row[separator...]), phase: phase)
        }
        let buckets = Dictionary(grouping: parsed) { [$0.phase.merchant, $0.phase.currency] }
        let groups = buckets.values.flatMap { bucket in
            let phases = Dictionary(grouping: bucket, by: \.phase)
            return phases.values.allSatisfy { $0.count >= 2 } ? Array(phases.values) : [bucket]
        }
        let referenceMonth = try #require(calendar.dateInterval(of: .month, for: reference)?.start)
        var offsets: [Phase: Int] = [:]
        for charges in groups {
            let latest = try #require(charges.map(\.date).max())
            let originalMonth = try #require(calendar.dateInterval(of: .month, for: latest)?.start)
            var offset = try #require(calendar.dateComponents([.month], from: originalMonth, to: referenceMonth).month)
            let shiftedLatest = try #require(calendar.date(byAdding: .month, value: offset, to: latest))
            if shiftedLatest > reference { offset -= 1 }
            for charge in charges { offsets[charge.phase] = offset }
        }
        return try parsed.map { row in
            let offset = try #require(offsets[row.phase])
            let shifted = try #require(calendar.date(byAdding: .month, value: offset, to: row.date))
            return formatter.string(from: shifted) + row.suffix
        }.joined(separator: "\n")
    }

}
