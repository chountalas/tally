import SwiftData
import XCTest
@testable import Tally

@MainActor
final class UnifiedSubscriptionLibraryTests: XCTestCase {
    func testManualSubscriptionCreationPersistsFirstClassManualEntry() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let subscription = try appModel.createManualSubscription(
            .init(
                displayName: "Superhuman",
                priceAmount: Decimal(string: "40.00") ?? 40,
                priceCurrency: "USD",
                cadence: .monthly,
                status: .active,
                lastChargeDate: .now,
                serviceIdentifier: "brand-superhuman",
                paymentMethodName: "Test Rewards Card",
                websiteURL: "https://superhuman.com",
                reminderDaysBefore: 3,
                category: "Software",
                notes: "Founder plan"
            ),
            in: context
        )

        let manualEntries = try context.fetch(FetchDescriptor<ManualSubscription>())

        XCTAssertEqual(subscription.creationPath, .manual)
        XCTAssertEqual(subscription.libraryState, .manual)
        XCTAssertEqual(subscription.status, .active)
        XCTAssertEqual(subscription.priceCurrency, "USD")
        XCTAssertEqual(subscription.serviceIdentifier, "brand-superhuman")
        XCTAssertEqual(subscription.paymentMethodName, "Test Rewards Card")
        XCTAssertEqual(subscription.websiteURL, "https://superhuman.com")
        XCTAssertEqual(subscription.reminderDaysBefore, 3)
        XCTAssertEqual(manualEntries.count, 1)
        XCTAssertEqual(manualEntries.first?.subscriptionID, subscription.id)
    }

    func testManualSubscriptionCreationInfersServiceIdentityWhenLeftBlank() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let subscription = try appModel.createManualSubscription(
            .init(
                displayName: "Netflix",
                priceAmount: Decimal(string: "15.99") ?? 15.99,
                priceCurrency: "USD",
                cadence: .monthly,
                status: .active,
                lastChargeDate: .now
            ),
            in: context
        )

        XCTAssertEqual(subscription.serviceIdentifier, "brand-netflix")
    }

    func testFormerManualSubscriptionPersistsReplacementLink() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let replacement = try appModel.createManualSubscription(
            .init(
                displayName: "YouTube Premium",
                priceAmount: Decimal(string: "18.99") ?? 18.99,
                priceCurrency: "USD",
                cadence: .monthly,
                status: .active,
                lastChargeDate: .now,
                serviceIdentifier: "brand-youtube"
            ),
            in: context
        )

        let legacy = try appModel.createManualSubscription(
            .init(
                displayName: "Spotify",
                priceAmount: Decimal(string: "11.99") ?? 11.99,
                priceCurrency: "USD",
                cadence: .monthly,
                status: .former,
                lastChargeDate: .now,
                replacementSubscriptionID: replacement.id,
                category: "Music"
            ),
            in: context
        )

        XCTAssertEqual(legacy.status, .former)
        XCTAssertEqual(legacy.libraryState, .inactive)
        XCTAssertEqual(legacy.replacementSubscriptionID, replacement.id)
    }

    func testManualSubscriptionSurvivesDetectionRebuild() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let subscription = try appModel.createManualSubscription(
            .init(
                displayName: "Superhuman",
                priceAmount: Decimal(string: "40.00") ?? 40,
                priceCurrency: "USD",
                cadence: .monthly,
                status: .active,
                lastChargeDate: .now,
                category: "Software"
            ),
            in: context
        )

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let manualEntries = try context.fetch(FetchDescriptor<ManualSubscription>())

        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertEqual(subscriptions.first?.id, subscription.id)
        XCTAssertEqual(subscriptions.first?.creationPath, .manual)
        XCTAssertEqual(manualEntries.count, 1)
        XCTAssertEqual(manualEntries.first?.subscriptionID, subscription.id)
    }

    func testEditedDetectedSubscriptionSurvivesDetectionRebuild() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let importRecord = ImportRecord(
            fileName: "chatgpt.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        // Deliberately stale monthly charges (always stale relative to now, so this is
        // not a date time-bomb): the detector infers a non-active status, which makes
        // the user's "keep active" edit a meaningful override to assert survives.
        let calendar = Calendar(identifier: .gregorian)
        let now = Date.now
        let chargeDates = [-9, -8, -7].compactMap {
            calendar.date(byAdding: .month, value: $0, to: now)
        }
        for chargeDate in chargeDates {
            let transaction = NormalizedTransaction(
                transactionDate: chargeDate,
                transactionAmount: Decimal(string: "-20.00") ?? -20,
                merchantRaw: "OPENAI *CHATGPT",
                merchantNormalized: "ChatGPT",
                currency: "USD",
                accountName: "Test Card A",
                category: "AI Subscriptions/Charges",
                memo: "ChatGPT Plus monthly subscription",
                merchantKind: .softwareOrSaaS,
                merchantSubscriptionAffinity: 0.98,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let detected = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>()).first
        )
        XCTAssertEqual(detected.canonicalName, "ChatGPT")
        XCTAssertNotEqual(detected.creationPath, .manual)
        // Stale charges → the detector did not infer an active subscription, so the
        // user's "keep active" edit below is a real override, not a no-op.
        XCTAssertNotEqual(detected.status, .active)

        // The user renames, reprices, recategorizes, keeps it active, and adds notes.
        _ = try appModel.updateManualSubscription(
            id: detected.id,
            .init(
                displayName: "ChatGPT Team",
                priceAmount: Decimal(string: "30.00") ?? 30,
                priceCurrency: "EUR",
                cadence: .monthly,
                status: .active,
                lastChargeDate: detected.lastChargeDate ?? now,
                category: "Work AI",
                notes: "Switched to the team plan"
            ),
            in: context
        )
        try context.save()

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(rule.overridePriceCurrency, "EUR")

        // A subsequent import/refresh must honor the edit via the review-rule override
        // instead of reverting to the detection summary (name "ChatGPT", $20, USD, no category).
        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let edited = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(edited.displayName, "ChatGPT Team")
        XCTAssertEqual(edited.priceAmount, Decimal(string: "30.00"))
        XCTAssertEqual(edited.priceCurrency, "EUR")
        XCTAssertEqual(edited.serviceCategory, "Work AI")
        XCTAssertEqual(edited.status, .active)
        XCTAssertEqual(edited.notes, "Switched to the team plan")
    }

    func testEditingDetectedSubscriptionStatusUpdatesLibraryStateImmediately() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()
        let lastChargeDate = Date.now

        let subscription = Subscription(
            canonicalName: "Claude",
            displayName: "Claude",
            status: .needsReview,
            libraryState: .suggested,
            creationPath: .imported,
            cadence: .monthly,
            priceAmount: Decimal(string: "20.00") ?? 20,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "20.00") ?? 20,
            lastChargeDate: lastChargeDate,
            predictedNextChargeDate: Calendar.current.date(byAdding: .month, value: 1, to: lastChargeDate),
            confidenceScore: 0.81,
            serviceCategory: "Software"
        )
        context.insert(subscription)
        try context.save()

        let active = try appModel.updateManualSubscription(
            id: subscription.id,
            .init(
                displayName: "Claude",
                priceAmount: subscription.priceAmount,
                priceCurrency: subscription.priceCurrency,
                cadence: subscription.cadence,
                status: .active,
                lastChargeDate: lastChargeDate,
                category: subscription.serviceCategory,
                notes: nil
            ),
            in: context
        )

        XCTAssertEqual(active.status, .active)
        XCTAssertEqual(active.libraryState, .confirmed)

        let needsReview = try appModel.updateManualSubscription(
            id: subscription.id,
            .init(
                displayName: "Claude",
                priceAmount: active.priceAmount,
                priceCurrency: active.priceCurrency,
                cadence: active.cadence,
                status: .needsReview,
                lastChargeDate: lastChargeDate,
                category: active.serviceCategory,
                notes: nil
            ),
            in: context
        )

        XCTAssertEqual(needsReview.status, .needsReview)
        XCTAssertEqual(needsReview.libraryState, .suggested)

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "Claude" }
        )
        XCTAssertEqual(rule.overrideStatus, .needsReview)
        XCTAssertFalse(rule.isUserConfirmed)
    }

    func testMerchantLearningPersistsNonUSDCurrencyForKeptSuggestion() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()
        let lastChargeDate = Date.now

        let importRecord = ImportRecord(
            fileName: "euro-tool.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        let subscription = Subscription(
            canonicalName: "Euro Tool",
            displayName: "Euro Tool",
            status: .needsReview,
            cadence: .monthly,
            priceAmount: Decimal(string: "10.00") ?? 10,
            priceCurrency: "EUR",
            normalizedMonthlyAmount: Decimal(string: "10.00") ?? 10,
            lastChargeDate: lastChargeDate,
            predictedNextChargeDate: Calendar.current.date(byAdding: .month, value: 1, to: lastChargeDate),
            confidenceScore: 0.91,
            serviceCategory: "Software"
        )
        context.insert(subscription)

        let transaction = NormalizedTransaction(
            transactionDate: lastChargeDate,
            transactionAmount: Decimal(string: "-10.00") ?? -10,
            merchantRaw: "EURO TOOL",
            merchantNormalized: "Euro Tool",
            currency: "EUR",
            accountName: "Visa",
            category: "Software",
            memo: "Monthly plan",
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.98,
            importRecordID: importRecord.id,
            subscriptionID: subscription.id
        )
        context.insert(transaction)
        try context.save()

        _ = try await appModel.applyMerchantLearning(
            subscriptionID: subscription.id,
            displayName: subscription.displayName,
            status: .active,
            cadence: subscription.cadence,
            priceAmount: subscription.priceAmount,
            priceCurrency: subscription.priceCurrency,
            lastChargeDate: subscription.lastChargeDate,
            category: subscription.serviceCategory,
            notes: subscription.notes,
            isUserConfirmed: true,
            isFalsePositive: false,
            applyAliasToFutureImports: false,
            in: context
        )

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "Euro Tool" }
        )
        XCTAssertEqual(rule.overridePriceAmount, Decimal(string: "10.00"))
        XCTAssertEqual(rule.overridePriceCurrency, "EUR")

        context.delete(subscription)
        context.delete(transaction)
        try context.save()

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let materialized = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "Euro Tool" }
        )
        XCTAssertEqual(materialized.creationPath, .manual)
        XCTAssertEqual(materialized.priceAmount, Decimal(string: "10.00"))
        XCTAssertEqual(materialized.priceCurrency, "EUR")
    }

    func testEditingSuggestedDetectedSubscriptionPreservesReviewQueueState() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let importRecord = ImportRecord(
            fileName: "chatgpt.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        let transaction = NormalizedTransaction(
            transactionDate: Date.now,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "OPENAI *CHATGPT",
            merchantNormalized: "ChatGPT",
            currency: "USD",
            accountName: "Test Card A",
            category: "AI Subscriptions/Charges",
            memo: "ChatGPT Plus monthly subscription",
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.98,
            importRecordID: importRecord.id
        )
        transaction.classificationConfidence = 0.95
        context.insert(transaction)

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let detected = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(detected.status, .needsReview)
        XCTAssertEqual(detected.libraryState, .suggested)

        _ = try appModel.updateManualSubscription(
            id: detected.id,
            .init(
                displayName: "ChatGPT candidate",
                priceAmount: detected.priceAmount,
                priceCurrency: detected.priceCurrency,
                cadence: .monthly,
                status: .needsReview,
                lastChargeDate: detected.lastChargeDate ?? Date.now,
                category: "Work AI",
                notes: "Review later"
            ),
            in: context
        )
        try context.save()

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(rule.overrideStatus, .needsReview)
        XCTAssertFalse(rule.isUserConfirmed)

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let rebuilt = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(rebuilt.displayName, "ChatGPT candidate")
        XCTAssertEqual(rebuilt.status, .needsReview)
        XCTAssertEqual(rebuilt.libraryState, .suggested)
        XCTAssertEqual(rebuilt.notes, "Review later")
    }

    func testCancellingDetectedSubscriptionSurvivesDetectionRebuild() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let importRecord = ImportRecord(
            fileName: "chatgpt.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        let calendar = Calendar(identifier: .gregorian)
        let chargeDates = [-2, -1, 0].compactMap {
            calendar.date(byAdding: .month, value: $0, to: Date.now)
        }
        for chargeDate in chargeDates {
            let transaction = NormalizedTransaction(
                transactionDate: chargeDate,
                transactionAmount: Decimal(string: "-20.00") ?? -20,
                merchantRaw: "OPENAI *CHATGPT",
                merchantNormalized: "ChatGPT",
                currency: "USD",
                accountName: "Test Card A",
                category: "AI Subscriptions/Charges",
                memo: "ChatGPT Plus monthly subscription",
                merchantKind: .softwareOrSaaS,
                merchantSubscriptionAffinity: 0.98,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let detected = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertNotEqual(detected.creationPath, .manual)
        XCTAssertEqual(detected.status, .active)

        try appModel.cancelSubscription(id: detected.id, in: context)

        XCTAssertEqual(detected.status, .former)
        XCTAssertEqual(detected.libraryState, .inactive)

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(rule.overrideStatus, .former)
        XCTAssertTrue(rule.isUserConfirmed)
        XCTAssertFalse(rule.isFalsePositive)

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let rebuilt = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertEqual(rebuilt.status, .former)
        XCTAssertEqual(rebuilt.libraryState, .inactive)
    }

    func testRemovingDetectedFormerSubscriptionSuppressesDetectionRebuild() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()

        let importRecord = ImportRecord(
            fileName: "chatgpt.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        let calendar = Calendar(identifier: .gregorian)
        let chargeDates = [-2, -1, 0].compactMap {
            calendar.date(byAdding: .month, value: $0, to: Date.now)
        }
        for chargeDate in chargeDates {
            let transaction = NormalizedTransaction(
                transactionDate: chargeDate,
                transactionAmount: Decimal(string: "-20.00") ?? -20,
                merchantRaw: "OPENAI *CHATGPT",
                merchantNormalized: "ChatGPT",
                currency: "USD",
                accountName: "Test Card A",
                category: "AI Subscriptions/Charges",
                memo: "ChatGPT Plus monthly subscription",
                merchantKind: .softwareOrSaaS,
                merchantSubscriptionAffinity: 0.98,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let detected = try XCTUnwrap(
            try context.fetch(FetchDescriptor<Subscription>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        let detectedID = detected.id
        let linkedBeforeRemoval = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            .filter { $0.subscriptionID == detectedID }
        XCTAssertFalse(linkedBeforeRemoval.isEmpty)

        try appModel.cancelSubscription(id: detectedID, in: context)
        try appModel.removeSubscription(id: detectedID, in: context)

        let rule = try XCTUnwrap(
            try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
                .first { $0.canonicalName == "ChatGPT" }
        )
        XCTAssertTrue(rule.isFalsePositive)
        XCTAssertTrue(rule.isUserConfirmed)
        XCTAssertNil(appModel.subscription(withID: detectedID, in: context))
        let transactionsAfterRemoval = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            .filter { $0.merchantNormalized == "ChatGPT" }
        XCTAssertTrue(transactionsAfterRemoval.allSatisfy { $0.subscriptionID == nil })

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertFalse(subscriptions.contains { $0.canonicalName == "ChatGPT" })
    }

    func testSubscriptionStatusReflectsUnifiedLibraryState() {
        let subscription = Subscription(
            canonicalName: "ChatGPT",
            displayName: "ChatGPT",
            status: .needsReview,
            libraryState: .suggested,
            cadence: .monthly,
            priceAmount: 20,
            priceCurrency: "USD",
            normalizedMonthlyAmount: 20,
            lastChargeDate: .now,
            predictedNextChargeDate: .now,
            confidenceScore: 0.64
        )

        XCTAssertEqual(subscription.libraryState, .suggested)
        XCTAssertEqual(subscription.status, .needsReview)

        subscription.libraryState = .confirmed

        XCTAssertEqual(subscription.status, .active)
    }

    func testBillingCycleSnapshotTracksCycleProgress() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

        let subscription = Subscription(
            canonicalName: "Cursor",
            displayName: "Cursor",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: 20,
            priceCurrency: "USD",
            normalizedMonthlyAmount: 20,
            lastChargeDate: date(2026, 4, 1, calendar: calendar),
            predictedNextChargeDate: date(2026, 5, 1, calendar: calendar),
            confidenceScore: 0.96
        )

        let snapshot = subscription.billingCycleSnapshot(
            asOf: date(2026, 4, 14, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(snapshot?.elapsedDays, 13)
        XCTAssertEqual(snapshot?.remainingDays, 17)
        XCTAssertEqual(snapshot?.totalDays, 30)
        XCTAssertEqual(snapshot?.urgency, .standard)
        XCTAssertEqual(snapshot?.compactProgressLabel, "43% through cycle")
    }

    func testBillingCycleSnapshotFlagsOverdueRenewals() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

        let subscription = Subscription(
            canonicalName: "Notion",
            displayName: "Notion",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: 12,
            priceCurrency: "USD",
            normalizedMonthlyAmount: 12,
            lastChargeDate: date(2026, 3, 1, calendar: calendar),
            predictedNextChargeDate: date(2026, 4, 1, calendar: calendar),
            confidenceScore: 0.94
        )

        let snapshot = subscription.billingCycleSnapshot(
            asOf: date(2026, 4, 14, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(snapshot?.remainingDays, 0)
        XCTAssertEqual(snapshot?.overdueDays, 13)
        XCTAssertEqual(snapshot?.urgency, .overdue)
        XCTAssertEqual(snapshot?.compactProgressLabel, "Renewal window passed")
        XCTAssertEqual(snapshot?.detailLabel, "Expected renewal was 13 days ago.")
    }

    func testRecurringSaaSClusterPromotesToConfirmedInsteadOfLingeringInReview() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext

        let importRecord = ImportRecord(
            fileName: "chatgpt.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "test"
        )
        context.insert(importRecord)

        let calendar = Calendar(identifier: .gregorian)
        let rows = [-2, -1, 0].map {
            (
                calendar.date(byAdding: .month, value: $0, to: Date.now) ?? Date.now,
                "-20.00"
            )
        }

        for row in rows {
            let transaction = NormalizedTransaction(
                transactionDate: row.0,
                transactionAmount: Decimal(string: row.1) ?? -20,
                merchantRaw: "OPENAI *CHATGPT",
                merchantNormalized: "ChatGPT",
                currency: "USD",
                accountName: "Test Card A",
                category: "AI Subscriptions/Charges",
                memo: "ChatGPT Plus monthly subscription",
                merchantKind: .softwareOrSaaS,
                merchantSubscriptionAffinity: 0.98,
                importRecordID: importRecord.id
            )
            transaction.classificationConfidence = 0.95
            context.insert(transaction)
        }

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let subscription = try XCTUnwrap(subscriptions.first)

        XCTAssertEqual(subscription.canonicalName, "ChatGPT")
        XCTAssertEqual(subscription.libraryState, .confirmed)
        XCTAssertEqual(subscription.status, .active)
        XCTAssertEqual(subscription.serviceIdentifier, "brand-openai")
        XCTAssertGreaterThan(subscription.confidenceScore, 0.7)
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
    }
}
