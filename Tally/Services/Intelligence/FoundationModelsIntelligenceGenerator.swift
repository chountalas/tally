import Foundation

extension SubscriptionIntelligenceService {
    func emptySavingsResponse() -> IntelligenceResponse {
        IntelligenceResponse(
            headline: "Your library needs transaction data first",
            summary: """
            Import a CSV, Excel, OFX, or QFX file to detect subscriptions before
            the copilot can recommend savings.
            """,
            evidence: [],
            actions: [
                IntelligenceActionSuggestion(
                    id: "tab:transactions",
                    kind: .openTab,
                    title: "Open transactions",
                    payload: ["route": IntelligenceNavigationRoute.transactions.rawValue],
                    requiresConfirmation: false
                )
            ],
            followUps: [
                "What renews soon once I import data?"
            ],
            confidence: 0.35
        )
    }

    func missingPriceHistoryResponse() -> IntelligenceResponse {
        IntelligenceResponse(
            headline: "Pick a subscription with a price history",
            summary: """
            I could not find a specific subscription to analyze. Open one from the
            subscriptions tab and ask again from its detail page.
            """,
            evidence: [],
            actions: [
                IntelligenceActionSuggestion(
                    id: "tab:subscriptions",
                    kind: .openTab,
                    title: "Open subscriptions",
                    payload: ["route": IntelligenceNavigationRoute.subscriptions.rawValue],
                    requiresConfirmation: false
                )
            ],
            followUps: [
                "What renews soon?",
                "What can I cancel?"
            ],
            confidence: 0.4
        )
    }
}

#if canImport(FoundationModels)
import FoundationModels

@available(iOS 26.0, macOS 26.0, *)
struct FoundationModelsIntelligenceGenerator: SubscriptionIntelligenceGenerating {
    private let deterministicOptions = GenerationOptions(temperature: 0)

    var evidenceProviderKind: AIProviderKind? { .appleIntelligence }

    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general),
            instructions: """
            You are refining a response for a local-first subscription tracking copilot.
            Preserve the evidence and actions already selected by the app.
            Only rewrite the headline, summary, and follow-up prompts.
            Be concise, specific, and grounded strictly in the facts provided.
            """
        )

        let response = try await session.respond(
            to: """
            Route: \(route.rawValue)
            User query: \(query.prompt)
            Facts:
            \(facts)
            """,
            generating: GeneratedCopyEnvelope.self,
            options: deterministicOptions
        )

        return IntelligenceCopyPayload(
            headline: response.content.headline,
            summary: response.content.summary,
            followUps: response.content.followUps
        )
    }

    func generateText(instructions: String, prompt: String) async throws -> String {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .general),
            instructions: instructions
        )

        let response = try await session.respond(to: prompt, options: deterministicOptions)
        return response.content
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Classify transaction merchants for Tally, a privacy-first subscription tracker.
            Return a stable canonical brand name, a compact service category, the merchant's business type,
            a subscription affinity score between 0 and 1, and an overall confidence score between 0 and 1.
            Focus on merchant type, not whether this single charge is definitely a subscription.
            Repeated visits to grocery stores, restaurants, chiropractors, therapists, salons, pharmacies,
            gas stations, and marketplaces are usually not subscriptions.
            Favor stable consumer-facing brand names. If the evidence is weak, lower the confidence.
            """
        )

        let response = try await session.respond(
            to: """
            Merchant: \(rawMerchant)
            Memo: \(memo ?? "None")
            Category: \(category ?? "None")
            Amount: \(amount)
            """,
            generating: MerchantClassificationPayload.self,
            options: deterministicOptions
        )

        return MerchantClassificationResult(
            canonicalName: response.content.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines),
            serviceCategory: response.content.serviceCategory.trimmingCharacters(in: .whitespacesAndNewlines),
            merchantKind: MerchantKind(rawValue: response.content.merchantKind) ?? .unknown,
            subscriptionAffinity: min(max(response.content.subscriptionAffinity, 0), 1),
            confidence: min(max(response.content.confidence, 0), 1)
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Classify transaction merchants for Tally, a privacy-first subscription tracker.
            Return exactly one classification for each merchant item using its merchantIndex.
            Return merchant identity, compact category, merchant business type, subscription affinity, and confidence.
            Repeated visits to grocery stores, restaurants, medical providers, chiropractors, salons, pharmacies,
            gas stations, and marketplaces are usually not subscriptions.
            Favor stable consumer-facing brand names. If the evidence is weak, lower the confidence.
            """
        )

        let prompt = requests.enumerated().map { index, request in
            """
            merchantIndex: \(index)
            Merchant: \(request.rawMerchant)
            Memo: \(request.memo ?? "None")
            Category: \(request.category ?? "None")
            Amount: \(request.amount)
            """
        }.joined(separator: "\n\n")

        let response = try await session.respond(
            to: prompt,
            generating: MerchantBatchClassificationEnvelope.self,
            options: deterministicOptions
        )

        var results: [String: MerchantClassificationResult] = [:]
        for payload in response.content.classifications
        where requests.indices.contains(payload.merchantIndex) {
            let merchant = requests[payload.merchantIndex].rawMerchant
            results[merchant] = MerchantClassificationResult(
                canonicalName: payload.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines),
                serviceCategory: payload.serviceCategory.trimmingCharacters(in: .whitespacesAndNewlines),
                merchantKind: MerchantKind(rawValue: payload.merchantKind) ?? .unknown,
                subscriptionAffinity: min(max(payload.subscriptionAffinity, 0), 1),
                confidence: min(max(payload.confidence, 0), 1)
            )
        }

        return results
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Evaluate whether a recurring charge cluster is a true subscription for Tally, a privacy-first subscription tracker.
            Look at the full cluster evidence, not just a single transaction.
            Repeated grocery trips, marketplace orders, restaurants, salons, pharmacies, and ad hoc retail
            spending are usually not subscriptions unless there is explicit membership, plan, autopay, or
            subscription wording.
            IMPORTANT EDGE CASES:
            - Gym memberships, recurring therapy memberships, and wellness subscriptions with "membership",
              "monthly", or "plan" wording ARE subscriptions even though the merchant is medical/wellness.
            - Monthly or annual charges to membership retailers (Costco, Sam's Club, Walmart+) with membership
              wording are subscriptions.
            - SaaS charges via payment processors (Stripe, Paddle, Gumroad) are very likely subscriptions.
            Base your decision on the evidence. High-confidence signals (consistent timing + subscription wording
            + known subscription merchant type) warrant high confidence. Low or contradictory signals warrant low
            confidence. Do not hedge when evidence is clear in either direction.
            Return a boolean decision, confidence from 0 to 1, a concise reason summary, and any negative signals.
            """
        )

        let response = try await session.respond(
            to: """
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant variants: \(input.rawMerchantVariants.joined(separator: ", "))
            Sample memos: \(input.sampleMemos.joined(separator: " | "))
            Sample categories: \(input.sampleCategories.joined(separator: ", "))
            Charge count: \(input.chargeCount)
            Date intervals: \(input.intervals.map(String.init).joined(separator: ", "))
            First charge date: \(input.firstChargeDate?.ISO8601Format() ?? "None")
            Last charge date: \(input.lastChargeDate?.ISO8601Format() ?? "None")
            Amount minimum: \(input.amountMinimum)
            Amount maximum: \(input.amountMaximum)
            Amount variation: \(input.amountVariation)
            Detected cadence: \(input.detectedCadence.rawValue)
            Merchant kind prior: \(input.merchantKind.rawValue)
            Merchant subscription affinity: \(input.subscriptionAffinity)
            Classification confidence: \(input.classificationConfidence)
            Interval consistency: \(input.intervalConsistency)
            Amount stability: \(input.amountStability)
            Keyword support: \(input.keywordSupport)
            Descriptor strength: \(input.descriptorStrength)
            Negative penalty: \(input.negativePenalty)
            """,
            generating: RecurringClusterEvaluationPayload.self,
            options: deterministicOptions
        )

        return RecurringClusterEvaluationResult(
            isSubscription: response.content.isSubscription,
            confidence: min(max(response.content.confidence, 0), 1),
            reasonSummary: response.content.reasonSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            negativeSignals: response.content.negativeSignals
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Evaluate whether a single recent charge is likely the start or renewal of a subscription
            for Tally, a privacy-first subscription tracker.
            Be conservative. Grocery trips, marketplace orders, restaurants, salons, pharmacies, travel,
            and ad hoc shopping are usually not subscriptions unless there is explicit membership, plan,
            annual, monthly, renewal, or subscription wording.
            IMPORTANT EDGE CASES:
            - Gym memberships and recurring wellness subscriptions with "membership" or "monthly" wording
              ARE subscriptions.
            - SaaS charges via payment processors (Stripe, Paddle, Gumroad, Shopify) are very likely subscriptions.
            Base your decision on the evidence. SaaS, streaming, membership, and utility merchants with
            explicit plan language warrant high confidence. Ambiguous merchants warrant lower confidence.
            Return a boolean decision, confidence from 0 to 1, a concise reason summary, and any negative signals.
            """
        )

        let response = try await session.respond(
            to: """
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant: \(input.rawMerchant)
            Memo: \(input.memo ?? "None")
            Category: \(input.category ?? "None")
            Amount: \(input.amount)
            Transaction date: \(input.transactionDate.ISO8601Format())
            Suggested cadence: \(input.suggestedCadence.rawValue)
            Merchant kind prior: \(input.merchantKind.rawValue)
            Merchant subscription affinity: \(input.subscriptionAffinity)
            Classification confidence: \(input.classificationConfidence)
            """,
            generating: SingleChargeEvaluationPayload.self,
            options: deterministicOptions
        )

        return SingleChargeEvaluationResult(
            isLikelySubscription: response.content.isLikelySubscription,
            confidence: min(max(response.content.confidence, 0), 1),
            reasonSummary: response.content.reasonSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            negativeSignals: response.content.negativeSignals
        )
    }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult {
        let session = LanguageModelSession(
            model: SystemLanguageModel(useCase: .contentTagging),
            instructions: """
            Evaluate structured subscription evidence for Tally, a privacy-first subscription tracker.
            You are not the final decision maker. The app combines your bounded output with deterministic
            rules, expected occurrences, merchant identity, and transaction history.
            Focus on contradictions, processor ambiguity, service identity, trial-to-paid patterns,
            and false-positive categories.
            """
        )

        let response = try await session.respond(
            to: """
            Candidate key: \(input.candidateKey)
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant variants: \(input.rawMerchantVariants.joined(separator: ", "))
            Memo samples: \(input.memoSamples.joined(separator: " | "))
            Category samples: \(input.categorySamples.joined(separator: " | "))
            Service profile: \(input.serviceProfileName ?? "None")
            Merchant kind: \(input.merchantKind.rawValue)
            Subscription affinity: \(input.subscriptionAffinity)
            Schedule summary: \(input.scheduleSummary)
            Occurrence summary: \(input.occurrenceSummary)
            Amount summary: \(input.amountSummary)
            Negative signals: \(input.negativeSignals.joined(separator: " | "))
            User rule summary: \(input.userRuleSummary ?? "None")
            """,
            generating: SubscriptionEvidenceEvaluationPayload.self,
            options: deterministicOptions
        )

        return SubscriptionEvidenceEvaluationResult(
            isSubscription: response.content.isSubscription,
            confidence: min(max(response.content.confidence, 0), 1),
            likelyServiceName: response.content.likelyServiceName,
            likelyPlanDescriptor: response.content.likelyPlanDescriptor,
            positiveSignals: response.content.positiveSignals,
            negativeSignals: response.content.negativeSignals,
            reasonSummary: response.content.reasonSummary
        )
    }
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct GeneratedCopyEnvelope {
    let headline: String
    let summary: String
    let followUps: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct MerchantClassificationPayload {
    @Guide(description: "A stable consumer-facing merchant name such as Netflix or Adobe.")
    let canonicalName: String

    @Guide(
        description: """
        A short service category such as Streaming, Music, Software, Storage, Membership,
        Utilities, Retail, or Uncategorized.
        """
    )
    let serviceCategory: String

    @Guide(
        description: """
        One of: subscription_service, membership_retailer, marketplace, grocery_retailer,
        restaurant, medical_or_wellness_provider, transport_or_travel, utility_or_biller,
        general_retail, software_or_saas, media_streaming, unknown.
        """
    )
    let merchantKind: String

    @Guide(.range(0.0...1.0))
    let subscriptionAffinity: Double

    @Guide(.range(0.0...1.0))
    let confidence: Double
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct MerchantBatchClassificationEnvelope {
    let classifications: [MerchantBatchClassificationPayload]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct MerchantBatchClassificationPayload {
    let merchantIndex: Int

    @Guide(description: "A stable consumer-facing merchant name such as Netflix or Adobe.")
    let canonicalName: String

    @Guide(
        description: """
        A short service category such as Streaming, Music, Software, Storage, Membership,
        Utilities, Retail, or Uncategorized.
        """
    )
    let serviceCategory: String

    @Guide(
        description: """
        One of: subscription_service, membership_retailer, marketplace, grocery_retailer,
        restaurant, medical_or_wellness_provider, transport_or_travel, utility_or_biller,
        general_retail, software_or_saas, media_streaming, unknown.
        """
    )
    let merchantKind: String

    @Guide(.range(0.0...1.0))
    let subscriptionAffinity: Double

    @Guide(.range(0.0...1.0))
    let confidence: Double
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct RecurringClusterEvaluationPayload {
    let isSubscription: Bool

    @Guide(.range(0.0...1.0))
    let confidence: Double

    let reasonSummary: String
    let negativeSignals: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SingleChargeEvaluationPayload {
    let isLikelySubscription: Bool

    @Guide(.range(0.0...1.0))
    let confidence: Double

    let reasonSummary: String
    let negativeSignals: [String]
}

@available(iOS 26.0, macOS 26.0, *)
@Generable
private struct SubscriptionEvidenceEvaluationPayload {
    let isSubscription: Bool

    @Guide(.range(0.0...1.0))
    let confidence: Double

    let likelyServiceName: String?
    let likelyPlanDescriptor: String?
    let positiveSignals: [String]
    let negativeSignals: [String]
    let reasonSummary: String
}
#endif
