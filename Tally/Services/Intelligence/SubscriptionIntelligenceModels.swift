import Foundation

enum IntelligenceEvidenceKind: String, Codable, Hashable, Sendable {
    case subscription
    case transaction
    case merchant
    case renewal
    case overlap
}

struct EvidenceReference: Identifiable, Codable, Hashable, Sendable {
    let kind: IntelligenceEvidenceKind
    let referenceID: String?
    let label: String
    let snippet: String

    var id: String {
        [kind.rawValue, referenceID ?? label].joined(separator: ":")
    }
}

enum IntelligenceActionKind: String, Codable, Hashable, Sendable {
    case openSubscription
    case createAliasDraft
    case draftReviewUpdate
    case openTab
}

enum IntelligenceNavigationRoute: String, Codable, Hashable, Sendable {
    case subscriptions
    case audit
    case calendar
    case transactions
}

struct IntelligenceActionSuggestion: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let kind: IntelligenceActionKind
    let title: String
    let payload: [String: String]
    let requiresConfirmation: Bool
}

struct IntelligenceResponse: Codable, Hashable, Sendable {
    let headline: String
    let summary: String
    let evidence: [EvidenceReference]
    let actions: [IntelligenceActionSuggestion]
    let followUps: [String]
    let confidence: Double
}

enum IntelligenceQueryKind: String, Codable, Hashable, Sendable {
    case savingsReview
    case upcomingRenewals
    case priceChangeExplanation
    case merchantFix
    case custom
}

struct IntelligenceQuery: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var kind: IntelligenceQueryKind
    var prompt: String
    var subscriptionID: UUID?
    var merchantName: String?
    var rawMerchant: String?
    var days: Int?

    init(
        id: UUID = UUID(),
        kind: IntelligenceQueryKind,
        prompt: String,
        subscriptionID: UUID? = nil,
        merchantName: String? = nil,
        rawMerchant: String? = nil,
        days: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.prompt = prompt
        self.subscriptionID = subscriptionID
        self.merchantName = merchantName
        self.rawMerchant = rawMerchant
        self.days = days
    }
}

protocol SubscriptionIntelligenceTooling {
    func allSubscriptions() -> [Subscription]
    func allTransactions() -> [NormalizedTransaction]
    func allAliases() -> [MerchantAlias]
    func allClassifications() -> [MerchantClassification]
    func libraryOverview() -> LibraryOverviewSnapshot
    func upcomingRenewals(days: Int) -> [Subscription]
    func subscriptionDetail(id: UUID) -> Subscription?
    func merchantHistory(name: String) -> [NormalizedTransaction]
    func overlapAnalysis() -> [OverlapGroup]
    func draftAlias(rawMerchant: String, canonicalName: String) -> IntelligenceActionSuggestion
    func draftReviewUpdate(
        subscriptionID: UUID,
        fields: [String: String]
    ) -> IntelligenceActionSuggestion
}

struct LibraryOverviewSnapshot {
    let monthlyRunRate: Decimal
    let annualizedSpend: Decimal
    let activeCount: Int
    let needsReviewCount: Int
}

struct LocalSubscriptionIntelligenceTooling: SubscriptionIntelligenceTooling {
    let subscriptions: [Subscription]
    let transactions: [NormalizedTransaction]
    let aliases: [MerchantAlias]
    let classifications: [MerchantClassification]

    func allSubscriptions() -> [Subscription] {
        subscriptions
    }

    func allTransactions() -> [NormalizedTransaction] {
        transactions
    }

    func allAliases() -> [MerchantAlias] {
        aliases
    }

    func allClassifications() -> [MerchantClassification] {
        classifications
    }

    func libraryOverview() -> LibraryOverviewSnapshot {
        let metrics = DashboardMetrics(
            subscriptions: subscriptions,
            transactions: transactions
        )
        return LibraryOverviewSnapshot(
            monthlyRunRate: metrics.monthlyRunRate,
            annualizedSpend: metrics.annualizedSpend,
            activeCount: metrics.activeCount,
            needsReviewCount: metrics.needsReviewCount
        )
    }

    func upcomingRenewals(days: Int) -> [Subscription] {
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: .now)
            ?? .distantFuture
        return subscriptions
            .filter {
                $0.status == .active &&
                    ($0.predictedNextChargeDate ?? .distantFuture) <= cutoff
            }
            .sorted {
                ($0.predictedNextChargeDate ?? .distantFuture) <
                    ($1.predictedNextChargeDate ?? .distantFuture)
            }
    }

    func subscriptionDetail(id: UUID) -> Subscription? {
        subscriptions.first(where: { $0.id == id })
    }

    func merchantHistory(name: String) -> [NormalizedTransaction] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.isEmpty == false else { return [] }

        return transactions
            .filter {
                $0.merchantNormalized.localizedStandardContains(query) ||
                    $0.merchantRaw.localizedStandardContains(query)
            }
            .sorted { $0.transactionDate > $1.transactionDate }
    }

    func overlapAnalysis() -> [OverlapGroup] {
        DashboardMetrics(
            subscriptions: subscriptions,
            transactions: transactions
        ).overlapGroups
    }

    func draftAlias(
        rawMerchant: String,
        canonicalName: String
    ) -> IntelligenceActionSuggestion {
        IntelligenceActionSuggestion(
            id: "alias:\(rawMerchant.lowercased()):\(canonicalName.lowercased())",
            kind: .createAliasDraft,
            title: "Save alias for \(rawMerchant)",
            payload: [
                "rawMerchant": rawMerchant,
                "canonicalName": canonicalName
            ],
            requiresConfirmation: true
        )
    }

    func draftReviewUpdate(
        subscriptionID: UUID,
        fields: [String: String]
    ) -> IntelligenceActionSuggestion {
        var payload = fields
        payload["subscriptionID"] = subscriptionID.uuidString

        return IntelligenceActionSuggestion(
            id: "review:\(subscriptionID.uuidString)",
            kind: .draftReviewUpdate,
            title: "Apply review update",
            payload: payload,
            requiresConfirmation: true
        )
    }
}

protocol SubscriptionIntelligenceGenerating: Sendable {
    var evidenceProviderKind: AIProviderKind? { get }

    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload
    func generateText(instructions: String, prompt: String) async throws -> String
    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult
    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult]
    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult
    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult
    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult
}

extension SubscriptionIntelligenceGenerating {
    var evidenceProviderKind: AIProviderKind? { nil }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult {
        SubscriptionEvidenceEvaluationResult(
            isSubscription: false,
            confidence: 0,
            likelyServiceName: nil,
            likelyPlanDescriptor: nil,
            positiveSignals: [],
            negativeSignals: ["Subscription evidence evaluation is unavailable for this provider."],
            reasonSummary: "The selected intelligence provider does not support structured subscription evidence evaluation."
        )
    }
}

enum SubscriptionIntelligenceRoute: String, Sendable {
    case savingsReview
    case upcomingRenewals
    case priceChangeExplanation
    case merchantFix
}

struct IntelligenceCopyPayload: Sendable {
    let headline: String
    let summary: String
    let followUps: [String]
}
