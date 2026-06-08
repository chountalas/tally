import SwiftData
import XCTest
@testable import Tally

extension CSVTransactionImporterTests {
    @MainActor
    func testImportDetectsSubscriptionBrandVariantsAcrossMerchantNames() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let csv = """
        Date,Merchant,Category,Account,Original Statement,Amount
        2025-11-19,Claude Ai Subscription,AI Subscriptions/Charges,Test Card A,CLAUDE.AI SUBSCRIPTION TEST MERCHANT,-20.00
        2025-12-19,Claude Ai Subscription,AI Subscriptions/Charges,Test Card A,CLAUDE.AI SUBSCRIPTION TEST MERCHANT,-20.00
        2026-01-19,Anthropic,AI Subscriptions/Charges,Test Card A,Claude.ai Subscription,-20.00
        2025-12-15,Openai,AI Subscriptions/Charges,Test Card A,OPENAI *CHATGPT SUBSCR TEST MERCHANT,-20.00
        2026-01-15,Openai,AI Subscriptions/Charges,Test Card A,OPENAI *CHATGPT SUBSCR TEST MERCHANT,-20.00
        2026-02-15,Openai,AI Subscriptions/Charges,Test Card A,OpenAI,-20.00
        2025-12-15,Notion Labs Inc,Business Subscriptions,Test Card A,NOTION LABS INC TEST,-24.00
        2026-01-15,Notion Labs Inc,Business Subscriptions,Test Card A,NOTION LABS INC TEST,-24.00
        2026-02-16,Notion,AI Subscriptions/Charges,Test Card A,Notion,-24.00
        2025-12-30,Walmart+,Subscriptions,Test Card B,WMT PLUS TEST REF 000001,-13.95
        2026-01-30,Walmart,Subscriptions,Test Card B,Walmart+ Member Test Ref 000001,-13.95
        2026-02-28,Walmart,Subscriptions,Test Card B,Walmart+ Member Test Ref 000001,-13.95
        """

        let draft = try importer.makeDraft(fileName: "brand-variants.csv", csvText: csv)
        appModel.importDraft = draft

        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        XCTAssertNil(appModel.importErrorMessage)

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.contains { $0.canonicalName == "Claude" && $0.cadence == .monthly })
        XCTAssertTrue(subscriptions.contains { $0.canonicalName == "ChatGPT" && $0.cadence == .monthly })
        XCTAssertTrue(subscriptions.contains { $0.canonicalName == "Notion" && $0.cadence == .monthly })
        XCTAssertTrue(subscriptions.contains { $0.canonicalName == "Walmart+" && $0.cadence == .monthly })
    }

    @MainActor
    func testTwoChargeHighSignalMonthlySubscriptionCanAutoConfirm() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let calendar = Calendar(identifier: .gregorian)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let previousChargeDate = calendar.date(byAdding: .month, value: -1, to: Date.now) ?? Date.now
        let latestChargeDate = Date.now

        let csv = """
        Date,Merchant,Category,Account,Original Statement,Amount
        \(formatter.string(from: previousChargeDate)),Openai,AI Subscriptions/Charges,Test Card A,OPENAI *CHATGPT SUBS TEST MERCHANT,-184.24
        \(formatter.string(from: latestChargeDate)),Openai,AI Subscriptions/Charges,Test Card A,OPENAI *CHATGPT SUBS TEST MERCHANT,-195.12
        """

        let draft = try importer.makeDraft(fileName: "recent-recurring.csv", csvText: csv)
        appModel.importDraft = draft

        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        XCTAssertNil(appModel.importErrorMessage)

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.canonicalName, "ChatGPT")
        XCTAssertEqual(subscriptions.first?.cadence, .monthly)
        XCTAssertEqual(subscriptions.first?.status, .active)
    }

    @MainActor
    func testRecurringFinancialMovementIsSuppressedInsteadOfQueuedForReview() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "transfers.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2026-01-01", amount: "-1500.00", memo: "Standard transfer to savings"),
                TransactionSeedRow(date: "2026-02-01", amount: "-1500.00", memo: "Standard transfer to savings"),
                TransactionSeedRow(date: "2026-03-01", amount: "-1500.00", memo: "Standard transfer to savings")
            ],
            config: TransactionSeedConfig(
                merchantRaw: "STANDARD TRANSFER",
                merchantNormalized: "Standard Transfer",
                category: "Transfer",
                merchantKind: .unknown,
                subscriptionAffinity: 0.32,
                confidence: 0.45
            ),
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.isEmpty)

        let summary = report.summary(for: importRecord.id)
        XCTAssertEqual(summary.detectedCount, 0)
        XCTAssertEqual(summary.needsReviewCount, 0)
        XCTAssertEqual(summary.suppressedCount, 1)
    }

    @MainActor
    func testManualRuleDoesNotLinkMixedUseMerchantPurchases() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        context.insert(
            SubscriptionReviewRule(
                canonicalName: "Amazon",
                overrideDisplayName: "Amazon Prime",
                overrideStatus: .active,
                overrideCadence: .monthly,
                overridePriceAmount: Decimal(string: "14.99"),
                overrideCategory: "Membership",
                isUserConfirmed: true
            )
        )

        let importRecord = insertImportRecord(named: "amazon-manual.csv", into: context)
        insertAmazonTransactions(
            primeDates: ["2024-01-12", "2024-02-12"],
            orderRows: [("2024-01-05", "-64.10"), ("2024-02-05", "-72.55")],
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let prime = try XCTUnwrap(subscriptions.first(where: { $0.displayName == "Amazon Prime" }))
        let linkedTransactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            .filter { $0.subscriptionID == prime.id }

        XCTAssertEqual(linkedTransactions.count, 2)
        XCTAssertTrue(linkedTransactions.allSatisfy { $0.memo == "Prime Membership" })
    }

    @MainActor
    func testAmbiguousRecurringChargesStayInReviewQueue() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "club.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2024-01-11", amount: "-19.99", memo: "Monthly charge"),
                TransactionSeedRow(date: "2024-02-11", amount: "-19.99", memo: "Monthly charge"),
                TransactionSeedRow(date: "2024-03-11", amount: "-19.99", memo: "Monthly charge")
            ],
            config: .summitClub,
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.status, .former)
        XCTAssertLessThan(subscriptions.first?.confidenceScore ?? 1, 0.9)
    }

    @MainActor
    func testLowConfidenceRecurringChargesAreSuppressed() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "misc.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2024-01-03", amount: "-18.40", memo: "Order 1042"),
                TransactionSeedRow(date: "2024-02-02", amount: "-31.75", memo: "Delivery 2819"),
                TransactionSeedRow(date: "2024-03-05", amount: "-24.10", memo: "Pickup 9012")
            ],
            config: .neighborhoodMarket,
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
    }

    @MainActor
    func testLongCancelledBorderlineRecurringChargesBecomeFormerInsteadOfReview() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "borderline.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2024-01-18", amount: "-29.00", memo: "Core plan"),
                TransactionSeedRow(date: "2024-02-17", amount: "-29.00", memo: "Core plan"),
                TransactionSeedRow(date: "2024-03-18", amount: "-29.00", memo: "Core plan")
            ],
            config: TransactionSeedConfig(
                merchantRaw: "Studio Cloud",
                merchantNormalized: "Studio Cloud",
                category: "Software",
                merchantKind: .unknown,
                subscriptionAffinity: 0.52,
                confidence: 0.38
            ),
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.status, .former)
        XCTAssertEqual(subscriptions.first?.libraryState, .inactive)
        XCTAssertLessThan(subscriptions.first?.confidenceScore ?? 1, 0.9)
        XCTAssertEqual(report.summary(for: importRecord.id).needsReviewCount, 0)
    }

    @MainActor
    func testRecentBorderlineRecurringChargesStillNeedReview() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let calendar = Calendar.current
        let dates = [-62, -31, -1].map { days in
            (calendar.date(byAdding: .day, value: days, to: .now) ?? .now)
                .ISO8601Format(.iso8601Date(timeZone: .gmt))
        }
        let importRecord = insertImportRecord(named: "recent-borderline.csv", into: context)
        insertTransactions(
            rows: dates.map {
                TransactionSeedRow(date: $0, amount: "-29.00", memo: "Core plan")
            },
            config: TransactionSeedConfig(
                merchantRaw: "Studio Cloud",
                merchantNormalized: "Studio Cloud",
                category: "Software",
                merchantKind: .unknown,
                subscriptionAffinity: 0.52,
                confidence: 0.38
            ),
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.status, .needsReview)
        XCTAssertEqual(report.summary(for: importRecord.id).needsReviewCount, 1)
    }

    @MainActor
    func testExplicitSubscriptionCategoryOverridesBillSuppression() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "internet-subscription.csv", into: context)
        let calendar = Calendar.current
        let dates = [-62, -31, -1].map { days in
            (calendar.date(byAdding: .day, value: days, to: .now) ?? .now)
                .ISO8601Format(.iso8601Date(timeZone: .gmt))
        }
        insertTransactions(
            rows: dates.map {
                TransactionSeedRow(date: $0, amount: "-49.99", memo: "Home internet subscription plan")
            },
            config: TransactionSeedConfig(
                merchantRaw: "Fiber Co",
                merchantNormalized: "Fiber Co",
                category: "Subscriptions",
                merchantKind: .utilityOrBiller,
                subscriptionAffinity: 0.78,
                confidence: 0.82
            ),
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertNotEqual(subscriptions.first?.status, .former)
    }

    @MainActor
    func testGenericSubstringSignalsDoNotAutoConfirmWeakSoftwareCandidate() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "weak-software.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2026-01-08", amount: "-29.00", memo: "Paid mail labels"),
                TransactionSeedRow(date: "2026-02-08", amount: "-29.00", memo: "Paid mail labels")
            ],
            config: TransactionSeedConfig(
                merchantRaw: "Daily Mail Tools",
                merchantNormalized: "Daily Mail Tools",
                category: "Software",
                merchantKind: .unknown,
                subscriptionAffinity: 0.54,
                confidence: 0.56
            ),
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertFalse(subscriptions.contains { $0.status == .active || $0.status == .former })
    }

    @MainActor
    func testGenericCloudOrPersonalWordsDoNotProtectRetailNoiseFromSuppression() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "cloud-paper.csv", into: context)
        insertTransactions(
            rows: [
                TransactionSeedRow(date: "2026-01-12", amount: "-40.00", memo: "Paper order"),
                TransactionSeedRow(date: "2026-02-12", amount: "-40.00", memo: "Paper order"),
                TransactionSeedRow(date: "2026-03-12", amount: "-40.00", memo: "Paper order")
            ],
            config: TransactionSeedConfig(
                merchantRaw: "Cloud Paper",
                merchantNormalized: "Cloud Paper",
                category: "House Supplies",
                merchantKind: .generalRetail,
                subscriptionAffinity: 0.22,
                confidence: 0.58
            ),
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
        XCTAssertGreaterThanOrEqual(report.summary(for: importRecord.id).suppressedCount, 1)
    }

    @MainActor
    func testFallbackRecoverySurfacesFragmentedAmountsForReview() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "fragmented.csv", into: context)
        let calendar = Calendar.current
        let olderCharge = calendar.date(byAdding: .day, value: -44, to: .now) ?? .now
        let newerCharge = calendar.date(byAdding: .day, value: -14, to: .now) ?? .now
        insertTransactions(
            rows: [
                TransactionSeedRow(date: olderCharge.ISO8601Format(.iso8601Date(timeZone: .gmt)), amount: "-10.00", memo: "Premium membership"),
                TransactionSeedRow(date: newerCharge.ISO8601Format(.iso8601Date(timeZone: .gmt)), amount: "-14.00", memo: "Premium membership")
            ],
            config: TransactionSeedConfig(
                merchantRaw: "Flex Membership",
                merchantNormalized: "Flex Membership",
                category: "Membership",
                merchantKind: .subscriptionService,
                subscriptionAffinity: 0.92,
                confidence: 0.93
            ),
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.status, .needsReview)

        let summary = report.summary(for: importRecord.id)
        XCTAssertEqual(summary.detectedCount, 0)
        XCTAssertEqual(summary.needsReviewCount, 1)
        XCTAssertEqual(summary.recoveredCount, 0)
    }

    @MainActor
    func testRecentHighSignalSingleChargeBecomesReviewCandidateWithPredictedRenewal() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "recent-purchase.csv", into: context)
        let chargeDate = Calendar.current.date(byAdding: .day, value: -11, to: .now) ?? .now
        insertTransaction(
            date: chargeDate,
            amount: "-19.99",
            merchantRaw: "OPENAI *CHATGPT",
            merchantNormalized: "ChatGPT",
            category: "AI Subscriptions/Charges",
            memo: "ChatGPT Plus monthly subscription",
            merchantKind: .softwareOrSaaS,
            subscriptionAffinity: 0.98,
            confidence: 0.95,
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let subscription = try XCTUnwrap(subscriptions.first)
        let nextChargeDate = try XCTUnwrap(subscription.predictedNextChargeDate)

        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscription.canonicalName, "ChatGPT")
        XCTAssertEqual(subscription.status, .needsReview)
        XCTAssertEqual(subscription.cadence, .monthly)
        XCTAssertTrue(Calendar.current.isDate(subscription.lastChargeDate ?? .distantPast, inSameDayAs: chargeDate))
        XCTAssertTrue(Calendar.current.isDate(subscription.firstChargeDate ?? .distantPast, inSameDayAs: chargeDate))
        XCTAssertGreaterThan(nextChargeDate, chargeDate)
        XCTAssertEqual(report.summary(for: importRecord.id).needsReviewCount, 1)
        XCTAssertEqual(report.clusters.first?.source, .recentPurchase)
    }

    @MainActor
    func testLowSignalSingleChargeDoesNotCreateSubscriptionCandidate() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "recent-shopping.csv", into: context)
        insertTransaction(
            date: Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .now,
            amount: "-42.18",
            merchantRaw: "NEIGHBORHOOD MARKET",
            merchantNormalized: "Neighborhood Market",
            category: "Shopping",
            memo: "Order 1042",
            merchantKind: .generalRetail,
            subscriptionAffinity: 0.14,
            confidence: 0.72,
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
        XCTAssertEqual(report.summary(for: importRecord.id).needsReviewCount, 0)
    }

    @MainActor
    func testManualBillingAnchorPersistsAcrossDetectionRefresh() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let billingAnchor = Calendar.current.date(byAdding: .day, value: -9, to: .now) ?? .now
        context.insert(
            SubscriptionReviewRule(
                canonicalName: "Superhuman",
                overrideDisplayName: "Superhuman",
                overrideStatus: .active,
                overrideCadence: .monthly,
                overridePriceAmount: Decimal(string: "40.00"),
                overrideLastChargeDate: billingAnchor,
                overrideCategory: "Software",
                isUserConfirmed: true
            )
        )

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()
        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let subscription = try XCTUnwrap(subscriptions.first(where: { $0.canonicalName == "Superhuman" }))
        let nextChargeDate = try XCTUnwrap(subscription.predictedNextChargeDate)
        let expectedNextCharge = Calendar.current.date(byAdding: .month, value: 1, to: billingAnchor) ?? billingAnchor

        XCTAssertEqual(subscription.status, .active)
        XCTAssertTrue(Calendar.current.isDate(subscription.lastChargeDate ?? .distantPast, inSameDayAs: billingAnchor))
        XCTAssertTrue(Calendar.current.isDate(nextChargeDate, inSameDayAs: expectedNextCharge))
    }

    @MainActor
    func testSubscriptionDetectionSeparatesRecurringClusterFromMerchantShopping() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertImportRecord(named: "amazon.csv", into: context)
        insertAmazonTransactions(
            primeDates: ["2024-01-12", "2024-02-12", "2024-03-12"],
            orderRows: [("2024-01-05", "-62.34"), ("2024-02-06", "-81.10"), ("2024-03-09", "-47.28")],
            importRecordID: importRecord.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.displayName, "Amazon Prime")
        XCTAssertEqual(subscriptions.first?.cadence, .monthly)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let linkedTransactions = transactions.filter { $0.subscriptionID == subscriptions.first?.id }
        XCTAssertEqual(linkedTransactions.count, 3)
        XCTAssertTrue(linkedTransactions.allSatisfy { $0.memo == "Prime Membership" })
    }
}

private struct TransactionSeedRow {
    let date: String
    let amount: String
    let memo: String
}

private struct TransactionSeedConfig {
    let merchantRaw: String
    let merchantNormalized: String
    let category: String
    let merchantKind: MerchantKind
    let subscriptionAffinity: Double
    let confidence: Double

    static let summitClub = TransactionSeedConfig(
        merchantRaw: "Summit Club",
        merchantNormalized: "Summit Club",
        category: "Uncategorized",
        merchantKind: .unknown,
        subscriptionAffinity: 0.55,
        confidence: 0.72
    )

    static let neighborhoodMarket = TransactionSeedConfig(
        merchantRaw: "Neighborhood Market",
        merchantNormalized: "Neighborhood Market",
        category: "Shopping",
        merchantKind: .generalRetail,
        subscriptionAffinity: 0.12,
        confidence: 0.7
    )
}

private extension CSVTransactionImporterTests {
    func insertImportRecord(named fileName: String, into context: ModelContext) -> ImportRecord {
        let importRecord = ImportRecord(
            fileName: fileName,
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)
        return importRecord
    }

    func insertAmazonTransactions(
        primeDates: [String],
        orderRows: [(String, String)],
        importRecordID: UUID,
        into context: ModelContext
    ) {
        insertTransactions(
            rows: primeDates.map {
                TransactionSeedRow(date: $0, amount: "-14.99", memo: "Prime Membership")
            },
            config: TransactionSeedConfig(
                merchantRaw: "Amazon",
                merchantNormalized: "Amazon",
                category: "Shopping",
                merchantKind: .subscriptionService,
                subscriptionAffinity: 0.94,
                confidence: 0.92
            ),
            importRecordID: importRecordID,
            into: context
        )
        insertTransactions(
            rows: orderRows.map {
                TransactionSeedRow(date: $0.0, amount: $0.1, memo: "Marketplace order")
            },
            config: TransactionSeedConfig(
                merchantRaw: "Amazon",
                merchantNormalized: "Amazon",
                category: "Shopping",
                merchantKind: .marketplace,
                subscriptionAffinity: 0.1,
                confidence: 0.92
            ),
            importRecordID: importRecordID,
            into: context
        )
    }

    func insertTransactions(
        rows: [TransactionSeedRow],
        config: TransactionSeedConfig,
        importRecordID: UUID,
        into context: ModelContext
    ) {
        for row in rows {
            insertTransaction(
                date: ISO8601DateFormatter().date(from: "\(row.date)T00:00:00Z") ?? .now,
                amount: row.amount,
                merchantRaw: config.merchantRaw,
                merchantNormalized: config.merchantNormalized,
                category: config.category,
                memo: row.memo,
                merchantKind: config.merchantKind,
                subscriptionAffinity: config.subscriptionAffinity,
                confidence: config.confidence,
                importRecordID: importRecordID,
                into: context
            )
        }
    }

    func insertTransaction(
        date: Date,
        amount: String,
        merchantRaw: String,
        merchantNormalized: String,
        category: String,
        memo: String,
        merchantKind: MerchantKind,
        subscriptionAffinity: Double,
        confidence: Double,
        importRecordID: UUID,
        into context: ModelContext
    ) {
        let transaction = NormalizedTransaction(
            transactionDate: date,
            transactionAmount: Decimal(string: amount) ?? 0,
            merchantRaw: merchantRaw,
            merchantNormalized: merchantNormalized,
            currency: "USD",
            accountName: "Visa",
            category: category,
            memo: memo,
            merchantKind: merchantKind,
            merchantSubscriptionAffinity: subscriptionAffinity,
            importRecordID: importRecordID
        )
        transaction.classificationConfidence = confidence
        context.insert(transaction)
    }
}
