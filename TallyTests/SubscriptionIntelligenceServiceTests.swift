import Foundation
import Testing
@testable import Tally

@Suite("Subscription intelligence routing")
struct SubscriptionIntelligenceServiceTests {
    private struct TransactionFixture {
        let daysAgo: Int
        let amount: String
        let merchantRaw: String
        let merchantNormalized: String
        let memo: String
    }

    @Test func cancellationPromptRoutesToSavingsReview() {
        let service = SubscriptionIntelligenceService(generator: nil)
        let query = IntelligenceQuery(kind: .custom, prompt: "What can I cancel right now?")

        #expect(service.route(for: query) == .savingsReview)
    }

    @Test func renewalPromptProducesRenewalEvidence() async {
        let service = SubscriptionIntelligenceService(generator: nil)
        let tooling = makeTooling()
        let query = IntelligenceQuery(
            kind: .upcomingRenewals,
            prompt: "What renews in the next 30 days?",
            days: 30
        )

        let response = await service.respond(
            to: query,
            using: tooling
        )

        #expect(response.evidence.contains(where: { $0.kind == .renewal }))
        #expect(response.actions.contains(where: { $0.kind == .openTab }))
    }

    @Test func merchantFixProducesAliasDraft() async {
        let service = SubscriptionIntelligenceService(generator: nil)
        let tooling = makeTooling()

        let response = await service.respond(
            to: IntelligenceQuery(
                kind: .merchantFix,
                prompt: "Fix this merchant / create alias",
                merchantName: "NETFLIX.COM"
            ),
            using: tooling
        )

        #expect(response.actions.contains(where: { $0.kind == .createAliasDraft }))
    }

    @Test func malformedGeneratedCopyFallsBackToDeterministicDraft() async {
        let service = SubscriptionIntelligenceService(generator: InvalidCopyGenerator())
        let tooling = makeTooling()

        let response = await service.respond(
            to: IntelligenceQuery(kind: .savingsReview, prompt: "What can I cancel?"),
            using: tooling
        )

        #expect(response.headline == "You likely have a trim opportunity")
        #expect(response.summary.localizedStandardContains("per month"))
    }

    @Test func validGeneratedCopyOverridesDraftText() async {
        let service = SubscriptionIntelligenceService(generator: ValidCopyGenerator())
        let tooling = makeTooling()

        let response = await service.respond(
            to: IntelligenceQuery(kind: .savingsReview, prompt: "What can I cancel?"),
            using: tooling
        )

        #expect(response.headline == "Custom headline")
        #expect(response.summary == "Custom summary")
        #expect(response.followUps == ["What renews next?", "Which merchant should I fix?"])
    }

    @MainActor
    @Test func spotlightIndexerBuildsSubscriptionAndRenewalItems() {
        let tooling = makeTooling()
        let indexer = SubscriptionSpotlightIndexer()

        let items = indexer.searchableItems(for: tooling.subscriptions)

        #expect(items.count >= tooling.subscriptions.count)
        #expect(items.contains(where: { $0.uniqueIdentifier.hasPrefix("subscription.") }))
        #expect(items.contains(where: { $0.uniqueIdentifier.hasPrefix("renewal.") }))
    }

    @MainActor
    @Test func spotlightIndexerSkipsStaleAnnualRenewalItems() {
        let stale = Subscription(
            canonicalName: "Old Annual App",
            displayName: "Old Annual App",
            status: .active,
            cadence: .annual,
            priceAmount: Decimal(string: "120") ?? 120,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10") ?? 10,
            lastChargeDate: Calendar.current.date(byAdding: .day, value: -593, to: .now),
            predictedNextChargeDate: Calendar.current.date(byAdding: .day, value: -228, to: .now),
            confidenceScore: 0.92,
            serviceCategory: "Software"
        )
        let indexer = SubscriptionSpotlightIndexer()

        let items = indexer.searchableItems(for: [stale])
        let subscriptionItem = items.first {
            $0.uniqueIdentifier == "subscription.\(stale.id.uuidString)"
        }

        #expect(subscriptionItem != nil)
        #expect(subscriptionItem?.attributeSet.contentDescription?.localizedStandardContains("Former") == true)
        #expect(subscriptionItem?.attributeSet.contentDescription?.localizedStandardContains("Active") == false)
        #expect(items.contains(where: { $0.uniqueIdentifier == "renewal.\(stale.id.uuidString)" }) == false)
    }

    @MainActor
    @Test func spotlightIndexerDropsAnnualRenewalAfterGraceDayExpires() {
        let calendar = Calendar.current
        let beforeGraceExpires = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 8, hour: 12)
        ) ?? .now
        let afterGraceExpires = calendar.date(
            from: DateComponents(year: 2026, month: 7, day: 9, hour: 12)
        ) ?? .now
        let annual = Subscription(
            canonicalName: "Annual App",
            displayName: "Annual App",
            status: .active,
            cadence: .annual,
            priceAmount: Decimal(string: "120") ?? 120,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10") ?? 10,
            lastChargeDate: calendar.date(from: DateComponents(year: 2025, month: 6, day: 17, hour: 12)),
            predictedNextChargeDate: calendar.date(from: DateComponents(year: 2026, month: 6, day: 17, hour: 12)),
            confidenceScore: 0.92,
            serviceCategory: "Software"
        )
        let indexer = SubscriptionSpotlightIndexer()

        let beforeItems = indexer.searchableItems(
            for: [annual],
            referenceDate: beforeGraceExpires
        )
        let afterItems = indexer.searchableItems(
            for: [annual],
            referenceDate: afterGraceExpires
        )

        #expect(beforeItems.contains(where: { $0.uniqueIdentifier == "renewal.\(annual.id.uuidString)" }))
        #expect(afterItems.contains(where: { $0.uniqueIdentifier == "renewal.\(annual.id.uuidString)" }) == false)
    }

    @Test func priceChangeAnalysisIgnoresStaleActivePeersForAuditScore() {
        let service = SubscriptionIntelligenceService(generator: nil)
        let target = makeNetflixSubscription()
        target.serviceCategory = "Software"
        target.priceChangePercent = 0.11
        let stalePeer = Subscription(
            canonicalName: "Old Annual App",
            displayName: "Old Annual App",
            status: .active,
            cadence: .annual,
            priceAmount: Decimal(string: "120") ?? 120,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "10") ?? 10,
            lastChargeDate: Calendar.current.date(byAdding: .day, value: -593, to: .now),
            predictedNextChargeDate: Calendar.current.date(byAdding: .day, value: -228, to: .now),
            confidenceScore: 0.92,
            serviceCategory: "Software"
        )
        let transactions = makeNetflixTransactions(subscriptionID: target.id)
        let tooling = LocalSubscriptionIntelligenceTooling(
            subscriptions: [target, stalePeer],
            transactions: transactions,
            aliases: [],
            classifications: []
        )

        let analysis = service.priceChangeAnalysis(
            query: IntelligenceQuery(
                kind: .priceChangeExplanation,
                prompt: "Why did this price change?",
                subscriptionID: target.id
            ),
            tooling: tooling,
            subscriptions: tooling.subscriptions,
            transactions: transactions
        )

        #expect(analysis?.score.reasons.contains { $0.localizedStandardContains("Overlaps") } == false)
    }

    private func makeTooling() -> LocalSubscriptionIntelligenceTooling {
        let netflix = makeNetflixSubscription()
        netflix.priceChangePercent = 0.11

        let hulu = makeHuluSubscription()
        let transactions = makeTransactions(netflixID: netflix.id, huluID: hulu.id)

        return LocalSubscriptionIntelligenceTooling(
            subscriptions: [netflix, hulu],
            transactions: transactions,
            aliases: [],
            classifications: []
        )
    }

    private func makeNetflixSubscription() -> Subscription {
        Subscription(
            canonicalName: "Netflix",
            displayName: "Netflix",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(string: "19.99") ?? 19.99,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "19.99") ?? 19.99,
            lastChargeDate: Calendar.current.date(byAdding: .day, value: -3, to: .now),
            predictedNextChargeDate: Calendar.current.date(byAdding: .day, value: 9, to: .now),
            confidenceScore: 0.94,
            serviceCategory: "Streaming"
        )
    }

    private func makeHuluSubscription() -> Subscription {
        Subscription(
            canonicalName: "Hulu",
            displayName: "Hulu",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(string: "8.99") ?? 8.99,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "8.99") ?? 8.99,
            lastChargeDate: Calendar.current.date(byAdding: .day, value: -5, to: .now),
            predictedNextChargeDate: Calendar.current.date(byAdding: .day, value: 14, to: .now),
            confidenceScore: 0.9,
            serviceCategory: "Streaming"
        )
    }

    private func makeTransactions(netflixID: UUID, huluID: UUID) -> [NormalizedTransaction] {
        makeNetflixTransactions(subscriptionID: netflixID) + [
            makeHuluTransaction(subscriptionID: huluID)
        ]
    }

    private func makeNetflixTransactions(
        subscriptionID: UUID
    ) -> [NormalizedTransaction] {
        [
            makeTransaction(
                TransactionFixture(
                    daysAgo: 30,
                    amount: "-17.99",
                    merchantRaw: "NETFLIX.COM",
                    merchantNormalized: "Netflix",
                    memo: "Standard plan"
                ),
                subscriptionID: subscriptionID
            ),
            makeTransaction(
                TransactionFixture(
                    daysAgo: 3,
                    amount: "-19.99",
                    merchantRaw: "NETFLIX.COM",
                    merchantNormalized: "Netflix",
                    memo: "Standard plan"
                ),
                subscriptionID: subscriptionID
            )
        ]
    }

    private func makeHuluTransaction(
        subscriptionID: UUID
    ) -> NormalizedTransaction {
        makeTransaction(
            TransactionFixture(
                daysAgo: 5,
                amount: "-8.99",
                merchantRaw: "HULU*BUNDLE",
                merchantNormalized: "Hulu",
                memo: "Bundle"
            ),
            subscriptionID: subscriptionID
        )
    }

    private func makeTransaction(
        _ fixture: TransactionFixture,
        subscriptionID: UUID
    ) -> NormalizedTransaction {
        NormalizedTransaction(
            transactionDate: Calendar.current.date(
                byAdding: .day,
                value: -fixture.daysAgo,
                to: .now
            ) ?? .now,
            transactionAmount: Decimal(string: fixture.amount) ?? 0,
            merchantRaw: fixture.merchantRaw,
            merchantNormalized: fixture.merchantNormalized,
            currency: "USD",
            accountName: "Visa",
            category: "Streaming",
            memo: fixture.memo,
            subscriptionID: subscriptionID
        )
    }
}

private struct InvalidCopyGenerator: SubscriptionIntelligenceGenerating {
    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        IntelligenceCopyPayload(headline: "", summary: "", followUps: [])
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        ""
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
            subscriptionAffinity: 0.3,
            confidence: 0.5
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
            confidence: 0.5,
            reasonSummary: "",
            negativeSignals: []
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        SingleChargeEvaluationResult(
            isLikelySubscription: false,
            confidence: 0.5,
            reasonSummary: "",
            negativeSignals: []
        )
    }
}

private struct ValidCopyGenerator: SubscriptionIntelligenceGenerating {
    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        IntelligenceCopyPayload(
            headline: "Custom headline",
            summary: "Custom summary",
            followUps: ["What renews next?", "Which merchant should I fix?"]
        )
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        "Custom text"
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult {
        MerchantClassificationResult(
            canonicalName: "Netflix",
            serviceCategory: "Streaming",
            merchantKind: .mediaStreaming,
            subscriptionAffinity: 0.98,
            confidence: 0.95
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        Dictionary(uniqueKeysWithValues: requests.map {
            (
                $0.rawMerchant,
                MerchantClassificationResult(
                    canonicalName: "Netflix",
                    serviceCategory: "Streaming",
                    merchantKind: .mediaStreaming,
                    subscriptionAffinity: 0.98,
                    confidence: 0.95
                )
            )
        })
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult {
        RecurringClusterEvaluationResult(
            isSubscription: true,
            confidence: 0.92,
            reasonSummary: "Stable recurring streaming charge.",
            negativeSignals: []
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        SingleChargeEvaluationResult(
            isLikelySubscription: true,
            confidence: 0.91,
            reasonSummary: "Strong single-charge subscription signals.",
            negativeSignals: []
        )
    }
}

@Suite("Manual subscription draft advisor")
struct EmbeddedManualSubscriptionDraftAdvisorTests {
    @Test func knownServiceSuggestionPrefillsIdentityAndCategory() async throws {
        let advisor = ManualSubscriptionDraftAdvisor()

        let suggestion = try await advisor.suggest(
            for: ManualSubscriptionDraftInput(
                displayName: "Netflix.com",
                priceAmount: Decimal(string: "19.99"),
                cadence: .monthly,
                status: .active,
                category: nil,
                notes: nil,
                websiteURL: nil,
                reminderDaysBefore: nil,
                replacementSubscriptionID: nil
            ),
            existingSubscriptions: []
        )

        #expect(suggestion?.serviceIdentifier == "brand-netflix")
        #expect(suggestion?.category == "Streaming")
        #expect(suggestion?.reminderDaysBefore == nil)
    }

    @Test func formerSubscriptionSuggestionLinksSingleCategoryReplacementAndReminder() async throws {
        let advisor = ManualSubscriptionDraftAdvisor()
        let replacement = Subscription(
            canonicalName: "YouTube Premium",
            displayName: "YouTube Premium",
            status: .active,
            cadence: .monthly,
            priceAmount: Decimal(string: "18.99") ?? 18.99,
            priceCurrency: "USD",
            normalizedMonthlyAmount: Decimal(string: "18.99") ?? 18.99,
            lastChargeDate: .now,
            predictedNextChargeDate: Calendar.current.date(byAdding: .day, value: 24, to: .now),
            confidenceScore: 0.95,
            serviceCategory: "Music",
            serviceIdentifier: "brand-youtube"
        )

        let suggestion = try await advisor.suggest(
            for: ManualSubscriptionDraftInput(
                displayName: "Spotify",
                priceAmount: Decimal(string: "119.99"),
                cadence: .annual,
                status: .former,
                category: nil,
                notes: "Annual plan",
                websiteURL: nil,
                reminderDaysBefore: nil,
                replacementSubscriptionID: nil
            ),
            existingSubscriptions: [replacement]
        )

        #expect(suggestion?.category == "Music")
        #expect(suggestion?.reminderDaysBefore == 30)
        #expect(suggestion?.replacementSubscriptionID == replacement.id)
        #expect(suggestion?.summary.localizedStandardContains("replacement") == true)
    }
}
