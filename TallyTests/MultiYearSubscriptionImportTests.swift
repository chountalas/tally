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
            let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
            #expect(occurrences.filter { $0.subscriptionID == originalID && $0.status == .priceChanged }.count == 2)
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
        let record = try #require(try context.fetch(FetchDescriptor<ImportRecord>()).first)
        #expect(record.needsReviewSubscriptionCount == 1)
        #expect(record.detectedSubscriptionCount == 0)
        #expect(record.recoveredRecurringCandidateCount == 0)
        let runs = try context.fetch(FetchDescriptor<DetectionRun>())
        #expect(runs.count == 1)
        #expect(runs.first?.needsReviewCount == 1)
        let report = try await app.detector.rebuildSubscriptions(in: context)
        let summary = report.summary(for: record.id)
        #expect(summary.needsReviewCount == 1)
        #expect(summary.detectedCount == 0)
        #expect(summary.recoveredCount == 0)
        let cluster = try #require(report.clusters.first { $0.subscriptionID == subscription.id })
        #expect(cluster.reason == subscription.detectionReason)
    }

    @Test
    func importReportsKeepSameMerchantAccountHistoriesSeparate() async throws {
        let history = History()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let app = AppModel.testing()
        let old = Array(history.monthly(merchant: "Netflix", day: 5, amount: "15.49").prefix(12))
        let current = history.monthly(merchant: "Netflix", day: 20, amount: "15.49").map { row in
            var value = row
            value.account = "Other card"
            return value
        }
        let rows = old + current
        var originalIDs = Set<UUID>()
        for pass in 0..<2 {
            try await importRows(pass == 0 ? rows : Array(rows.reversed()), app: app, context: context)
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            #expect(subscriptions.count == 2)
            #expect(subscriptions.filter { DashboardMetrics.needsReview(for: $0) }.count == 1)
            #expect(subscriptions.filter { $0.status == .active }.count == 1)
            let ids = Set(subscriptions.map(\.id))
            if pass == 0 { originalIDs = ids } else { #expect(ids == originalIDs) }
            let records = try context.fetch(FetchDescriptor<ImportRecord>())
            let latest = try #require(records.max { $0.importedAt < $1.importedAt })
            #expect(latest.needsReviewSubscriptionCount == 1)
            #expect(latest.detectedSubscriptionCount == 1)
            #expect(latest.recoveredRecurringCandidateCount == 0)
        }
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
        let lastCharge = try #require(rows.last?.date)
        let followingMonth = try #require(history.calendar.date(byAdding: .month, value: 1, to: lastCharge))
        #expect(subscription.predictedNextChargeDate == history.calendar.endOfMonth(for: followingMonth))
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

    @Test(arguments: [1, 7, 11, 26, 31])
    func monthlyFixturesReachTheLatestObservedBillingCycle(_ day: Int) throws {
        let calendar = Calendar(identifier: .gregorian)
        let reference = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12)))
        let history = History(referenceDate: reference)
        for phase in [5, 20, 31] {
            let rows = history.monthly(merchant: "Netflix", day: phase, amount: "15.49")
            let latest = try #require(rows.last?.date)
            let schedule = BillingSchedule(cadence: .monthly, dates: rows.map(\.date), calendar: calendar)
            let next = try #require(schedule.next(after: latest))
            let grace = try #require(calendar.date(byAdding: .day, value: SubscriptionCadence.monthly.renewalGraceWindowDays, to: next))
            #expect(latest <= reference)
            #expect(grace >= reference)
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
        var referenceDate: Date = .now
        let calendar = Calendar(identifier: .gregorian)
        var start: Date {
            let currentMonth = calendar.dateInterval(of: .month, for: referenceDate)?.start ?? referenceDate
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
            let offset = date(month: 36, day: day) <= referenceDate ? 1 : 0
            return prices.enumerated().map { index, amount in
                Row(date: date(month: index + offset, day: day), merchant: merchant, amount: amount, currency: currency)
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

@MainActor
struct SparseOccurrenceImportTests {
    @Test(.timeLimit(.minutes(2)))
    func distantWeeklyHistoryDoesNotFillUnobservedYears() async throws {
        try await withFixture { app, context in
            let dates = try [1, 8, 15, 22].map { try date(year: 1900, month: 1, day: $0) }
            let activity = Calendar.current.date(byAdding: .day, value: -14, to: .now) ?? .now
            let rows = dates.map { csvRow(date: $0) } + [csvRow(date: activity, merchant: "Neighborhood Market", memo: "Groceries")]
            try await importCSV(rows, app: app, context: context)
            let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).filter { $0.subscriptionID == subscription.id }
            #expect(subscription.cadence == .weekly)
            #expect(subscription.status == .needsReview)
            #expect(subscription.predictedNextChargeDate == nil)
            #expect(transactions.filter { $0.subscriptionID == subscription.id }.count == 4)
            #expect(occurrences.filter { $0.matchedTransactionID != nil }.count == 4)
            #expect(occurrences.count == 4)
            #expect(occurrences.allSatisfy { $0.status == .matched })
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func ancientISOChargesRemainFourObservedCyclesOnReimport() async throws {
        try await withFixture { app, context in
            let rows = ["01", "08", "15", "22"].map {
                "0001-01-\($0)T12:00:00Z,Netflix,Streaming,Weekly subscription,-15.49,USD,Visa"
            }
            var originalID: UUID?
            for _ in 0..<2 {
                try await importCSV(rows, app: app, context: context)
                let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
                let subscription = try #require(subscriptions.first)
                let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
                let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
                    .filter { $0.subscriptionID == subscription.id }
                #expect(subscriptions.count == 1)
                #expect(subscription.cadence == .weekly)
                #expect(subscription.status == .needsReview)
                #expect(subscription.predictedNextChargeDate == nil)
                #expect(transactions.count == 4)
                #expect(transactions.allSatisfy { $0.subscriptionID == subscription.id })
                #expect(occurrences.count == 4)
                #expect(occurrences.allSatisfy { $0.status == .matched })
                if let originalID { #expect(subscription.id == originalID) } else { originalID = subscription.id }
            }
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func retainsMoreThanOneHundredEightyObservedWeeklyCycles() async throws {
        try await withFixture { app, context in
            let calendar = Calendar.current
            let last = calendar.startOfDay(for: .now)
            let dates = try (0..<190).map { index in
                try #require(calendar.date(byAdding: .day, value: -7 * (189 - index), to: last))
            }
            try await importCSV(dates.map { csvRow(date: $0) }, app: app, context: context)
            let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).filter { $0.subscriptionID == subscription.id }
            #expect(subscription.cadence == .weekly)
            #expect(transactions.filter { $0.subscriptionID == subscription.id }.count == 190)
            #expect(occurrences.filter { $0.status == .matched }.count == 190)
            #expect(Set(occurrences.compactMap(\.matchedTransactionID)) == Set(transactions.map(\.id)))
            #expect(occurrences.count == 191)
            #expect(occurrences.filter { $0.expectedDate == subscription.predictedNextChargeDate }.count == 1)
        }
    }

    @Test(arguments: ["same", "foreignAccount", "foreignCurrency", "unknown", "future"])
    func onlyObservedAccountCyclesBecomeMissed(_ scenario: String) async throws {
        try await withFixture { app, context in
            let calendar = Calendar.current
            let currentMonth = try #require(calendar.dateInterval(of: .month, for: .now)?.start)
            let start = try #require(calendar.date(byAdding: .month, value: -18, to: currentMonth))
            let charges = try (0..<4).map { index in
                let month = try #require(calendar.date(byAdding: .month, value: index, to: start))
                return try #require(calendar.date(byAdding: .day, value: 4, to: month))
            }
            let activity = try (4..<18).map { index in
                let month = try #require(calendar.date(byAdding: .month, value: index, to: start))
                return try #require(calendar.date(byAdding: .day, value: 11, to: month))
            }
            let noise = activity.map {
                csvRow(date: scenario == "future" ? .now.addingTimeInterval(86400 * 60) : $0,
                       merchant: "Neighborhood Market", memo: "Groceries",
                       account: scenario == "foreignAccount" ? "Other Card" : scenario == "unknown" ? "" : "Visa",
                       currency: scenario == "foreignCurrency" ? "EUR" : "USD")
            }
            try await importCSV(charges.map { csvRow(date: $0) } + noise, app: app, context: context)
            let subscription = try #require(try context.fetch(FetchDescriptor<Subscription>()).first)
            let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).filter { $0.subscriptionID == subscription.id }
            let missed = occurrences.filter { $0.status == .missed }
            #expect(missed.count == (scenario == "same" ? 2 : 0))
            #expect(occurrences.count == (scenario == "same" ? 6 : 4))
            #expect(subscription.status == (scenario == "same" ? .former : .needsReview))
            let datesBefore = Set(occurrences.map(\.expectedDate))
            let confidenceBefore = subscription.confidenceScore
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            let run = DetectionRun(trigger: .rebuild, transactionCount: transactions.count)
            context.insert(run)
            try await app.detector.reconcileOccurrences(for: [subscription], transactions: transactions, detectionRun: run, in: context)
            #expect(subscription.confidenceScore == confidenceBefore)
            #expect(Set(try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).map(\.expectedDate)) == datesBefore)
        }
    }

    @Test
    func annualEndingKeepsOnlyFirstWitnessedMiss() async throws {
        try await withFixture { app, context in
            let year = Calendar.current.component(.year, from: .now)
            let charges = try (0..<4).map { try date(year: year - 8 + $0, month: 1, day: 5) }
            let activity = try (0..<4).map { try date(year: year - 4 + $0, month: 2, day: 12) }
            let rows = charges.map { csvRow(date: $0, memo: "Annual subscription") } + activity.map {
                csvRow(date: $0, merchant: "Neighborhood Market", memo: "Groceries")
            }
            try await importCSV(rows, app: app, context: context)
            let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            let subscription = try #require(subscriptions.first { $0.cadence == .annual })
            let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).filter { $0.subscriptionID == subscription.id }
            #expect(subscription.status == .former)
            #expect(subscription.predictedNextChargeDate == nil)
            #expect(occurrences.filter { $0.status == .matched }.count == 4)
            #expect(occurrences.filter { $0.status == .missed }.count == 1)
            #expect(occurrences.count == 5)
        }
    }

    @Test(arguments: [SubscriptionCadence.weekly, .monthly, .annual])
    func sparseCoverageMatchesGraceBoundaries(_ cadence: SubscriptionCadence) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let anchor = try #require(calendar.date(from: cadence == .annual
            ? DateComponents(year: 2020, month: 2, day: 29)
            : cadence == .monthly ? DateComponents(year: 2020, month: 1, day: 31)
            : DateComponents(year: 2020, month: 3, day: 8)))
        let charge = NormalizedTransaction(transactionDate: anchor, transactionAmount: -15.49,
                                           merchantRaw: "Netflix", merchantNormalized: "Netflix", currency: "USD", accountName: "Visa")
        let schedule = BillingSchedule(cadence: cadence, dates: [anchor], calendar: calendar)
        let expected = try #require(schedule.date(at: 0))
        let grace = try #require(calendar.date(byAdding: .day, value: cadence.renewalGraceWindowDays, to: expected))
        let next = try #require(schedule.date(at: 1))
        let reference = next.addingTimeInterval(86400)
        for (observation, shouldObserve) in [(grace.addingTimeInterval(-1), false), (grace, true),
                                            (next, true), (next.addingTimeInterval(1), false)] {
            let transaction = NormalizedTransaction(transactionDate: observation, transactionAmount: -5,
                                                    merchantRaw: "Market", merchantNormalized: "Market",
                                                    currency: "USD", accountName: "Visa")
            let coverage = AccountObservationCoverage(transactions: [charge, transaction])
            let observed = coverage.observesMissingPayment(expected: expected, schedule: schedule,
                                                          charges: [charge], referenceDate: reference)
            let cycles = try await coverage.observedMissingCycles(schedule: schedule, charges: [charge], referenceDate: reference)
            #expect(observed == shouldObserve)
            #expect(cycles.contains(0) == observed)
            let atGrace = try await coverage.observedMissingCycles(schedule: schedule, charges: [charge], referenceDate: grace)
            #expect(atGrace.contains(0) == false)
            #expect(coverage.observesMissingPayment(expected: expected, schedule: schedule,
                                                    charges: [charge], referenceDate: grace) == false)
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func cancellationDuringOccurrenceReplacementRollsBackSavedHistory() async throws {
        try await withFixture { app, context in
            let calendar = Calendar.current
            let last = calendar.startOfDay(for: .now)
            let dates = try (0..<190).map {
                try #require(calendar.date(byAdding: .day, value: -7 * (189 - $0), to: last))
            }
            try await importCSV(dates.map { csvRow(date: $0) }, app: app, context: context)
            try context.save()
            let oldOccurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
            let oldIDs = Set(oldOccurrences.map(\.id))
            let oldEvidenceIDs = Set(try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>()).map(\.id))
            let oldLinks = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<NormalizedTransaction>()).map {
                ($0.id, $0.subscriptionID)
            })
            let autosave = context.autosaveEnabled
            var finished = false
            let rebuild = Task {
                defer { finished = true }
                _ = try await app.detector.rebuildSubscriptions(in: context)
            }
            var interruptedReplacement = false
            for _ in 0..<10_000 {
                await Task.yield()
                if finished { break }
                let currentIDs = Set(try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).map(\.id))
                if currentIDs != oldIDs {
                    interruptedReplacement = true
                    rebuild.cancel()
                    break
                }
            }
            if !interruptedReplacement { rebuild.cancel() }
            do {
                _ = try await rebuild.value
                Issue.record("Rebuild finished before cancellation interrupted occurrence replacement")
            } catch is CancellationError {
                #expect(interruptedReplacement)
            }
            #expect(context.autosaveEnabled == autosave)
            #expect(Set(try context.fetch(FetchDescriptor<SubscriptionOccurrence>()).map(\.id)) == oldIDs)
            #expect(Set(try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>()).map(\.id)) == oldEvidenceIDs)
            #expect(Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<NormalizedTransaction>()).map {
                ($0.id, $0.subscriptionID)
            }) == oldLinks)
        }
    }

    private func withFixture(_ body: @MainActor (AppModel, ModelContext) async throws -> Void) async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let suite = "TallyTests.SparseOccurrences.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.isAIGenerationDisabled = true
        let directory = FileManager.default.temporaryDirectory.appending(path: suite, directoryHint: .isDirectory)
        let app = AppModel(
            aiProviderPreferences: preferences,
            gemmaModelManager: GemmaModelManager(appSupportDirectory: directory, adoptableSourceURLs: []),
            calendarEventCleaner: { _ in }, calendarEventCleanupFailureRecorder: { _ in }
        )
        try await body(app, container.mainContext)
    }

    private func importCSV(_ rows: [String], app: AppModel, context: ModelContext) async throws {
        let text = "Date,Merchant,Category,Original Statement,Amount,Currency,Account\n" + rows.joined(separator: "\n")
        let draft = try CSVTransactionImporter().makeDraft(fileName: "synthetic-sparse-history.csv", csvText: text)
        app.importDraft = draft
        await app.commitImport(using: draft.suggestedMapping, into: context)
        try #require(app.importErrorMessage == nil)
    }

    private func csvRow(date: Date, merchant: String = "Netflix", memo: String = "Subscription",
                        account: String = "Visa", currency: String = "USD") -> String {
        "\(date.ISO8601Format()),\(merchant),\(merchant == "Netflix" ? "Streaming" : "Shopping"),\(memo),-15.49,\(currency),\(account)"
    }

    private func date(year: Int, month: Int, day: Int) throws -> Date {
        try #require(Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12)))
    }
}
