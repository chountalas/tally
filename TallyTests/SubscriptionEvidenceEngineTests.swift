import SwiftData
import XCTest
@testable import Tally

@MainActor
final class SubscriptionEvidenceEngineTests: XCTestCase {
    func testPendingSourceIdentityReconcilesToPostedTransaction() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SourceTransactionUpsertService()
        let postedDate = ISO8601DateFormatter().date(from: "2026-05-14T00:00:00Z") ?? .now
        let pendingDate = Calendar.current.date(byAdding: .day, value: -1, to: postedDate) ?? postedDate

        let pendingSeed = NormalizedTransactionSeed(
            transactionDate: pendingDate,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "STRIPE* OPENAI",
            category: "Software",
            accountName: "Visa",
            memo: "Pending authorization",
            currency: "USD"
        )
        let postedSeed = NormalizedTransactionSeed(
            transactionDate: postedDate,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "STRIPE* OPENAI",
            category: "Software",
            accountName: "Visa",
            memo: "ChatGPT Plus",
            currency: "USD"
        )

        _ = try await service.upsert(
            [
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: pendingSeed,
                        source: .simpleFIN,
                        externalTransactionID: "pending-1",
                        externalAccountID: "acct-1",
                        pendingExternalTransactionID: "pending-1",
                        status: .pending
                    ),
                    merchantNormalized: "OpenAI",
                    category: "Software",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.95,
                    classificationConfidence: 0.95
                )
            ],
            importRecordID: nil,
            into: context
        )

        _ = try await service.upsert(
            [
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: postedSeed,
                        source: .simpleFIN,
                        externalTransactionID: "posted-1",
                        externalAccountID: "acct-1",
                        pendingExternalTransactionID: "pending-1",
                        status: .posted
                    ),
                    merchantNormalized: "OpenAI",
                    category: "Software",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.95,
                    classificationConfidence: 0.95
                )
            ],
            importRecordID: nil,
            into: context
        )

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].externalTransactionID, "posted-1")
        XCTAssertEqual(identities[0].pendingExternalTransactionID, "pending-1")
        XCTAssertEqual(identities[0].status, .posted)
        XCTAssertEqual(transactions[0].externalTransactionID, "posted-1")
        XCTAssertEqual(transactions[0].transactionDate, postedDate)
        XCTAssertEqual(transactions[0].memo, "ChatGPT Plus")
    }

    func testPendingSourceIdentityFuzzyReconcilesPostedReplacementWithNewFeedID() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SourceTransactionUpsertService()
        let pendingDate = ISO8601DateFormatter().date(from: "2026-05-14T00:00:00Z") ?? .now
        let postedDate = Calendar.current.date(byAdding: .day, value: 1, to: pendingDate) ?? pendingDate
        let pendingSeed = NormalizedTransactionSeed(
            transactionDate: pendingDate,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "STRIPE* OPENAI",
            category: "Software",
            accountName: "Visa",
            memo: "Pending authorization",
            currency: "USD"
        )
        let postedSeed = NormalizedTransactionSeed(
            transactionDate: postedDate,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "STRIPE* OPENAI",
            category: "Software",
            accountName: "Visa",
            memo: "ChatGPT Plus",
            currency: "USD"
        )

        _ = try await service.upsert(
            [
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: pendingSeed,
                        source: .simpleFIN,
                        externalTransactionID: "pending-feed-id",
                        externalAccountID: "acct-1",
                        sourceReferenceID: "pending-feed-id",
                        pendingExternalTransactionID: "pending-feed-id",
                        status: .pending
                    ),
                    merchantNormalized: "OpenAI",
                    category: "Software",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.95,
                    classificationConfidence: 0.95
                )
            ],
            importRecordID: nil,
            into: context
        )

        _ = try await service.upsert(
            [
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: postedSeed,
                        source: .simpleFIN,
                        externalTransactionID: "posted-feed-id",
                        externalAccountID: "acct-1",
                        sourceReferenceID: "posted-feed-id",
                        status: .posted
                    ),
                    merchantNormalized: "OpenAI",
                    category: "Software",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.95,
                    classificationConfidence: 0.95
                )
            ],
            importRecordID: nil,
            into: context
        )

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(identities.count, 1)
        XCTAssertEqual(identities[0].externalTransactionID, "posted-feed-id")
        XCTAssertNil(identities[0].pendingExternalTransactionID)
        XCTAssertEqual(identities[0].status, .posted)
        XCTAssertEqual(transactions[0].externalTransactionID, "posted-feed-id")
        XCTAssertEqual(transactions[0].transactionDate, postedDate)
        XCTAssertEqual(transactions[0].memo, "ChatGPT Plus")
    }

    func testExternalTransactionIDMatchesAreScopedByAccount() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let service = SourceTransactionUpsertService()
        let postedDate = ISO8601DateFormatter().date(from: "2026-05-14T00:00:00Z") ?? .now
        let firstSeed = NormalizedTransactionSeed(
            transactionDate: postedDate,
            transactionAmount: Decimal(string: "-12.00") ?? -12,
            merchantRaw: "APPLE.COM/BILL",
            category: "Digital",
            accountName: "Checking",
            memo: "App Store",
            currency: "USD"
        )
        let secondSeed = NormalizedTransactionSeed(
            transactionDate: postedDate,
            transactionAmount: Decimal(string: "-12.00") ?? -12,
            merchantRaw: "APPLE.COM/BILL",
            category: "Digital",
            accountName: "Savings",
            memo: "App Store",
            currency: "USD"
        )

        _ = try await service.upsert(
            [
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: firstSeed,
                        source: .simpleFIN,
                        externalTransactionID: "provider-local-1",
                        externalAccountID: "acct-checking"
                    ),
                    merchantNormalized: "Apple",
                    category: "Digital",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.8,
                    classificationConfidence: 0.8
                ),
                SourceTransactionMaterialization(
                    draft: SourceTransactionDraft(
                        seed: secondSeed,
                        source: .simpleFIN,
                        externalTransactionID: "provider-local-1",
                        externalAccountID: "acct-savings"
                    ),
                    merchantNormalized: "Apple",
                    category: "Digital",
                    merchantKind: .softwareOrSaaS,
                    merchantSubscriptionAffinity: 0.8,
                    classificationConfidence: 0.8
                )
            ],
            importRecordID: nil,
            into: context
        )

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(Set(transactions.compactMap(\.externalAccountID)), ["acct-checking", "acct-savings"])
    }

    func testDuplicateManualImportUpsertsSourceIdentitiesWithoutDuplicatingTransactions() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let csv = """
        Date,Merchant,Amount,Category,Memo
        2025-01-04,Netflix,-15.49,Streaming,Standard plan
        2025-02-04,Netflix,-15.49,Streaming,Standard plan
        2025-03-04,Netflix,-15.49,Streaming,Standard plan
        """

        var draft = try importer.makeDraft(fileName: "netflix.csv", csvText: csv)
        appModel.importDraft = draft
        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        draft = try importer.makeDraft(fileName: "netflix.csv", csvText: csv)
        appModel.importDraft = draft
        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(identities.count, 3)
        XCTAssertTrue(identities.allSatisfy { $0.normalizedTransactionID != nil })
    }

    func testIdenticalRowsInSingleManualImportStaySeparate() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let csv = """
        Date,Merchant,Amount,Category,Memo
        2025-01-04,Apple,-4.99,Digital,App Store
        2025-01-04,Apple,-4.99,Digital,App Store
        """

        let draft = try importer.makeDraft(fileName: "app-store.csv", csvText: csv)
        appModel.importDraft = draft
        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(Set(identities.compactMap(\.sourceReferenceID)).count, 2)
        XCTAssertTrue(identities.compactMap(\.sourceReferenceID).allSatisfy { $0.hasPrefix("fingerprint:") })
    }

    func testManualImportReconcilesRowsAfterInsertedCsvRowShiftsPositions() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let originalCSV = """
        Date,Merchant,Amount,Category,Memo
        2025-01-04,Netflix,-15.49,Streaming,Standard plan
        2025-02-04,Netflix,-15.49,Streaming,Standard plan
        2025-03-04,Netflix,-15.49,Streaming,Standard plan
        """
        let updatedCSV = """
        Date,Merchant,Amount,Category,Memo
        2025-04-04,Netflix,-15.49,Streaming,Standard plan
        2025-01-04,Netflix,-15.49,Streaming,Standard plan
        2025-02-04,Netflix,-15.49,Streaming,Standard plan
        2025-03-04,Netflix,-15.49,Streaming,Standard plan
        """

        var draft = try importer.makeDraft(fileName: "netflix.csv", csvText: originalCSV)
        appModel.importDraft = draft
        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        draft = try importer.makeDraft(fileName: "netflix.csv", csvText: updatedCSV)
        appModel.importDraft = draft
        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertEqual(transactions.count, 4)
        XCTAssertEqual(identities.count, 4)
        XCTAssertEqual(Set(identities.compactMap(\.sourceReferenceID)).count, 4)
    }

    func testFalsePositiveMerchantCorrectionCreatesNegativeMatchRuleAndRejectsMatches() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        context.insert(
            MerchantCorrection(
                canonicalName: "Amazon",
                isSubscription: false,
                correctedCadence: nil
            )
        )
        let transaction = NormalizedTransaction(
            transactionDate: Calendar.current.date(byAdding: .day, value: -4, to: .now) ?? .now,
            transactionAmount: Decimal(string: "-14.99") ?? -14.99,
            merchantRaw: "AMAZON PRIME STORE",
            merchantNormalized: "Amazon",
            currency: "USD",
            accountName: "Visa",
            category: "Retail",
            memo: "Prime order",
            merchantKind: .marketplace,
            merchantSubscriptionAffinity: 0.2
        )
        transaction.classificationConfidence = 0.8
        context.insert(transaction)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let rules = try context.fetch(FetchDescriptor<SubscriptionMatchRule>())
        XCTAssertTrue(
            rules.contains {
                $0.canonicalName == "Amazon" &&
                    $0.isNegativeRule &&
                    $0.createdFrom == .userCorrection
            }
        )
        XCTAssertNil(transaction.subscriptionID)

        let evidence = try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
        XCTAssertTrue(evidence.contains { $0.candidateKey == "Amazon" && $0.decision == .ruleRejected })
        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
    }

    func testEmptyAliasShortCanonicalRuleDoesNotWildcardMerchantMatches() {
        let rule = SubscriptionMatchRule(
            canonicalName: "X",
            amountMinimum: Decimal(string: "8.00"),
            amountMaximum: Decimal(string: "12.00"),
            currencyCode: "USD",
            confidence: 1,
            createdFrom: .reviewRule
        )
        let unrelatedTransaction = NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-10.00") ?? -10,
            source: .manualImport,
            merchantRaw: "EXXON MOBIL",
            merchantNormalized: "Exxon",
            currency: "USD",
            accountName: "Visa",
            category: "Fuel",
            memo: nil,
            merchantKind: .unknown,
            merchantSubscriptionAffinity: 0.1
        )
        let exactTransaction = NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-10.00") ?? -10,
            source: .manualImport,
            merchantRaw: "X",
            merchantNormalized: "X",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9
        )

        let service = SubscriptionDetectionService()
        XCTAssertFalse(service.ruleMatches(rule, transaction: unrelatedTransaction))
        XCTAssertTrue(service.ruleMatches(rule, transaction: exactTransaction))
    }

    func testAllowedRawMerchantSatisfiesRuleWhenRequiredCanonicalTokensAreAbsent() {
        let rule = SubscriptionMatchRule(
            canonicalName: "Claude Pro",
            allowedRawMerchantsJSON: SubscriptionEvidenceJSON.encodeStrings(["SQ *ANTHROPIC"]),
            requiredTokensJSON: SubscriptionEvidenceJSON.encodeStrings(["claude", "pro"]),
            amountMinimum: Decimal(string: "18.00"),
            amountMaximum: Decimal(string: "22.00"),
            currencyCode: "USD",
            confidence: 1,
            createdFrom: .reviewRule
        )
        let transaction = NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            source: .manualImport,
            merchantRaw: "SQ *ANTHROPIC",
            merchantNormalized: "Anthropic",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9
        )

        XCTAssertTrue(SubscriptionDetectionService().ruleMatches(rule, transaction: transaction))
    }

    func testMissingTransactionCurrencyMatchesDefaultUSDRule() {
        let rule = SubscriptionMatchRule(
            subscriptionID: UUID(),
            canonicalName: "Netflix",
            allowedRawMerchantsJSON: SubscriptionEvidenceJSON.encodeStrings(["NETFLIX"]),
            amountMinimum: Decimal(string: "14.00"),
            amountMaximum: Decimal(string: "17.00"),
            currencyCode: "USD",
            confidence: 1,
            createdFrom: .reviewRule
        )
        let transaction = NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-15.49") ?? -15.49,
            source: .manualImport,
            merchantRaw: "NETFLIX",
            merchantNormalized: "Netflix",
            currency: nil,
            accountName: "Visa",
            category: "Streaming",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9
        )

        XCTAssertTrue(SubscriptionDetectionService().ruleMatches(rule, transaction: transaction))
    }

    func testNeedsReviewEvidenceStoresLocalAIContribution() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let transaction = NormalizedTransaction(
            transactionDate: Calendar.current.date(byAdding: .day, value: -3, to: .now) ?? .now,
            transactionAmount: Decimal(string: "-8.99") ?? -8.99,
            merchantRaw: "NIMBUS NOTES",
            merchantNormalized: "Nimbus Notes",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: "monthly plan",
            merchantKind: .unknown,
            merchantSubscriptionAffinity: 0.78
        )
        transaction.classificationConfidence = 0.6
        context.insert(transaction)

        try await SubscriptionDetectionService(
            intelligence: SubscriptionIntelligenceService(generator: EvidenceRecordingGenerator())
        ).rebuildSubscriptions(in: context)
        try context.save()

        let evidence = try XCTUnwrap(
            context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
                .first { $0.candidateKey == "Nimbus Notes" && $0.decision == .needsReview }
        )
        XCTAssertEqual(evidence.llmScore ?? 0, 0.84, accuracy: 0.001)
        XCTAssertEqual(evidence.llmProviderRawValue, AIProviderKind.gemmaLocal.rawValue)
        XCTAssertEqual(evidence.llmPromptVersion, 1)
        XCTAssertTrue(evidence.llmInputFingerprint?.isEmpty == false)
        XCTAssertTrue(evidence.llmOutputJSON?.contains("Structured evidence matched subscription cues.") == true)
        XCTAssertTrue(evidence.evidenceFactorsJSON.contains("llm_subscription_judgment"))

        let runs = try context.fetch(FetchDescriptor<DetectionRun>())
        XCTAssertEqual(runs.first?.llmEvaluationCount, 1)
    }

    func testMatchRuleLinksNewChargeBeforeClusteringAndRecordsEvidence() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let formatter = ISO8601DateFormatter()
        let subscription = Subscription(
            canonicalName: "OpenAI",
            displayName: "OpenAI",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: Decimal(string: "20.00") ?? 20,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "20.00") ?? 20,
            lastChargeDate: formatter.date(from: "2026-05-14T00:00:00Z"),
            predictedNextChargeDate: formatter.date(from: "2026-06-14T00:00:00Z"),
            confidenceScore: 0.96,
            isUserConfirmed: true
        )
        context.insert(subscription)
        context.insert(
            SubscriptionMatchRule(
                subscriptionID: subscription.id,
                canonicalName: "OpenAI",
                allowedRawMerchantsJSON: SubscriptionEvidenceJSON.encodeStrings(["STRIPE* OPENAI"]),
                amountMinimum: Decimal(string: "18.00"),
                amountMaximum: Decimal(string: "22.00"),
                amountMedian: Decimal(string: "20.00"),
                currencyCode: "USD",
                priority: 900,
                confidence: 1,
                createdFrom: .reviewRule
            )
        )
        let transaction = NormalizedTransaction(
            transactionDate: formatter.date(from: "2026-06-15T00:00:00Z") ?? .now,
            transactionAmount: Decimal(string: "-20.00") ?? -20,
            merchantRaw: "STRIPE* OPENAI",
            merchantNormalized: "OpenAI",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: "ChatGPT Plus",
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.95
        )
        transaction.classificationConfidence = 0.95
        context.insert(transaction)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertEqual(transaction.subscriptionID, subscription.id)
        XCTAssertEqual(subscription.lastChargeDate, transaction.transactionDate)
        XCTAssertEqual(subscription.priceAmount, Decimal(string: "20.00") ?? 20)
        XCTAssertEqual(
            subscription.predictedNextChargeDate,
            formatter.date(from: "2026-07-15T00:00:00Z")
        )

        let evidence = try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
        XCTAssertTrue(evidence.contains { $0.decision == .ruleMatched && $0.subscriptionID == subscription.id })

        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        XCTAssertTrue(occurrences.contains { $0.subscriptionID == subscription.id && $0.status == .matched })
    }

    func testMissedOccurrenceKeepsConfirmedSubscriptionAndLowersConfidence() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let formatter = ISO8601DateFormatter()
        let subscription = Subscription(
            canonicalName: "Linear",
            displayName: "Linear",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: Decimal(string: "10.00") ?? 10,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10.00") ?? 10,
            lastChargeDate: formatter.date(from: "2026-04-01T00:00:00Z"),
            predictedNextChargeDate: formatter.date(from: "2026-05-01T00:00:00Z"),
            confidenceScore: 0.92,
            isUserConfirmed: true
        )
        context.insert(subscription)
        let transaction = NormalizedTransaction(
            transactionDate: formatter.date(from: "2026-04-01T00:00:00Z") ?? .now,
            transactionAmount: Decimal(string: "-10.00") ?? -10,
            merchantRaw: "LINEAR",
            merchantNormalized: "Linear",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9,
            subscriptionID: subscription.id
        )
        transaction.classificationConfidence = 0.9
        context.insert(transaction)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertEqual(subscriptions.count, 1)
        XCTAssertLessThan(subscriptions[0].confidenceScore, 0.92)
        let confidenceAfterFirstMiss = subscriptions[0].confidenceScore

        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        XCTAssertTrue(occurrences.contains { $0.subscriptionID == subscription.id && $0.status == .missed })

        let evidence = try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
        XCTAssertTrue(evidence.contains { $0.decision == .occurrenceMissed && $0.subscriptionID == subscription.id })

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        XCTAssertEqual(subscription.confidenceScore, confidenceAfterFirstMiss, accuracy: 0.001)
    }

    func testOccurrenceWindowIncludesEntireFinalToleranceDay() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let formatter = ISO8601DateFormatter()
        let subscription = Subscription(
            canonicalName: "Linear",
            displayName: "Linear",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: Decimal(string: "10.00") ?? 10,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10.00") ?? 10,
            lastChargeDate: formatter.date(from: "2026-05-10T00:00:00Z"),
            predictedNextChargeDate: formatter.date(from: "2026-06-10T00:00:00Z"),
            confidenceScore: 0.92,
            isUserConfirmed: true
        )
        context.insert(subscription)
        let transaction = NormalizedTransaction(
            transactionDate: formatter.date(from: "2026-06-13T15:00:00Z") ?? .now,
            transactionAmount: Decimal(string: "-10.00") ?? -10,
            merchantRaw: "LINEAR",
            merchantNormalized: "Linear",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9,
            subscriptionID: subscription.id
        )
        transaction.classificationConfidence = 0.9
        context.insert(transaction)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        XCTAssertTrue(occurrences.contains { occurrence in
            occurrence.subscriptionID == subscription.id &&
                occurrence.status == .matched &&
                occurrence.matchedTransactionID == transaction.id
        })
    }

    func testPriceJumpRecordsPriceChangedOccurrence() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let formatter = ISO8601DateFormatter()
        let subscription = Subscription(
            canonicalName: "Figma",
            displayName: "Figma",
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: Decimal(string: "10.00") ?? 10,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10.00") ?? 10,
            lastChargeDate: formatter.date(from: "2026-05-10T00:00:00Z"),
            predictedNextChargeDate: formatter.date(from: "2026-06-10T00:00:00Z"),
            confidenceScore: 0.94,
            isUserConfirmed: true
        )
        context.insert(subscription)
        context.insert(
            SubscriptionMatchRule(
                subscriptionID: subscription.id,
                canonicalName: "Figma",
                allowedRawMerchantsJSON: SubscriptionEvidenceJSON.encodeStrings(["FIGMA"]),
                amountMinimum: Decimal(string: "7.00"),
                amountMaximum: Decimal(string: "12.50"),
                amountMedian: Decimal(string: "10.00"),
                currencyCode: "USD",
                priority: 900,
                confidence: 1,
                createdFrom: .reviewRule
            )
        )
        let transaction = NormalizedTransaction(
            transactionDate: formatter.date(from: "2026-06-10T00:00:00Z") ?? .now,
            transactionAmount: Decimal(string: "-15.00") ?? -15,
            merchantRaw: "FIGMA",
            merchantNormalized: "Figma",
            currency: "USD",
            accountName: "Visa",
            category: "Software",
            memo: nil,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9
        )
        transaction.classificationConfidence = 0.9
        context.insert(transaction)

        try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let occurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        XCTAssertTrue(occurrences.contains { $0.subscriptionID == subscription.id && $0.status == .priceChanged })

        let evidence = try context.fetch(FetchDescriptor<SubscriptionDetectionEvidence>())
        XCTAssertTrue(evidence.contains { $0.decision == .priceChanged && $0.subscriptionID == subscription.id })
    }
}

struct InvalidEvidenceGenerator: SubscriptionIntelligenceGenerating {
    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        IntelligenceCopyPayload(headline: draft.headline, summary: draft.summary, followUps: draft.followUps)
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult {
        MerchantClassificationResult(
            canonicalName: rawMerchant,
            serviceCategory: "Uncategorized",
            merchantKind: .unknown,
            subscriptionAffinity: 0,
            confidence: 0
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        [:]
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult {
        RecurringClusterEvaluationResult(
            isSubscription: false,
            confidence: 0,
            reasonSummary: "",
            negativeSignals: []
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        SingleChargeEvaluationResult(
            isLikelySubscription: false,
            confidence: 0,
            reasonSummary: "",
            negativeSignals: []
        )
    }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult {
        SubscriptionEvidenceEvaluationResult(
            isSubscription: true,
            confidence: 1.8,
            likelyServiceName: "  ",
            likelyPlanDescriptor: "Plus",
            positiveSignals: [" Recurring amount "],
            negativeSignals: [" "],
            reasonSummary: " Evidence says subscription. "
        )
    }
}

struct EvidenceRecordingGenerator: SubscriptionIntelligenceGenerating {
    var evidenceProviderKind: AIProviderKind? { .gemmaLocal }

    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        IntelligenceCopyPayload(headline: draft.headline, summary: draft.summary, followUps: draft.followUps)
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult {
        MerchantClassificationResult(
            canonicalName: rawMerchant,
            serviceCategory: "Uncategorized",
            merchantKind: .unknown,
            subscriptionAffinity: 0.7,
            confidence: 0.7
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        [:]
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult {
        RecurringClusterEvaluationResult(
            isSubscription: true,
            confidence: 0.78,
            reasonSummary: "Recurring evidence is plausible.",
            negativeSignals: []
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        SingleChargeEvaluationResult(
            isLikelySubscription: true,
            confidence: 0.84,
            reasonSummary: "Single-charge evidence is plausible.",
            negativeSignals: []
        )
    }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult {
        SubscriptionEvidenceEvaluationResult(
            isSubscription: true,
            confidence: 0.84,
            likelyServiceName: input.displayName,
            likelyPlanDescriptor: "Monthly",
            positiveSignals: ["Monthly wording", "Software merchant"],
            negativeSignals: [],
            reasonSummary: "Structured evidence matched subscription cues."
        )
    }
}

final class SubscriptionEvidenceLLMValidationTests: XCTestCase {
    func testEvidenceEvaluationClampsConfidenceAndSanitizesSignals() async {
        let service = SubscriptionIntelligenceService(generator: InvalidEvidenceGenerator())
        let result = await service.evaluateSubscriptionEvidence(
            SubscriptionEvidenceEvaluationInput(
                candidateKey: "openai",
                canonicalName: "OpenAI",
                displayName: "OpenAI",
                rawMerchantVariants: ["STRIPE* OPENAI"],
                memoSamples: ["ChatGPT Plus"],
                categorySamples: ["Software"],
                serviceProfileName: nil,
                merchantKind: .softwareOrSaaS,
                subscriptionAffinity: 0.95,
                scheduleSummary: "monthly",
                occurrenceSummary: "3 of 3 matched",
                amountSummary: "$20 stable",
                negativeSignals: [],
                userRuleSummary: nil
            )
        )

        XCTAssertEqual(result?.confidence, 1)
        XCTAssertNil(result?.likelyServiceName)
        XCTAssertEqual(result?.likelyPlanDescriptor, "Plus")
        XCTAssertEqual(result?.positiveSignals, ["Recurring amount"])
        XCTAssertTrue(result?.negativeSignals.isEmpty == true)
        XCTAssertEqual(result?.reasonSummary, "Evidence says subscription.")
    }
}
