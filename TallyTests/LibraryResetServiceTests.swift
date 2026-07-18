import SwiftData
import XCTest
@testable import Tally

@MainActor
final class LibraryResetServiceTests: XCTestCase {
    func testImportRecordPreservesTypedFileFormatAsRawValue() {
        let record = ImportRecord(
            fileName: "statement.xlsx",
            fileFormat: .xlsx,
            status: .queued,
            mappingSignature: "test"
        )

        XCTAssertEqual(record.fileFormat, .xlsx)
        XCTAssertEqual(record.sourceType, "xlsx")
    }

    /// A full reset must clear every library-owned model. If any store is left
    /// behind, previously-suppressed merchants stay suppressed and dedup ghosts
    /// persist after the user asks for a clean slate.
    func testClearLibraryDeletesAllModelTypes() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        seedOneOfEachModel(in: context)
        try context.save()

        let summary = try LibraryResetService().clearLibrary(in: context, includeTemplates: true)

        XCTAssertEqual(summary.importCount, 1)
        XCTAssertEqual(summary.subscriptionCount, 1)
        XCTAssertEqual(summary.transactionCount, 1)
        XCTAssertEqual(summary.templateCount, 1)

        try assertStoreEmpty(ImportRecord.self, in: context)
        try assertStoreEmpty(ColumnMappingTemplate.self, in: context)
        try assertStoreEmpty(MerchantClassification.self, in: context)
        try assertStoreEmpty(MerchantCorrection.self, in: context)
        try assertStoreEmpty(MerchantAlias.self, in: context)
        try assertStoreEmpty(NormalizedTransaction.self, in: context)
        try assertStoreEmpty(Subscription.self, in: context)
        try assertStoreEmpty(SubscriptionReviewRule.self, in: context)
        try assertStoreEmpty(ManualSubscription.self, in: context)
        try assertStoreEmpty(SourceTransactionIdentity.self, in: context)
        try assertStoreEmpty(MerchantIdentity.self, in: context)
        try assertStoreEmpty(MerchantIdentityMember.self, in: context)
        try assertStoreEmpty(ServiceProfile.self, in: context)
        try assertStoreEmpty(SubscriptionScheduleExpectation.self, in: context)
        try assertStoreEmpty(SubscriptionMatchRule.self, in: context)
        try assertStoreEmpty(SubscriptionOccurrence.self, in: context)
        try assertStoreEmpty(SubscriptionDetectionEvidence.self, in: context)
        try assertStoreEmpty(DetectionRun.self, in: context)
    }

    /// Without `includeTemplates`, saved column mappings survive so a plain
    /// "clear imported data" doesn't force the user to re-map their bank's CSV,
    /// while every other learning store is still wiped.
    func testClearLibraryKeepsTemplatesWhenNotIncluded() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        seedOneOfEachModel(in: context)
        try context.save()

        _ = try LibraryResetService().clearLibrary(in: context, includeTemplates: false)

        let templates = try context.fetch(FetchDescriptor<ColumnMappingTemplate>())
        XCTAssertEqual(templates.count, 1)

        try assertStoreEmpty(MerchantCorrection.self, in: context)
        try assertStoreEmpty(SubscriptionMatchRule.self, in: context)
        try assertStoreEmpty(Subscription.self, in: context)
    }

    func testClearLibraryQueuesCalendarCleanupWhenAccessDenied() throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        seedOneOfEachModel(in: context)
        let subscription = try XCTUnwrap(try context.fetch(FetchDescriptor<Subscription>()).first)
        subscription.calendarEventIdentifier = "event-to-clear-after-reset"
        try context.save()

        var recordedPendingIDs: [String] = []
        let service = LibraryResetService(
            calendarEventCleaner: { _, _ in
                throw RenewalCalendarError.accessDenied
            },
            pendingCalendarEventRecorder: { identifiers in
                recordedPendingIDs.append(contentsOf: identifiers)
            }
        )

        _ = try service.clearLibrary(in: context, includeTemplates: false)

        XCTAssertEqual(recordedPendingIDs, ["event-to-clear-after-reset"])
        try assertStoreEmpty(Subscription.self, in: context)
    }

    // MARK: Helpers

    private func assertStoreEmpty<T: PersistentModel>(
        _ type: T.Type,
        in context: ModelContext,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let count = try context.fetch(FetchDescriptor<T>()).count
        XCTAssertEqual(count, 0, "\(T.self) store should be empty after reset", file: file, line: line)
    }

    private func seedOneOfEachModel(in context: ModelContext) {
        let subscriptionID = UUID()

        context.insert(ImportRecord(
            fileName: "seed.csv",
            fileFormat: .csv,
            status: .analyzed,
            mappingSignature: "seed"
        ))
        context.insert(ColumnMappingTemplate(config: ColumnMappingConfig(
            dateColumn: "Date",
            descriptionColumn: "Description",
            amountColumn: "Amount",
            merchantColumn: "Merchant",
            categoryColumn: nil,
            accountColumn: nil,
            currencyColumn: nil,
            debitSignConvention: .negative
        )))
        context.insert(MerchantClassification(
            rawMerchant: "Studio Cloud",
            result: MerchantClassificationResult(
                canonicalName: "Studio Cloud",
                serviceCategory: "Software",
                merchantKind: .unknown,
                subscriptionAffinity: 0.5,
                confidence: 0.5
            )
        ))
        context.insert(MerchantCorrection(canonicalName: "Studio Cloud", isSubscription: false))
        context.insert(MerchantAlias(rawMerchant: "STUDIO*CLOUD", canonicalName: "Studio Cloud"))
        context.insert(NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(-29),
            merchantRaw: "Studio Cloud",
            merchantNormalized: "Studio Cloud",
            currency: "USD",
            subscriptionID: subscriptionID
        ))
        context.insert(Subscription(
            id: subscriptionID,
            canonicalName: "Studio Cloud",
            displayName: "Studio Cloud",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(29),
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(29),
            lastChargeDate: .now,
            predictedNextChargeDate: .now,
            confidenceScore: 0.9
        ))
        context.insert(SubscriptionReviewRule(canonicalName: "Studio Cloud", isFalsePositive: true))
        context.insert(ManualSubscription(subscriptionID: subscriptionID))
        context.insert(SourceTransactionIdentity(sourceFingerprint: "fingerprint"))
        context.insert(MerchantIdentity(canonicalName: "Studio Cloud"))
        context.insert(MerchantIdentityMember(
            merchantIdentityID: UUID(),
            rawMerchant: "Studio Cloud",
            normalizedMerchant: "Studio Cloud"
        ))
        context.insert(ServiceProfile(canonicalName: "Studio Cloud"))
        context.insert(SubscriptionScheduleExpectation(subscriptionID: subscriptionID, cadence: .monthly))
        context.insert(SubscriptionMatchRule(canonicalName: "Studio Cloud"))
        context.insert(SubscriptionOccurrence(
            subscriptionID: subscriptionID,
            expectedDate: .now,
            windowStartDate: .now,
            windowEndDate: .now,
            status: .pending
        ))
        context.insert(SubscriptionDetectionEvidence(
            candidateKey: "studio-cloud",
            decision: .needsReview,
            confidence: 0.5,
            deterministicScore: 0.5,
            reason: "seed"
        ))
        context.insert(DetectionRun(trigger: .rebuild))
    }
}
