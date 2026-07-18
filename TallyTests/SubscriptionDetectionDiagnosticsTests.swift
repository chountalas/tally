import SwiftData
import XCTest
@testable import Tally

final class SubscriptionDetectionDiagnosticsTests: XCTestCase {
    private let diagnosticsFlagPath = NSTemporaryDirectory() + "subscription-diagnostics.flag"

    @MainActor
    func testPrintDetectionDiagnosticsFixtures() async throws {
        guard FileManager.default.fileExists(atPath: diagnosticsFlagPath) else {
            throw XCTSkip("Create the diagnostics flag file to run diagnostics output.")
        }

        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let importRecord = ImportRecord(
            fileName: "diagnostics.csv",
            fileFormat: .csv,
            status: .analyzed,
            mappingSignature: "diagnostics"
        )
        context.insert(importRecord)

        insertTransaction(
            date: isoDate("2026-01-08T00:00:00Z"),
            amount: "-19.99",
            merchantRaw: "OPENAI *CHATGPT",
            merchantNormalized: "ChatGPT",
            category: "AI Subscriptions/Charges",
            memo: "ChatGPT Plus",
            merchantKind: .softwareOrSaaS,
            subscriptionAffinity: 0.98,
            confidence: 0.95,
            importRecordID: importRecord.id,
            into: context
        )
        insertTransaction(
            date: isoDate("2026-02-08T00:00:00Z"),
            amount: "-19.99",
            merchantRaw: "OPENAI *CHATGPT",
            merchantNormalized: "ChatGPT",
            category: "AI Subscriptions/Charges",
            memo: "ChatGPT Plus",
            merchantKind: .softwareOrSaaS,
            subscriptionAffinity: 0.98,
            confidence: 0.95,
            importRecordID: importRecord.id,
            into: context
        )
        insertTransaction(
            date: isoDate("2026-03-08T00:00:00Z"),
            amount: "-19.99",
            merchantRaw: "OPENAI *CHATGPT",
            merchantNormalized: "ChatGPT",
            category: "AI Subscriptions/Charges",
            memo: "ChatGPT Plus",
            merchantKind: .softwareOrSaaS,
            subscriptionAffinity: 0.98,
            confidence: 0.95,
            importRecordID: importRecord.id,
            into: context
        )

        insertTransaction(
            date: Calendar.current.date(byAdding: .day, value: -12, to: .now) ?? .now,
            amount: "-12.99",
            merchantRaw: "YOUTUBE",
            merchantNormalized: "YouTube",
            category: "Streaming",
            memo: "YouTube Premium",
            merchantKind: .mediaStreaming,
            subscriptionAffinity: 0.94,
            confidence: 0.91,
            importRecordID: importRecord.id,
            into: context
        )

        insertTransaction(
            date: isoDate("2026-01-03T00:00:00Z"),
            amount: "-18.40",
            merchantRaw: "NEIGHBORHOOD MARKET",
            merchantNormalized: "Neighborhood Market",
            category: "Shopping",
            memo: "Order 1042",
            merchantKind: .generalRetail,
            subscriptionAffinity: 0.12,
            confidence: 0.72,
            importRecordID: importRecord.id,
            into: context
        )
        insertTransaction(
            date: isoDate("2026-02-02T00:00:00Z"),
            amount: "-31.75",
            merchantRaw: "NEIGHBORHOOD MARKET",
            merchantNormalized: "Neighborhood Market",
            category: "Shopping",
            memo: "Delivery 2819",
            merchantKind: .generalRetail,
            subscriptionAffinity: 0.12,
            confidence: 0.72,
            importRecordID: importRecord.id,
            into: context
        )
        insertTransaction(
            date: isoDate("2026-03-05T00:00:00Z"),
            amount: "-24.10",
            merchantRaw: "NEIGHBORHOOD MARKET",
            merchantNormalized: "Neighborhood Market",
            category: "Shopping",
            memo: "Pickup 9012",
            merchantKind: .generalRetail,
            subscriptionAffinity: 0.12,
            confidence: 0.72,
            importRecordID: importRecord.id,
            into: context
        )

        let report = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let clusters = report.clusters.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        print("=== Detection diagnostics ===")
        for cluster in clusters {
            print(
                [
                    cluster.status.debugLabel,
                    "source=\(cluster.source.debugLabel)",
                    "name=\(cluster.displayName)",
                    "reason=\(cluster.reason ?? "none")"
                ].joined(separator: " | ")
            )
        }
        for subscription in subscriptions {
            print(
                [
                    "SUBSCRIPTION",
                    "name=\(subscription.displayName)",
                    "status=\(subscription.status.rawValue)",
                    "cadence=\(subscription.cadence.rawValue)",
                    "next=\(subscription.predictedNextChargeDate?.ISO8601Format() ?? "none")"
                ].joined(separator: " | ")
            )
        }
    }
}

private extension SubscriptionDetectionDiagnosticsTests {
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
            accountName: "Diagnostics",
            category: category,
            memo: memo,
            merchantKind: merchantKind,
            merchantSubscriptionAffinity: subscriptionAffinity,
            importRecordID: importRecordID
        )
        transaction.classificationConfidence = confidence
        context.insert(transaction)
    }

    func isoDate(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value) ?? .now
    }
}

private extension SubscriptionDetectionClusterStatus {
    var debugLabel: String {
        switch self {
        case .detected:
            return "DETECTED"
        case .needsReview:
            return "REVIEW"
        case .suppressed:
            return "SUPPRESSED"
        }
    }
}

private extension SubscriptionDetectionSource {
    var debugLabel: String {
        switch self {
        case .primary:
            return "primary"
        case .fallback:
            return "fallback"
        case .recentPurchase:
            return "recentPurchase"
        }
    }
}
