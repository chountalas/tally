import Foundation
import SwiftData
import Testing
@testable import Tally

@MainActor
struct MultiYearSubscriptionImportTests {
    enum Plans: CaseIterable, Sendable {
        case twoMonthly
        case monthlyAndAnnual
    }

    nonisolated static let planScenarios: [Plans] = [.twoMonthly, .monthlyAndAnnual]

    @Test(arguments: planScenarios)
    func separatesThreeYearsOfSamePricePlans(_ plans: Plans) async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let first = history.monthly(merchant: "Netflix", day: 5, amount: "15.49")
        let second = plans == .twoMonthly
            ? history.monthly(merchant: "Netflix", day: 20, amount: "15.49")
            : history.annual(merchant: "Netflix", day: 20, amount: "15.49")
        let rows = first + second + history.coverage()

        try await importRows(rows, app: app, context: context)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        #expect(subscriptions.count == 2)
        #expect(transactions.filter { $0.subscriptionID != nil }.count == first.count + second.count)
        #expect(subscriptions.allSatisfy { $0.status == .active })
        #expect(subscriptions.filter { $0.cadence == .annual }.count == (plans == .monthlyAndAnnual ? 1 : 0))
        #expect(Set(subscriptions.compactMap(\.predictedNextChargeDate)).count == 2)
        for subscription in subscriptions {
            let linked = transactions.filter { $0.subscriptionID == subscription.id }
            let expectedDay = try #require(linked.first).transactionDate
            #expect(linked.allSatisfy {
                history.calendar.component(.day, from: $0.transactionDate) ==
                    history.calendar.component(.day, from: expectedDay)
            })
        }
    }

    @Test
    func expandsConfirmedHistoryWithoutPriceBasedIdentityChurn() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let prices = (0..<36).map { $0 < 12 || $0 >= 24 ? "10.00" : "20.00" }
        let primary = history.monthly(merchant: "Netflix", day: 5, prices: prices)
        try await importRows(Array(primary.prefix(12)) + Array(history.coverage().prefix(12)), app: app, context: context)
        let original = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        original.isUserConfirmed = true
        let originalID = original.id
        try context.save()

        let second = Array(history.monthly(merchant: "Netflix", day: 20, amount: "15.00").dropFirst(12))
        let foreignCurrency = history.monthly(merchant: "Netflix", day: 20, amount: "15.00", currency: "EUR")
        let rows = primary + second + foreignCurrency + history.coverage()
        for _ in 0..<2 {
            try await importRows(rows.reversed(), app: app, context: context)
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            #expect(subscriptions.count == 3)
            #expect(transactions.count == rows.count)
            let retained = try #require(subscriptions.first { $0.id == originalID })
            #expect(retained.isUserConfirmed)
            #expect(retained.priceAmount == 10)
            #expect(retained.firstChargeDate == primary.first?.date)
            #expect(transactions.filter { $0.subscriptionID == originalID }.count == 36)
            #expect(transactions.filter { $0.subscriptionID != nil }.count == primary.count + second.count + foreignCurrency.count)
            for subscription in subscriptions {
                let linked = transactions.filter { $0.subscriptionID == subscription.id }
                #expect(Set(linked.compactMap(\.currency)).count == 1)
            }
        }
    }

    @Test
    func confirmedSubscriptionEndsWhenTheAccountKeepsBeingObserved() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let ended = Array(history.monthly(merchant: "Adobe", day: 5, amount: "19.99").prefix(12))
        try await importRows(ended + Array(history.coverage().prefix(12)), app: app, context: context)
        let original = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        original.isUserConfirmed = true
        let originalID = original.id
        try context.save()
        for _ in 0..<2 {
            try await importRows(ended + history.coverage(), app: app, context: context)
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            let subscription = try #require(subscriptions.first { $0.id == originalID })
            #expect(subscriptions.count == 1)
            #expect(subscription.status == .former)
            #expect(subscription.predictedNextChargeDate == nil)
            #expect(DashboardMetrics.currentActiveSubscriptions(from: subscriptions).isEmpty)
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            #expect(transactions.filter { $0.subscriptionID == originalID }.count == ended.count)
        }
    }

    @Test
    func oldExportsAndOtherAccountsDoNotProveCancellation() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let old = Array(history.monthly(merchant: "Netflix", day: 5, amount: "15.49").prefix(12))
        try await importRows(old + history.coverage(account: "Other card"), app: app, context: context)
        let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        #expect(subscription.status == .needsReview)
        #expect(subscription.predictedNextChargeDate == nil)
        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        #expect(occurrences.contains { $0.status == .missed } == false)
    }

    @Test
    func userCancellationRemainsAuthoritative() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let rows = history.monthly(merchant: "Netflix", day: 5, amount: "15.49") + history.coverage()
        try await importRows(rows, app: app, context: context)
        let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        let originalID = subscription.id
        try app.cancelSubscription(id: originalID, in: context)
        try await importRows(rows, app: app, context: context)
        let retained = try #require(try context.fetch(FetchDescriptor<Subscription>()).first { $0.id == originalID })
        #expect(retained.status == .former)
        #expect(retained.predictedNextChargeDate == nil)
    }

    @Test
    func editingOnePlanDoesNotRewriteTheOtherPlansMerchant() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let primary = history.monthly(merchant: "Netflix", day: 5, amount: "15.49")
        try await importRows(Array(primary.prefix(12)), app: app, context: context)
        let selected = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        let rows = primary + history.monthly(merchant: "Netflix", day: 20, amount: "15.49") + history.coverage()
        try await importRows(rows, app: app, context: context)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let other = try #require(subscriptions.first { $0.id != selected.id })
        let otherName = other.displayName
        _ = try await app.applyMerchantLearning(
            subscriptionID: selected.id, displayName: "My streaming plan", status: .active,
            cadence: .monthly, priceAmount: Decimal(string: "15.49"), priceCurrency: "USD",
            lastChargeDate: nil, category: "Streaming", notes: "Selected plan only",
            isUserConfirmed: true, isFalsePositive: false, applyAliasToFutureImports: false, in: context
        )
        #expect(try context.fetch(FetchDescriptor<NormalizedTransaction>()).allSatisfy {
            $0.merchantRaw != "Netflix" || $0.merchantNormalized == "Netflix"
        })
        try await importRows(rows, app: app, context: context)
        let retained = try context.fetch(FetchDescriptor<Subscription>())
        #expect(retained.count == 2)
        #expect(retained.first { $0.id == selected.id }?.displayName == "My streaming plan")
        #expect(retained.first { $0.id == selected.id }?.notes == "Selected plan only")
        #expect(retained.first { $0.id == other.id }?.displayName == otherName)
        let charges = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        #expect(charges.filter { $0.subscriptionID == selected.id }.count == 36)
        #expect(charges.filter { $0.subscriptionID == other.id }.count == 36)
        _ = try await app.applyMerchantLearning(
            subscriptionID: selected.id, displayName: "My streaming plan", status: .former,
            cadence: nil, priceAmount: nil, priceCurrency: nil, lastChargeDate: nil,
            category: nil, notes: nil, isUserConfirmed: true, isFalsePositive: true,
            applyAliasToFutureImports: false, in: context
        )
        try await importRows(rows, app: app, context: context)
        let remaining = try context.fetch(FetchDescriptor<Subscription>())
        #expect(remaining.map(\.id) == [other.id])
    }

    @Test
    func rejectedPlanStaysRejectedWhenEarlierChargesAreImported() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let primary = history.monthly(merchant: "Netflix", day: 5, amount: "15.49")
        let second = history.monthly(merchant: "Netflix", day: 20, amount: "15.49")
        try await importRows(Array(primary.suffix(12)) + Array(second.suffix(12)), app: app, context: context)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let charges = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let firstID = try #require(charges.first {
            history.calendar.component(.day, from: $0.transactionDate) == 5
        }?.subscriptionID)
        let selected = try #require(subscriptions.first { $0.id == firstID })
        let other = try #require(subscriptions.first { $0.id != firstID })
        _ = try await app.applyMerchantLearning(
            subscriptionID: selected.id, displayName: selected.displayName, status: .former,
            cadence: nil, priceAmount: nil, priceCurrency: nil, lastChargeDate: nil,
            category: nil, notes: nil, isUserConfirmed: true, isFalsePositive: true,
            applyAliasToFutureImports: false, in: context
        )
        for _ in 0..<2 {
            try await importRows(primary + second + history.coverage(), app: app, context: context)
            let retained = try context.fetch(FetchDescriptor<Subscription>())
            #expect(retained.map(\.id) == [other.id])
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            #expect(transactions.filter { $0.subscriptionID == other.id }.count == 36)
            #expect(transactions.filter {
                $0.merchantRaw == "Netflix" && history.calendar.component(.day, from: $0.transactionDate) == 5
            }.allSatisfy { $0.subscriptionID == nil })
        }
    }

    @Test
    func monthEndRenewalsRetainTheirCalendarAnchor() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let rows = history.monthly(merchant: "Netflix", day: 31, amount: "15.49")
        try await importRows(rows, app: app, context: context)
        let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
        #expect(subscription.status == .active)
        #expect(subscription.predictedNextChargeDate == history.date(month: 36, day: 31))
        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        #expect(occurrences.filter { $0.matchedTransactionID != nil }.count == 36)
        #expect(occurrences.contains { $0.status == .missed } == false)
    }

    @Test(.timeLimit(.minutes(3)))
    func importsTenThousandPurchasesAndThreeYearsOfSubscriptions() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let noise = (0..<10_000).map { index in
            Row(date: history.calendar.date(byAdding: .day, value: index / 10, to: history.start) ?? history.start,
                merchant: "Neighborhood Market \(index % 8)", category: "Shopping", memo: "Order \(index)",
                amount: "\(10 + index % 25).\(String(format: "%02d", index % 100))")
        }
        let subscriptions = history.monthly(merchant: "Netflix", day: 5, amount: "15.49") +
            history.monthly(merchant: "Netflix", day: 20, amount: "15.49") +
            history.annual(merchant: "Notion", day: 20, amount: "120.00") +
            Array(history.monthly(merchant: "Adobe", day: 5, amount: "19.99").prefix(12))
        let rows = noise + subscriptions + history.coverage()
        var originalIDs = Set<UUID>()
        for pass in 0..<2 {
            let started = Date()
            try await importRows(rows, app: app, context: context)
            let detected = try context.fetch(FetchDescriptor<Subscription>())
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            #expect(detected.count == 4)
            #expect(detected.filter { $0.status == .former }.count == 1)
            #expect(transactions.count == rows.count)
            #expect(transactions.filter { $0.subscriptionID != nil }.count == subscriptions.count)
            let ids = Set(detected.map(\.id))
            if pass == 0 { originalIDs = ids } else { #expect(ids == originalIDs) }
            print("multi_year_import pass=\(pass) rows=\(rows.count) elapsed_ms=\(started.distance(to: .now) * 1000)")
        }
    }

    private func importRows<S: Sequence>(_ rows: S, app: AppModel, context: ModelContext) async throws where S.Element == Row {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        let text = "Date,Merchant,Category,Original Statement,Amount,Currency,Account\n" + rows.map {
            "\(formatter.string(from: $0.date)),\($0.merchant),\($0.category),\($0.memo),-\($0.amount),\($0.currency),\($0.account)"
        }.joined(separator: "\n")
        let draft = try CSVTransactionImporter().makeDraft(fileName: "synthetic-three-years.csv", csvText: text)
        app.importDraft = draft
        await app.commitImport(using: draft.suggestedMapping, into: context)
        #expect(app.importErrorMessage == nil)
    }

    private struct Row {
        let date: Date
        let merchant: String
        var category = "Streaming"
        var memo = "Monthly subscription"
        let amount: String
        var currency = "USD"
        var account = "Visa"
    }

    private struct History {
        let calendar = Calendar(identifier: .gregorian)
        var start: Date {
            let currentMonth = calendar.dateInterval(of: .month, for: .now)?.start ?? .now
            return calendar.date(byAdding: .month, value: -36, to: currentMonth) ?? currentMonth
        }
        func date(month: Int, day: Int) -> Date {
            let monthDate = calendar.date(byAdding: .month, value: month, to: start) ?? start
            let days = calendar.range(of: .day, in: .month, for: monthDate) ?? 1..<32
            return calendar.date(byAdding: .day, value: min(day, days.count) - 1, to: monthDate) ?? monthDate
        }
        func monthly(merchant: String, day: Int, amount: String, currency: String = "USD") -> [Row] {
            monthly(merchant: merchant, day: day, prices: Array(repeating: amount, count: 36), currency: currency)
        }
        func monthly(merchant: String, day: Int, prices: [String], currency: String = "USD") -> [Row] {
            prices.enumerated().map { index, amount in
                Row(date: date(month: index, day: day), merchant: merchant, amount: amount, currency: currency)
            }
        }
        func annual(merchant: String, day: Int, amount: String) -> [Row] {
            [0, 12, 24].map {
                Row(date: date(month: $0, day: day), merchant: merchant, memo: "Annual subscription", amount: amount)
            }
        }
        func coverage(account: String = "Visa") -> [Row] {
            (0..<36).map {
                Row(date: date(month: $0, day: 31), merchant: "Neighborhood Market", category: "Shopping",
                    memo: "Order", amount: "12.34", account: account)
            }
        }
    }
}
