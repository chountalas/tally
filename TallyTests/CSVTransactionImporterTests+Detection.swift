import SwiftData
import XCTest
@testable import Tally

extension CSVTransactionImporterTests {
    @MainActor
    func testSubscriptionDetectionCreatesMonthlyAndAnnualRecords() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = ImportRecord(
            fileName: "seed.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

        let spotifyDates = ["2024-01-18", "2024-02-18", "2024-03-18", "2024-04-18"]
        let dateFormatter = ISO8601DateFormatter()

        for dateString in spotifyDates {
            let transaction = NormalizedTransaction(
                transactionDate: dateFormatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-10.99") ?? -10.99,
                merchantRaw: "Spotify",
                merchantNormalized: "Spotify",
                currency: "USD",
                accountName: "Visa",
                category: "Music",
                memo: nil,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }

        for dateString in ["2023-11-12", "2024-11-12"] {
            let transaction = NormalizedTransaction(
                transactionDate: dateFormatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-119.88") ?? -119.88,
                merchantRaw: "Dropbox",
                merchantNormalized: "Dropbox",
                currency: "USD",
                accountName: "Visa",
                category: "Storage",
                memo: nil,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.94
            context.insert(transaction)
        }

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 2)
        XCTAssertEqual(subscriptions.first(where: { $0.displayName == "Spotify" })?.cadence, .monthly)
        XCTAssertEqual(subscriptions.first(where: { $0.displayName == "Dropbox" })?.cadence, .annual)
    }

    @MainActor
    func testSubscriptionDetectionIgnoresRepeatedGroceries() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = ImportRecord(
            fileName: "groceries.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

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
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.84
            transaction.merchantKind = .groceryRetailer
            transaction.merchantSubscriptionAffinity = 0.08
            context.insert(transaction)
        }

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.isEmpty)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        XCTAssertTrue(transactions.allSatisfy { $0.subscriptionID == nil })
    }

    @MainActor
    func testSubscriptionDetectionIgnoresRepeatedWellnessVisits() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = ImportRecord(
            fileName: "chiro.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

        let formatter = ISO8601DateFormatter()
        for dateString in ["2024-01-09", "2024-02-09", "2024-03-08"] {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-45.00") ?? -45,
                merchantRaw: "Example Wellness Clinic",
                merchantNormalized: "Example Wellness Clinic",
                currency: "USD",
                accountName: "Visa",
                category: "Health",
                memo: "Adjustment visit",
                merchantKind: .medicalOrWellnessProvider,
                merchantSubscriptionAffinity: 0.08,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.91
            context.insert(transaction)
        }

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
    }

    @MainActor
    func testCostcoMembershipRenewalIsDetected() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = ImportRecord(
            fileName: "costco-membership.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

        let formatter = ISO8601DateFormatter()
        for dateString in ["2023-02-15", "2024-02-15"] {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-120.00") ?? -120,
                merchantRaw: "Costco",
                merchantNormalized: "Costco",
                currency: "USD",
                accountName: "Visa",
                category: "Membership",
                memo: "Gold Membership Renewal",
                merchantKind: .membershipRetailer,
                merchantSubscriptionAffinity: 0.85,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.94
            context.insert(transaction)
        }

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.cadence, .annual)
        XCTAssertNotEqual(subscriptions.first?.status, .needsReview)
    }

    @MainActor
    func testAliasImportPreservesMerchantPriorSignals() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        context.insert(MerchantAlias(rawMerchant: "NETFLIX *123", canonicalName: "Netflix"))
        context.insert(
            MerchantClassification(
                rawMerchant: "Netflix",
                result: MerchantClassificationResult(
                    canonicalName: "Netflix",
                    serviceCategory: "Streaming",
                    merchantKind: .mediaStreaming,
                    subscriptionAffinity: 0.98,
                    confidence: 0.95
                ),
                isUserCorrected: true
            )
        )

        let importer = CSVTransactionImporter()
        let draft = try importer.makeDraft(
            fileName: "alias.csv",
            csvText: """
            Date,Merchant,Amount,Category,Memo
            2024-01-04,NETFLIX *123,-15.49,Streaming,Standard plan
            2024-02-04,NETFLIX *123,-15.49,Streaming,Standard plan
            2024-03-04,NETFLIX *123,-15.49,Streaming,Standard plan
            """
        )
        appModel.importDraft = draft

        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        XCTAssertEqual(transactions.count, 3)
        XCTAssertTrue(transactions.allSatisfy { $0.merchantNormalized == "Netflix" })
        XCTAssertTrue(transactions.allSatisfy { $0.merchantKind == .mediaStreaming })
        XCTAssertTrue(transactions.allSatisfy { $0.merchantSubscriptionAffinity >= 0.95 })
    }
}
