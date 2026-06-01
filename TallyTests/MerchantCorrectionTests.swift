import SwiftData
import XCTest
@testable import Tally

@MainActor
final class MerchantCorrectionTests: XCTestCase {
    func testRecordUserCorrectionUpsertsByCanonicalName() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let service = SubscriptionDetectionService()

        _ = try service.recordUserCorrection(
            canonicalName: "Notion",
            isSubscription: true,
            cadence: .monthly,
            in: context
        )
        _ = try service.recordUserCorrection(
            canonicalName: "Notion",
            isSubscription: false,
            cadence: nil,
            in: context
        )

        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.canonicalName, "Notion")
        XCTAssertEqual(corrections.first?.isSubscription, false)
        XCTAssertNil(corrections.first?.correctedCadence)
    }

    func testFalsePositiveCorrectionSuppressesRecurringCluster() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let formatter = ISO8601DateFormatter()
        let importRecord = ImportRecord(
            fileName: "studio.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

        for dateString in ["2024-01-18", "2024-02-17", "2024-03-18"] {
            let transaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(dateString)T00:00:00Z") ?? .now,
                transactionAmount: Decimal(string: "-29.00") ?? -29,
                merchantRaw: "Studio Cloud",
                merchantNormalized: "Studio Cloud",
                currency: "USD",
                category: "Software",
                memo: "Core plan",
                merchantKind: .unknown,
                merchantSubscriptionAffinity: 0.52,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.38
            context.insert(transaction)
        }

        try SubscriptionDetectionService().recordUserCorrection(
            canonicalName: "Studio Cloud",
            isSubscription: false,
            cadence: nil,
            in: context
        )

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertTrue(subscriptions.isEmpty)
    }
}
