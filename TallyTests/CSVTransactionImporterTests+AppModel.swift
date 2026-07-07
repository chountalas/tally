import SwiftData
import XCTest
@testable import Tally

extension CSVTransactionImporterTests {
    func testAppDataExportIncludesAliasesAndReviewRules() throws {
        let data = try AppDataExporter().exportData(from: makeExportSource())

        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let exportedImports = try XCTUnwrap(payload["imports"] as? [[String: Any]])
        let exportedAliases = try XCTUnwrap(payload["aliases"] as? [[String: Any]])
        let exportedReviewRules = try XCTUnwrap(payload["reviewRules"] as? [[String: Any]])

        XCTAssertEqual(exportedImports.first?["detectedSubscriptionCount"] as? Int, 1)
        XCTAssertEqual(exportedImports.first?["needsReviewSubscriptionCount"] as? Int, 1)
        XCTAssertEqual(exportedImports.first?["suppressedRecurringCandidateCount"] as? Int, 2)
        XCTAssertEqual(exportedImports.first?["recoveredRecurringCandidateCount"] as? Int, 1)
        XCTAssertEqual(exportedAliases.count, 1)
        XCTAssertEqual(exportedAliases.first?["rawMerchant"] as? String, "NETFLIX *123")
        XCTAssertEqual(exportedReviewRules.count, 1)
        XCTAssertEqual(exportedReviewRules.first?["canonicalName"] as? String, "Netflix")
        XCTAssertEqual(exportedReviewRules.first?["overrideDisplayName"] as? String, "Netflix Premium")
        XCTAssertEqual(exportedReviewRules.first?["overridePriceCurrency"] as? String, "EUR")
        XCTAssertEqual(
            exportedReviewRules.first?["overrideLastChargeDate"] as? String,
            "2026-03-01T12:00:00Z"
        )
    }

    @MainActor
    func testDismissImportRemovesPendingImportRecord() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        try "Date,Merchant,Amount\n2025-01-01,Netflix,-15.49\n".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        appModel.prepareImport(from: url, into: context)
        appModel.dismissImport(into: context)

        await Task.yield()
        await Task.yield()

        let imports = try context.fetch(FetchDescriptor<ImportRecord>())
        XCTAssertTrue(imports.isEmpty)
        XCTAssertNil(appModel.importDraft)
    }

    @MainActor
    func testClearImportedLibraryRemovesPersistedImportDataAndDraftState() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let mapping = ColumnMappingConfig(
            dateColumn: "Date",
            descriptionColumn: "Merchant",
            amountColumn: "Amount",
            merchantColumn: "Merchant",
            categoryColumn: nil,
            accountColumn: nil,
            currencyColumn: nil,
            debitSignConvention: .negative
        )

        appModel.importDraft = makePendingDraft(mapping: mapping)
        appModel.infoMessage = "Imported 1 transaction."
        appModel.importErrorMessage = "Previous failure"
        appModel.classificationStatusMessage = "Cached classifications"
        insertPersistedImportLibrary(into: context, mapping: mapping)
        try context.save()

        let summary = try appModel.clearImportedLibrary(in: context)

        XCTAssertEqual(summary.importCount, 1)
        XCTAssertEqual(summary.transactionCount, 1)
        XCTAssertEqual(summary.subscriptionCount, 1)
        XCTAssertNil(appModel.importDraft)
        XCTAssertNil(appModel.infoMessage)
        XCTAssertNil(appModel.importErrorMessage)
        XCTAssertNil(appModel.classificationStatusMessage)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ImportRecord>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Subscription>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<NormalizedTransaction>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MerchantClassification>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<MerchantAlias>()).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<SubscriptionReviewRule>()).isEmpty)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ColumnMappingTemplate>()).count, 1)
    }

    @MainActor
    func testStoredTemplateIsReappliedWhenHeadersMatch() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let storedMapping = ColumnMappingConfig(
            dateColumn: "Txn Date",
            descriptionColumn: "Details",
            amountColumn: "Value",
            merchantColumn: "Details",
            categoryColumn: nil,
            accountColumn: nil,
            currencyColumn: nil,
            debitSignConvention: .positive
        )
        context.insert(ColumnMappingTemplate(config: storedMapping))
        try context.save()

        let draft = TransactionImportDraft(
            fileName: "reuse.csv",
            headers: ["Txn Date", "Details", "Value"],
            previewRows: [],
            rawRows: [["Txn Date": "2025-01-01", "Details": "Netflix", "Value": "15.49"]],
            suggestedMapping: ColumnMappingConfig(
                dateColumn: "Txn Date",
                descriptionColumn: nil,
                amountColumn: "Value",
                merchantColumn: nil,
                categoryColumn: nil,
                accountColumn: nil,
                currencyColumn: nil,
                debitSignConvention: .negative
            ),
            confidence: 0.33
        )

        let resolved = appModel.draftApplyingStoredTemplate(draft, context: context)

        XCTAssertEqual(resolved.suggestedMapping, storedMapping)
        XCTAssertEqual(resolved.confidence, 1.0)
    }

    @MainActor
    func testStoredTemplateIsIgnoredWhenColumnsMissing() throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let storedMapping = ColumnMappingConfig(
            dateColumn: "Legacy Date",
            descriptionColumn: nil,
            amountColumn: "Legacy Amount",
            merchantColumn: "Legacy Merchant",
            categoryColumn: nil,
            accountColumn: nil,
            currencyColumn: nil,
            debitSignConvention: .negative
        )
        context.insert(ColumnMappingTemplate(config: storedMapping))
        try context.save()

        let guessedMapping = ColumnMappingConfig(
            dateColumn: "Date",
            descriptionColumn: nil,
            amountColumn: "Amount",
            merchantColumn: "Merchant",
            categoryColumn: nil,
            accountColumn: nil,
            currencyColumn: nil,
            debitSignConvention: .negative
        )
        let draft = TransactionImportDraft(
            fileName: "fresh.csv",
            headers: ["Date", "Merchant", "Amount"],
            previewRows: [],
            rawRows: [["Date": "2025-01-01", "Merchant": "Netflix", "Amount": "-15.49"]],
            suggestedMapping: guessedMapping,
            confidence: 0.66
        )

        let resolved = appModel.draftApplyingStoredTemplate(draft, context: context)

        XCTAssertEqual(resolved.suggestedMapping, guessedMapping)
        XCTAssertEqual(resolved.confidence, 0.66)
    }

    @MainActor
    func testImportResultMessageReportsInsertedUpdatedUnchanged() {
        let appModel = AppModel.testing()
        var summary = SourceTransactionUpsertSummary()
        summary.insertedCount = 3
        summary.updatedCount = 2
        summary.unchangedCount = 5

        let message = appModel.importResultMessage(importFileName: "bank.csv", upsertSummary: summary)

        XCTAssertTrue(message.contains("3 new"))
        XCTAssertTrue(message.contains("2 updated"))
        XCTAssertTrue(message.contains("5 unchanged"))
        XCTAssertTrue(message.contains("10 transactions"))
    }

    @MainActor
    func testNavigationExposesTransactionsTabAndRoutesToIt() {
        let appModel = AppModel.testing()

        XCTAssertTrue(SidebarTab.allCases.contains(.transactions))

        appModel.openRoute(.transactions)

        XCTAssertEqual(appModel.selectedTab, .transactions)
    }

    @MainActor
    func testOpenSubscriptionLibraryQueuesSuggestedInboxNavigation() {
        let appModel = AppModel.testing()

        appModel.openSubscriptionLibrary(state: .suggested)

        XCTAssertEqual(appModel.selectedTab, .subscriptions)
        XCTAssertEqual(appModel.consumePendingSubscriptionLibraryState(), .suggested)
        XCTAssertNil(appModel.consumePendingSubscriptionLibraryState())
    }

    @MainActor
    func testOpenSubscriptionLibraryCanScopeNavigationToImportRecord() {
        let appModel = AppModel.testing()
        let importRecordID = UUID()

        appModel.openSubscriptionLibrary(
            state: .suggested,
            importRecordID: importRecordID
        )

        let request = appModel.consumePendingSubscriptionLibraryNavigation()
        XCTAssertEqual(appModel.selectedTab, .subscriptions)
        XCTAssertEqual(request?.state, .suggested)
        XCTAssertEqual(request?.importRecordID, importRecordID)
        XCTAssertNil(appModel.consumePendingSubscriptionLibraryNavigation())
    }

    @MainActor
    func testSaveChangesAndApplyReviewRuleLocallyReplaysMerchantLearningForConfirmedRule() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()
        let calendar = Calendar.current
        let previousChargeDate = calendar.date(byAdding: .day, value: -42, to: .now) ?? .now
        let latestChargeDate = calendar.date(byAdding: .day, value: -12, to: .now) ?? .now
        let nextChargeDate = calendar.date(byAdding: .month, value: 1, to: latestChargeDate) ?? .now

        let subscription = Subscription(
            canonicalName: "Netflix",
            displayName: "Netflix",
            status: .needsReview,
            cadence: .monthly,
            priceAmount: Decimal(string: "15.49") ?? 15.49,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "15.49") ?? 15.49,
            lastChargeDate: latestChargeDate,
            predictedNextChargeDate: nextChargeDate,
            confidenceScore: 0.62,
            serviceCategory: "Streaming"
        )
        context.insert(subscription)

        let importRecord = ImportRecord(
            fileName: "netflix.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "seed"
        )
        context.insert(importRecord)

        for (rawMerchant, transactionDate) in [
            ("NETFLIX *123", previousChargeDate),
            ("NETFLIX.COM", latestChargeDate)
        ] {
            let transaction = NormalizedTransaction(
                transactionDate: transactionDate,
                transactionAmount: Decimal(string: "-15.49") ?? -15.49,
                merchantRaw: rawMerchant,
                merchantNormalized: "Netflix",
                currency: "USD",
                accountName: "Visa",
                category: "Streaming",
                memo: "Plan",
                importRecordID: importRecord.id,
                subscriptionID: subscription.id
            )
            context.insert(transaction)
        }

        context.insert(
            SubscriptionReviewRule(
                canonicalName: "Netflix",
                overrideStatus: .active,
                overrideCategory: "Streaming",
                isFalsePositive: false,
                isUserConfirmed: true
            )
        )
        try context.save()

        let updated = try await appModel.saveChangesAndApplyReviewRuleLocally(
            canonicalName: "Netflix",
            subscriptionID: subscription.id,
            in: context
        )

        XCTAssertEqual(updated?.status, .active)

        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.canonicalName, "Netflix")
        XCTAssertEqual(corrections.first?.isSubscription, true)

        let aliases = try context.fetch(FetchDescriptor<MerchantAlias>())
        XCTAssertEqual(Set(aliases.map(\.rawMerchant)), Set(["NETFLIX *123", "NETFLIX.COM"]))
        XCTAssertTrue(aliases.allSatisfy { $0.canonicalName == "Netflix" })

        let classifications = try context.fetch(FetchDescriptor<MerchantClassification>())
        XCTAssertEqual(Set(classifications.map(\.rawMerchant)), Set(["NETFLIX *123", "NETFLIX.COM"]))
        XCTAssertTrue(classifications.allSatisfy(\.isUserCorrected))
        XCTAssertTrue(classifications.allSatisfy { $0.canonicalName == "Netflix" })
        XCTAssertTrue(classifications.allSatisfy { $0.confidence == 1 })
    }

    @MainActor
    func testReviewAutomationPlanSplitsSafeConfirmationsNoiseAndManualReview() throws {
        let appModel = AppModel.testing()
        let safe = makeAutomationSubscription(
            name: "GitHub",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.91,
            category: "Software"
        )
        let noise = makeAutomationSubscription(
            name: "Corner Market",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.24,
            category: "Groceries"
        )
        let manual = makeAutomationSubscription(
            name: "Mystery Cloud",
            status: .needsReview,
            cadence: .unknown,
            confidence: 0.55,
            category: nil
        )

        let transactions = [
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -2,
                subscriptionID: safe.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -1,
                subscriptionID: safe.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "CORNER MARKET",
                amount: -21.45,
                monthOffset: -1,
                subscriptionID: noise.id,
                merchantKind: .groceryRetailer,
                affinity: 0.05
            ),
            makeAutomationTransaction(
                merchant: "MYSTERY CLOUD",
                amount: -19,
                monthOffset: -1,
                subscriptionID: manual.id,
                merchantKind: .unknown,
                affinity: 0.4
            )
        ]

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [safe, noise, manual],
            transactions: transactions
        )

        XCTAssertEqual(plan.confirmCandidates.map(\.displayName), ["GitHub"])
        XCTAssertEqual(plan.suppressCandidates.map(\.displayName), ["Corner Market"])
        XCTAssertEqual(plan.manualCandidates.map(\.displayName), ["Mystery Cloud"])
        XCTAssertEqual(plan.manualCountAfterAutomation, 1)
    }

    @MainActor
    func testAutomatedReviewConfirmationDoesNotDeleteUntouchedSubscriptions() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let safe = makeAutomationSubscription(
            name: "GitHub",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.91,
            category: "Software"
        )
        let untouched = makeAutomationSubscription(
            name: "Dropbox",
            status: .active,
            cadence: .monthly,
            confidence: 0.97,
            category: "Storage"
        )
        context.insert(safe)
        context.insert(untouched)

        let importRecord = ImportRecord(
            fileName: "automation.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: "automation"
        )
        context.insert(importRecord)

        for transaction in [
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -2,
                subscriptionID: safe.id,
                importRecordID: importRecord.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -1,
                subscriptionID: safe.id,
                importRecordID: importRecord.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "DROPBOX",
                amount: -19.99,
                monthOffset: -2,
                subscriptionID: untouched.id,
                importRecordID: importRecord.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "DROPBOX",
                amount: -19.99,
                monthOffset: -1,
                subscriptionID: untouched.id,
                importRecordID: importRecord.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            )
        ] {
            context.insert(transaction)
        }
        try context.save()

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [safe, untouched],
            transactions: try context.fetch(FetchDescriptor<NormalizedTransaction>())
        )
        let result = try await appModel.applyAutomatedReviewDecisions(
            plan.confirmCandidates,
            in: context
        )

        XCTAssertEqual(result.confirmedCount, 1)
        XCTAssertEqual(result.suppressedCount, 0)

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        XCTAssertNotNil(subscriptions.first { $0.canonicalName == "Dropbox" })
        XCTAssertEqual(subscriptions.first { $0.canonicalName == "GitHub" }?.status, .active)

        let aliases = try context.fetch(FetchDescriptor<MerchantAlias>())
        XCTAssertTrue(aliases.contains { $0.rawMerchant == "GITHUB" && $0.canonicalName == "GitHub" })
    }

    @MainActor
    func testAutomatedReviewLearnsStableServiceNameForProcessorDescriptors() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let candidate = makeAutomationSubscription(
            name: "ChatGPT $19.58 $19.58",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.72,
            category: "AI"
        )
        context.insert(candidate)
        context.insert(
            SubscriptionReviewRule(
                canonicalName: "ChatGPT $19.58 $19.58",
                overrideDisplayName: "Noisy ChatGPT"
            )
        )
        context.insert(
            MerchantCorrection(
                canonicalName: "ChatGPT $19.58 $19.58",
                isSubscription: true,
                correctedCadence: .monthly
            )
        )

        for offset in [-2, -1] {
            context.insert(
                makeAutomationTransaction(
                    merchant: "Openai",
                    amount: -19.58,
                    monthOffset: offset,
                    subscriptionID: candidate.id,
                    merchantKind: .subscriptionService,
                    affinity: 0.98
                )
            )
        }
        try context.save()

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [candidate],
            transactions: try context.fetch(FetchDescriptor<NormalizedTransaction>())
        )
        let result = try await appModel.applyAutomatedReviewDecisions(
            plan.confirmCandidates,
            in: context
        )

        XCTAssertEqual(result.confirmedCount, 1)
        XCTAssertEqual(candidate.canonicalName, "ChatGPT")
        XCTAssertEqual(candidate.displayName, "ChatGPT")

        let aliases = try context.fetch(FetchDescriptor<MerchantAlias>())
        XCTAssertTrue(aliases.contains { $0.rawMerchant == "Openai" && $0.canonicalName == "ChatGPT" })

        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        XCTAssertTrue(corrections.contains { $0.canonicalName == "ChatGPT" && $0.isSubscription })
        XCTAssertFalse(corrections.contains { $0.canonicalName == "ChatGPT $19.58 $19.58" })

        let rules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
        XCTAssertTrue(rules.contains { $0.canonicalName == "ChatGPT" })
        XCTAssertFalse(rules.contains { $0.canonicalName == "ChatGPT $19.58 $19.58" })
    }

    @MainActor
    func testAutomatedReviewDoesNotRewriteDistinctOpenAIProductToChatGPT() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let candidate = makeAutomationSubscription(
            name: "OpenAI API $20.00",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.72,
            category: "AI"
        )
        context.insert(candidate)

        for offset in [-2, -1] {
            context.insert(
                makeAutomationTransaction(
                    merchant: "Openai",
                    amount: -20,
                    monthOffset: offset,
                    subscriptionID: candidate.id,
                    merchantKind: .subscriptionService,
                    affinity: 0.98
                )
            )
        }
        try context.save()

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [candidate],
            transactions: try context.fetch(FetchDescriptor<NormalizedTransaction>())
        )
        let result = try await appModel.applyAutomatedReviewDecisions(
            plan.confirmCandidates,
            in: context
        )

        XCTAssertEqual(result.confirmedCount, 1)
        XCTAssertEqual(candidate.canonicalName, "OpenAI API")
        XCTAssertEqual(candidate.displayName, "OpenAI API")
    }

    @MainActor
    func testAutomatedReviewUsesLinkedChargeDateBeforePersistingConfirmedStatus() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let candidate = makeAutomationSubscription(
            name: "GitHub",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.91,
            category: "Software"
        )
        candidate.lastChargeDate = nil
        candidate.predictedNextChargeDate = Calendar.current.date(byAdding: .day, value: -120, to: .now)
        context.insert(candidate)

        for offset in [-1, 0] {
            context.insert(
                makeAutomationTransaction(
                    merchant: "GITHUB",
                    amount: -12,
                    monthOffset: offset,
                    subscriptionID: candidate.id,
                    merchantKind: .softwareOrSaaS,
                    affinity: 0.96
                )
            )
        }
        try context.save()

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [candidate],
            transactions: try context.fetch(FetchDescriptor<NormalizedTransaction>())
        )
        let result = try await appModel.applyAutomatedReviewDecisions(
            plan.confirmCandidates,
            in: context
        )

        XCTAssertEqual(result.confirmedCount, 1)
        XCTAssertEqual(candidate.status, .active)

        let rule = try XCTUnwrap(try context.fetch(FetchDescriptor<SubscriptionReviewRule>()).first)
        XCTAssertEqual(rule.overrideStatus, SubscriptionStatus.active)
    }

    @MainActor
    func testAutomatedReviewAppliesSuppressionCandidates() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let noise = makeAutomationSubscription(
            name: "Corner Market",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.24,
            category: "Groceries"
        )
        context.insert(noise)

        let transaction = makeAutomationTransaction(
            merchant: "CORNER MARKET",
            amount: -21.45,
            monthOffset: -1,
            subscriptionID: noise.id,
            merchantKind: .groceryRetailer,
            affinity: 0.05
        )
        context.insert(transaction)
        try context.save()

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [noise],
            transactions: [transaction]
        )
        let result = try await appModel.applyAutomatedReviewDecisions(
            plan.suppressCandidates,
            in: context
        )

        XCTAssertEqual(plan.suppressCandidates.map(\.displayName), ["Corner Market"])
        XCTAssertEqual(result.confirmedCount, 0)
        XCTAssertEqual(result.suppressedCount, 1)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(noise.status, .former)
        XCTAssertEqual(noise.libraryState, .inactive)

        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?.isSubscription, false)
    }

    @MainActor
    func testReviewAutomationKeepsSharedRawMerchantManual() async throws {
        let appModel = AppModel.testing()
        let candidate = makeAutomationSubscription(
            name: "Apple Music",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.91,
            category: "Streaming"
        )
        let existing = makeAutomationSubscription(
            name: "iCloud",
            status: .active,
            cadence: .monthly,
            confidence: 0.96,
            category: "Storage"
        )
        let transactions = [
            makeAutomationTransaction(
                merchant: "APPLE.COM/BILL",
                amount: -10.99,
                monthOffset: -2,
                subscriptionID: candidate.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "APPLE.COM/BILL",
                amount: -10.99,
                monthOffset: -1,
                subscriptionID: candidate.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "APPLE.COM/BILL",
                amount: -2.99,
                monthOffset: -1,
                subscriptionID: existing.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            )
        ]

        let plan = appModel.reviewAutomationPlan(
            subscriptions: [candidate, existing],
            transactions: transactions
        )

        XCTAssertTrue(plan.confirmCandidates.isEmpty)
        XCTAssertEqual(plan.manualCandidates.map(\.displayName), ["Apple Music"])
    }

    @MainActor
    func testAutomatedReviewRevalidatesStalePlanBeforeApplying() async throws {
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel.testing()

        let safe = makeAutomationSubscription(
            name: "GitHub",
            status: .needsReview,
            cadence: .monthly,
            confidence: 0.91,
            category: "Software"
        )
        context.insert(safe)
        for transaction in [
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -2,
                subscriptionID: safe.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            ),
            makeAutomationTransaction(
                merchant: "GITHUB",
                amount: -12,
                monthOffset: -1,
                subscriptionID: safe.id,
                merchantKind: .softwareOrSaaS,
                affinity: 0.96
            )
        ] {
            context.insert(transaction)
        }
        try context.save()

        let stalePlan = appModel.reviewAutomationPlan(
            subscriptions: [safe],
            transactions: try context.fetch(FetchDescriptor<NormalizedTransaction>())
        )
        XCTAssertEqual(stalePlan.confirmCandidates.map(\.displayName), ["GitHub"])

        safe.confidenceScore = 0.41
        try context.save()

        let result = try await appModel.applyAutomatedReviewDecisions(
            stalePlan.confirmCandidates,
            in: context
        )

        XCTAssertEqual(result.confirmedCount, 0)
        XCTAssertEqual(result.suppressedCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(safe.status, .needsReview)
    }
}

private extension CSVTransactionImporterTests {
    func makeExportSource() -> AppDataExportSource {
        AppDataExportSource(
            imports: makeExportImports(),
            subscriptions: makeExportSubscriptions(),
            transactions: makeExportTransactions(),
            classifications: makeExportClassifications(),
            aliases: makeExportAliases(),
            templates: makeExportTemplates(),
            reviewRules: makeExportReviewRules()
        )
    }

    func makePendingDraft(mapping: ColumnMappingConfig) -> TransactionImportDraft {
        TransactionImportDraft(
            fileName: "pending.csv",
            headers: ["Date", "Merchant", "Amount"],
            previewRows: [
                .init(
                    id: 0,
                    values: [
                        "Date": "2025-01-01",
                        "Merchant": "Netflix",
                        "Amount": "-15.49"
                    ]
                )
            ],
            rawRows: [[
                "Date": "2025-01-01",
                "Merchant": "Netflix",
                "Amount": "-15.49"
            ]],
            suggestedMapping: mapping,
            confidence: 0.95
        )
    }

    func insertPersistedImportLibrary(into context: ModelContext, mapping: ColumnMappingConfig) {
        let importRecord = makePersistedImportRecord(mapping: mapping)
        let subscription = makePersistedSubscription()
        let transaction = makePersistedTransaction(
            importRecordID: importRecord.id,
            subscriptionID: subscription.id
        )

        context.insert(importRecord)
        context.insert(subscription)
        context.insert(transaction)
        context.insert(makePersistedClassification())
        context.insert(makePersistedAlias())
        context.insert(makePersistedReviewRule())
        context.insert(ColumnMappingTemplate(config: mapping))
    }

    func makeExportImports() -> [ImportRecord] {
        [
            ImportRecord(
                fileName: "ledger.csv",
                sourceType: "csv",
                status: .analyzed,
                mappingSignature: "sig",
                importedTransactionCount: 2,
                detectedSubscriptionCount: 1,
                needsReviewSubscriptionCount: 1,
                suppressedRecurringCandidateCount: 2,
                recoveredRecurringCandidateCount: 1
            )
        ]
    }

    func makeExportSubscriptions() -> [Subscription] {
        [
            Subscription(
                canonicalName: "Netflix",
                displayName: "Netflix",
                status: .active,
                cadence: .monthly,
                priceAmount: Decimal(string: "15.49") ?? 15.49,
                priceCurrency: "USD",
                normalizedMonthlyAmount: Decimal(string: "15.49") ?? 15.49,
                lastChargeDate: nil,
                predictedNextChargeDate: nil,
                confidenceScore: 0.95
            )
        ]
    }

    func makeExportTransactions() -> [NormalizedTransaction] {
        [
            NormalizedTransaction(
                transactionDate: .now,
                transactionAmount: Decimal(string: "-15.49") ?? -15.49,
                merchantRaw: "NETFLIX *123",
                merchantNormalized: "Netflix"
            )
        ]
    }

    func makeExportClassifications() -> [MerchantClassification] {
        [makePersistedClassification()]
    }

    func makeExportAliases() -> [MerchantAlias] {
        [makePersistedAlias()]
    }

    func makeExportTemplates() -> [ColumnMappingTemplate] {
        [
            ColumnMappingTemplate(
                config: ColumnMappingConfig(
                    dateColumn: "Date",
                    descriptionColumn: "Memo",
                    amountColumn: "Amount",
                    merchantColumn: "Merchant",
                    categoryColumn: "Category",
                    accountColumn: "Account",
                    currencyColumn: "Currency",
                    debitSignConvention: .negative
                )
            )
        ]
    }

    func makeExportReviewRules() -> [SubscriptionReviewRule] {
        [
            SubscriptionReviewRule(
                canonicalName: "Netflix",
                overrideDisplayName: "Netflix Premium",
                overrideStatus: .active,
                overrideCadence: .annual,
                overridePriceAmount: Decimal(string: "185.88"),
                overridePriceCurrency: "EUR",
                overrideLastChargeDate: ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z"),
                overrideCategory: "Streaming",
                notes: "Keep this one",
                isFalsePositive: false,
                isUserConfirmed: true
            )
        ]
    }

    func makePersistedImportRecord(mapping: ColumnMappingConfig) -> ImportRecord {
        ImportRecord(
            fileName: "seed.csv",
            sourceType: "csv",
            status: .analyzed,
            mappingSignature: mapping.signature
        )
    }

    func makePersistedSubscription() -> Subscription {
        let subscription = Subscription(
            canonicalName: "Netflix",
            displayName: "Netflix",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(string: "15.49") ?? 15.49,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "15.49") ?? 15.49,
            lastChargeDate: .now,
            predictedNextChargeDate: .now,
            confidenceScore: 0.95,
            serviceCategory: "Streaming"
        )
        subscription.calendarEventIdentifier = "calendar"
        subscription.lastNotificationScheduledAt = .now
        return subscription
    }

    func makePersistedTransaction(
        importRecordID: UUID,
        subscriptionID: UUID
    ) -> NormalizedTransaction {
        NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-15.49") ?? -15.49,
            merchantRaw: "NETFLIX *123",
            merchantNormalized: "Netflix",
            currency: "USD",
            accountName: "Visa",
            category: "Streaming",
            memo: "Standard",
            merchantKind: .mediaStreaming,
            merchantSubscriptionAffinity: 0.98,
            importRecordID: importRecordID,
            subscriptionID: subscriptionID
        )
    }

    func makePersistedClassification() -> MerchantClassification {
        MerchantClassification(
            rawMerchant: "NETFLIX *123",
            result: MerchantClassificationResult(
                canonicalName: "Netflix",
                serviceCategory: "Streaming",
                merchantKind: .mediaStreaming,
                subscriptionAffinity: 0.98,
                confidence: 0.95
            )
        )
    }

    func makePersistedAlias() -> MerchantAlias {
        MerchantAlias(rawMerchant: "NETFLIX *123", canonicalName: "Netflix")
    }

    func makePersistedReviewRule() -> SubscriptionReviewRule {
        SubscriptionReviewRule(
            canonicalName: "Netflix",
            overrideDisplayName: "Netflix Premium"
        )
    }

    func makeAutomationSubscription(
        name: String,
        status: SubscriptionStatus,
        cadence: SubscriptionCadence,
        confidence: Double,
        category: String?
    ) -> Subscription {
        let lastChargeDate = Calendar.current.date(byAdding: .month, value: -1, to: .now)
        let nextChargeDate = cadence.advance(lastChargeDate ?? .now)
        return Subscription(
            canonicalName: name,
            displayName: name,
            status: status,
            cadence: cadence,
            priceAmount: Decimal(string: "12.00") ?? 12,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "12.00") ?? 12,
            lastChargeDate: lastChargeDate,
            predictedNextChargeDate: nextChargeDate,
            confidenceScore: confidence,
            serviceCategory: category
        )
    }

    func makeAutomationTransaction(
        merchant: String,
        amount: Decimal,
        monthOffset: Int,
        subscriptionID: UUID,
        importRecordID: UUID? = nil,
        merchantKind: MerchantKind,
        affinity: Double
    ) -> NormalizedTransaction {
        NormalizedTransaction(
            transactionDate: Calendar.current.date(byAdding: .month, value: monthOffset, to: .now) ?? .now,
            transactionAmount: amount,
            merchantRaw: merchant,
            merchantNormalized: merchant.capitalized,
            currency: "USD",
            accountName: "Visa",
            category: merchantKind.defaultServiceCategory,
            memo: "Recurring charge",
            merchantKind: merchantKind,
            merchantSubscriptionAffinity: affinity,
            importRecordID: importRecordID,
            subscriptionID: subscriptionID
        )
    }
}
