import SwiftData
import XCTest
@testable import Tally

extension CSVTransactionImporterTests {
    @MainActor
    func testRefreshSubscriptionAnalysisClearsExistingFalsePositiveGroceries() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let staleClassificationDate =
            ISO8601DateFormatter().date(from: "2024-01-01T00:00:00Z") ?? .distantPast
        let staleClassification = makeStaleCostcoClassification(lastUpdatedAt: staleClassificationDate)
        context.insert(staleClassification)

        let staleSubscription = makeStaleCostcoSubscription()
        context.insert(staleSubscription)

        let importRecord = insertSeedImportRecord(named: "groceries.csv", into: context)
        insertCostcoGroceryTransactions(
            importRecordID: importRecord.id,
            staleSubscriptionID: staleSubscription.id,
            into: context
        )

        try context.save()

        await appModel.refreshSubscriptionAnalysis(in: context)

        XCTAssertNil(appModel.importErrorMessage)
        XCTAssertEqual(appModel.infoMessage, "Refreshed subscription analysis for 3 transactions.")

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.isEmpty)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        XCTAssertTrue(transactions.allSatisfy { $0.subscriptionID == nil })
        XCTAssertTrue(transactions.allSatisfy { $0.merchantSubscriptionAffinity < 0.3 })
        XCTAssertTrue(transactions.allSatisfy { $0.category == "Groceries" })

        let refreshedClassification = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<MerchantClassification>(
                    predicate: #Predicate { $0.rawMerchant == "Costco" }
                )
            ).first
        )
        XCTAssertEqual(refreshedClassification.serviceCategory, "Groceries")
        XCTAssertEqual(refreshedClassification.merchantKind, .groceryRetailer)
        XCTAssertLessThan(refreshedClassification.subscriptionAffinity, 0.5)
        XCTAssertGreaterThan(refreshedClassification.lastUpdatedAt, staleClassificationDate)
    }

    @MainActor
    func testImportReclassifiesStaleCachedMerchantClassification() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        context.insert(
            MerchantClassification(
                rawMerchant: "Netflix",
                result: MerchantClassificationResult(
                    canonicalName: "Netflix",
                    serviceCategory: "Retail",
                    merchantKind: .generalRetail,
                    subscriptionAffinity: 0.15,
                    confidence: 0.92
                ),
                lastUpdatedAt: .now
            )
        )
        try context.save()

        let csv = """
        Date,Merchant,Amount,Category
        2025-01-04,Netflix,-15.49,Streaming
        2025-02-04,Netflix,-15.49,Streaming
        2025-03-04,Netflix,-15.49,Streaming
        """

        let draft = try importer.makeDraft(fileName: "stale-cache.csv", csvText: csv)
        appModel.importDraft = draft

        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        XCTAssertNil(appModel.importErrorMessage)

        let refreshedClassification = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<MerchantClassification>(
                    predicate: #Predicate { $0.rawMerchant == "Netflix" }
                )
            ).first
        )
        XCTAssertEqual(refreshedClassification.serviceCategory, "Streaming")
        XCTAssertEqual(refreshedClassification.merchantKind, .mediaStreaming)
        XCTAssertGreaterThan(refreshedClassification.subscriptionAffinity, 0.8)
        XCTAssertGreaterThan(refreshedClassification.classifierVersion, 0)

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.canonicalName, "Netflix")
    }

    @MainActor
    func testRefreshSubscriptionAnalysisReusesHealthyCachedClassification() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let cachedAt = ISO8601DateFormatter().date(from: "2026-05-01T00:00:00Z") ?? .distantPast
        context.insert(
            MerchantClassification(
                rawMerchant: "Netflix",
                result: MerchantClassificationResult(
                    canonicalName: "Netflix",
                    serviceCategory: "Streaming",
                    merchantKind: .mediaStreaming,
                    subscriptionAffinity: 0.96,
                    confidence: 0.97
                ),
                classifierVersion: 2,
                lastUpdatedAt: cachedAt
            )
        )

        let importRecord = insertSeedImportRecord(named: "healthy-cache.csv", into: context)
        insertNetflixTransactions(
            rows: [
                NetflixTransactionSeed(
                    date: "2025-01-04",
                    rawMerchant: "Netflix",
                    confidence: 0.97
                ),
                NetflixTransactionSeed(
                    date: "2025-02-04",
                    rawMerchant: "Netflix",
                    confidence: 0.97
                ),
                NetflixTransactionSeed(
                    date: "2025-03-04",
                    rawMerchant: "Netflix",
                    confidence: 0.97
                )
            ],
            importRecordID: importRecord.id,
            into: context
        )
        try context.save()

        await appModel.refreshSubscriptionAnalysis(in: context)

        XCTAssertNil(appModel.importErrorMessage)

        let reusedClassification = try XCTUnwrap(
            context.fetch(
                FetchDescriptor<MerchantClassification>(
                    predicate: #Predicate { $0.rawMerchant == "Netflix" }
                )
            ).first
        )
        XCTAssertEqual(reusedClassification.lastUpdatedAt, cachedAt)
        XCTAssertEqual(reusedClassification.classifierVersion, 2)

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.canonicalName, "Netflix")
    }

    @MainActor
    func testSubscriptionReviewRulesPersistAcrossRebuilds() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertSeedImportRecord(named: "seed.csv", into: context)
        insertNetflixSeedTransactions(
            importRecordID: importRecord.id,
            rawMerchant: "NETFLIX *123",
            into: context
        )

        let rule = makeNetflixPremiumRule()
        context.insert(rule)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        var subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.displayName, "Netflix Premium")
        XCTAssertEqual(subscriptions.first?.cadence, .annual)
        XCTAssertEqual(subscriptions.first?.priceAmount, Decimal(string: "185.88"))
        XCTAssertEqual(subscriptions.first?.isUserConfirmed, true)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.displayName, "Netflix Premium")
        XCTAssertEqual(subscriptions.first?.notes, "Confirmed annual billing")

        rule.isFalsePositive = true
        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.isEmpty)
    }

    @MainActor
    func testSubscriptionReviewRulesPersistAfterReimport() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = insertSeedImportRecord(named: "seed.csv", into: context)
        insertNetflixSeedTransactions(
            importRecordID: importRecord.id,
            rawMerchant: "NETFLIX *123",
            into: context
        )

        let rule = makeNetflixPremiumRule()
        context.insert(rule)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let secondImport = insertSeedImportRecord(named: "seed-2.csv", into: context)
        insertNetflixTransactions(
            rows: [
                NetflixTransactionSeed(
                    date: "2025-03-04",
                    rawMerchant: "NETFLIX *456",
                    confidence: 0.97
                )
            ],
            importRecordID: secondImport.id,
            into: context
        )

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let netflix = try XCTUnwrap(subscriptions.first)
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(netflix.displayName, "Netflix Premium")
        XCTAssertEqual(netflix.cadence, .annual)
        XCTAssertEqual(netflix.priceAmount, Decimal(string: "185.88"))
        XCTAssertEqual(netflix.notes, "Confirmed annual billing")

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        XCTAssertEqual(transactions.filter { $0.subscriptionID == netflix.id }.count, 4)
    }

    @MainActor
    func testManualReviewRuleCreatesStandaloneSubscriptionAndSurvivesRebuild() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        context.insert(
            SubscriptionReviewRule(
                canonicalName: "Linear",
                overrideStatus: .active,
                overrideCadence: .monthly,
                overridePriceAmount: Decimal(string: "14.00"),
                overrideCategory: "Software",
                notes: "Manually added",
                isUserConfirmed: true
            )
        )

        let importRecord = insertSeedImportRecord(named: "seed.csv", into: context)
        insertSpotifySeedTransactions(importRecordID: importRecord.id, into: context)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 2)

        let manual = try XCTUnwrap(subscriptions.first(where: { $0.canonicalName == "Linear" }))
        XCTAssertEqual(manual.displayName, "Linear")
        XCTAssertEqual(manual.cadence, .monthly)
        XCTAssertEqual(manual.status, .active)
        XCTAssertEqual(manual.priceAmount, Decimal(string: "14.00"))
        XCTAssertEqual(manual.serviceCategory, "Software")
        XCTAssertEqual(manual.notes, "Manually added")
        XCTAssertEqual(manual.confidenceScore, 1)
        XCTAssertNil(manual.lastChargeDate)
        XCTAssertNil(manual.predictedNextChargeDate)
    }
}

private extension CSVTransactionImporterTests {
    struct NetflixTransactionSeed {
        let date: String
        let rawMerchant: String
        let confidence: Double
    }

    func insertSeedImportRecord(named fileName: String, into context: ModelContext) -> ImportRecord {
        let importRecord = ImportRecord(
            fileName: fileName,
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)
        return importRecord
    }

    func makeStaleCostcoClassification(lastUpdatedAt: Date) -> MerchantClassification {
        MerchantClassification(
            rawMerchant: "Costco",
            result: MerchantClassificationResult(
                canonicalName: "Costco",
                serviceCategory: "Membership",
                merchantKind: .membershipRetailer,
                subscriptionAffinity: 0.8,
                confidence: 0.95
            ),
            lastUpdatedAt: lastUpdatedAt
        )
    }

    func makeStaleCostcoSubscription() -> Subscription {
        Subscription(
            canonicalName: "Costco",
            displayName: "Costco",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(string: "89.99") ?? 89.99,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "89.99") ?? 89.99,
            lastChargeDate: ISO8601DateFormatter().date(from: "2024-03-06T00:00:00Z"),
            predictedNextChargeDate: ISO8601DateFormatter().date(from: "2024-04-06T00:00:00Z"),
            confidenceScore: 0.91,
            serviceCategory: "Membership"
        )
    }

    func insertCostcoGroceryTransactions(
        importRecordID: UUID,
        staleSubscriptionID: UUID,
        into context: ModelContext
    ) {
        let formatter = ISO8601DateFormatter()

        for (dateString, amount) in [
            ("2024-01-05", "-86.42"),
            ("2024-02-04", "-112.19"),
            ("2024-03-06", "-74.63")
        ] {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: amount) ?? -50,
                merchantRaw: "Costco",
                merchantNormalized: "Costco",
                currency: "USD",
                accountName: "Visa",
                category: "Groceries",
                memo: "Warehouse trip",
                merchantKind: .membershipRetailer,
                merchantSubscriptionAffinity: 0.8,
                importRecordID: importRecordID,
                subscriptionID: staleSubscriptionID
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }
    }

    func makeNetflixPremiumRule() -> SubscriptionReviewRule {
        SubscriptionReviewRule(
            canonicalName: "Netflix",
            overrideDisplayName: "Netflix Premium",
            overrideStatus: .active,
            overrideCadence: .annual,
            overridePriceAmount: Decimal(string: "185.88"),
            overrideCategory: "Streaming",
            notes: "Confirmed annual billing",
            isFalsePositive: false,
            isUserConfirmed: true
        )
    }

    func insertNetflixSeedTransactions(
        importRecordID: UUID,
        rawMerchant: String,
        into context: ModelContext
    ) {
        insertNetflixTransactions(
            rows: [
                NetflixTransactionSeed(date: "2024-01-04", rawMerchant: rawMerchant, confidence: 0.95),
                NetflixTransactionSeed(date: "2024-02-04", rawMerchant: rawMerchant, confidence: 0.95),
                NetflixTransactionSeed(date: "2024-03-04", rawMerchant: rawMerchant, confidence: 0.95)
            ],
            importRecordID: importRecordID,
            into: context
        )
    }

    func insertSpotifySeedTransactions(importRecordID: UUID, into context: ModelContext) {
        let formatter = ISO8601DateFormatter()

        for dateString in ["2024-01-18", "2024-02-18", "2024-03-18"] {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-10.99") ?? -10.99,
                merchantRaw: "Spotify",
                merchantNormalized: "Spotify",
                currency: "USD",
                accountName: "Visa",
                category: "Music",
                memo: nil,
                importRecordID: importRecordID
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }
    }

    func insertNetflixTransactions(
        rows: [NetflixTransactionSeed],
        importRecordID: UUID,
        into context: ModelContext
    ) {
        let formatter = ISO8601DateFormatter()

        for row in rows {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(row.date)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-15.49") ?? -15.49,
                merchantRaw: row.rawMerchant,
                merchantNormalized: "Netflix",
                currency: "USD",
                accountName: "Visa",
                category: "Streaming",
                memo: "Plan",
                importRecordID: importRecordID
            )
            transaction.classificationConfidence = row.confidence
            context.insert(transaction)
        }
    }
}
