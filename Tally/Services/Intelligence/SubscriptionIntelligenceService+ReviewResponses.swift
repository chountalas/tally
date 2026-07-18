import Foundation

struct PriceChangeAnalysis {
    let subscription: Subscription
    let linkedTransactions: [NormalizedTransaction]
    let change: Double
    let score: AuditScore
}

extension SubscriptionIntelligenceService {
    @MainActor
    func priceChangeResponse(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) -> IntelligenceResponse {
        let subscriptions = tooling.allSubscriptions()
        let transactions = tooling.allTransactions()

        guard let analysis = priceChangeAnalysis(
            query: query,
            tooling: tooling,
            subscriptions: subscriptions,
            transactions: transactions
        ) else {
            return missingPriceHistoryResponse()
        }

        let subscription = analysis.subscription

        return IntelligenceResponse(
            headline: abs(analysis.change) < 0.03
                ? "\(subscription.displayName) looks stable"
                : "\(subscription.displayName) changed \(analysis.change.percentString)",
            summary: priceChangeSummary(subscription: subscription, change: analysis.change),
            evidence: priceChangeEvidence(for: analysis),
            actions: priceChangeActions(
                for: subscription,
                change: analysis.change,
                tooling: tooling
            ),
            followUps: [
                "Show the transactions behind this change.",
                "What else should I cancel?"
            ],
            confidence: analysis.linkedTransactions.count >= 2 ? 0.83 : 0.59
        )
    }

    @MainActor
    func merchantFixResponse(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) async -> IntelligenceResponse {
        let subject = merchantFixSubject(for: query)
        let history = tooling.merchantHistory(name: subject)
        let rawMerchant = history.first?.merchantRaw ?? subject
        let suggestedCanonical = await suggestedCanonicalName(
            rawMerchant: rawMerchant,
            history: history,
            tooling: tooling
        )
        let recentCategories = Set(history.compactMap(\.category)).sorted()

        return IntelligenceResponse(
            headline: "I would normalize this merchant to \(suggestedCanonical)",
            summary: merchantFixSummary(
                suggestedCanonical: suggestedCanonical,
                history: history,
                recentCategories: recentCategories
            ),
            evidence: merchantFixEvidence(from: history),
            actions: [
                tooling.draftAlias(rawMerchant: rawMerchant, canonicalName: suggestedCanonical)
            ],
            followUps: [
                "Why was it classified this way?",
                "What subscriptions use this merchant?"
            ],
            confidence: history.isEmpty ? 0.52 : 0.8
        )
    }
}

extension SubscriptionIntelligenceService {
    func priceChangeAnalysis(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling,
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction]
    ) -> PriceChangeAnalysis? {
        guard let subscription = targetSubscription(
            query: query,
            tooling: tooling,
            subscriptions: subscriptions
        ) else {
            return nil
        }

        let linkedTransactions = transactions
            .filter { $0.subscriptionID == subscription.id && $0.transactionAmount < 0 }
            .sorted { $0.transactionDate > $1.transactionDate }
        let prices = linkedTransactions.map { abs($0.transactionAmount.doubleValue) }
        let latest = prices.first ?? subscription.priceAmount.doubleValue
        let historicalPrices = Array(prices.dropFirst())
        let baseline = historicalPrices.isEmpty
            ? max(subscription.priceAmount.doubleValue, 0)
            : historicalPrices.reduce(0, +) / Double(historicalPrices.count)
        let change = baseline > 0 ? (latest - baseline) / baseline : 0
        let currentActiveSubscriptions = DashboardMetrics.currentActiveSubscriptions(
            from: subscriptions
        )
        let score = AuditEngine.score(
            subscription: subscription,
            allActive: currentActiveSubscriptions
        )

        return PriceChangeAnalysis(
            subscription: subscription,
            linkedTransactions: linkedTransactions,
            change: change,
            score: score
        )
    }

    func targetSubscription(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling,
        subscriptions: [Subscription]
    ) -> Subscription? {
        if let subscriptionID = query.subscriptionID {
            return tooling.subscriptionDetail(id: subscriptionID)
        }
        if let merchantName = query.merchantName {
            return subscriptions.first {
                $0.displayName.localizedStandardContains(merchantName) ||
                    $0.canonicalName.localizedStandardContains(merchantName)
            }
        }
        return DashboardMetrics(
            subscriptions: subscriptions,
            transactions: tooling.allTransactions()
        ).priceChangedSubscriptions.first
    }

    func priceChangeSummary(subscription: Subscription, change: Double) -> String {
        if abs(change) < 0.03 {
            return """
            Recent charges for \(subscription.displayName) are close to its earlier
            baseline, so there is not a strong price-change signal yet.
            """
        }

        return """
        The latest charge for \(subscription.displayName) is \(change.percentString)
        versus its earlier average, which is why it moved into review territory.
        """
    }

    func priceChangeEvidence(for analysis: PriceChangeAnalysis) -> [EvidenceReference] {
        var evidence = analysis.linkedTransactions.prefix(3).map { transaction in
            EvidenceReference(
                kind: .transaction,
                referenceID: transaction.id.uuidString,
                label: transaction.transactionDate.shortDateString,
                snippet: transaction.transactionAmount.currencyString(
                    code: transaction.currency ?? analysis.subscription.priceCurrency
                )
            )
        }
        evidence.insert(
            EvidenceReference(
                kind: .subscription,
                referenceID: analysis.subscription.id.uuidString,
                label: analysis.subscription.displayName,
                snippet: """
                Audit score \(analysis.score.cancelWorthiness)/100, cadence
                \(analysis.subscription.cadence.rawValue)
                """
            ),
            at: 0
        )
        return Array(evidence.prefix(4))
    }

    func priceChangeActions(
        for subscription: Subscription,
        change: Double,
        tooling: SubscriptionIntelligenceTooling
    ) -> [IntelligenceActionSuggestion] {
        [
            IntelligenceActionSuggestion(
                id: "subscription:\(subscription.id.uuidString)",
                title: "Open \(subscription.displayName)",
                action: .openSubscription(subscription.id),
                requiresConfirmation: false
            ),
            tooling.draftReviewUpdate(
                subscriptionID: subscription.id,
                fields: [
                    "status": SubscriptionStatus.needsReview.rawValue,
                    "notes": """
                    Copilot flagged a \(change.percentString) price change against the
                    earlier baseline.
                    """
                ]
            )
        ]
    }

    func merchantFixSubject(for query: IntelligenceQuery) -> String {
        query.rawMerchant ??
            query.merchantName ??
            query.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor
    func suggestedCanonicalName(
        rawMerchant: String,
        history: [NormalizedTransaction],
        tooling: SubscriptionIntelligenceTooling
    ) async -> String {
        if let aliasSuggestion = tooling.allAliases()
            .first(where: { $0.rawMerchant.localizedStandardContains(rawMerchant) })?
            .canonicalName {
            return aliasSuggestion
        }
        if let cachedSuggestion = tooling.allClassifications()
            .first(where: { $0.rawMerchant.localizedStandardContains(rawMerchant) })?
            .canonicalName {
            return cachedSuggestion
        }
        if let recent = history.first {
            return (try? await classifyMerchant(
                rawMerchant: recent.merchantRaw,
                memo: recent.memo,
                category: recent.category,
                amount: recent.transactionAmount
            ))?.canonicalName ?? heuristicClassifier.normalize(rawMerchant)
        }
        return heuristicClassifier.normalize(rawMerchant)
    }

    func merchantFixSummary(
        suggestedCanonical: String,
        history: [NormalizedTransaction],
        recentCategories: [String]
    ) -> String {
        guard history.isEmpty == false else {
            return """
            I do not have matching transaction history yet, so this is a best-effort
            local suggestion based on the merchant string alone.
            """
        }

        return """
        Recent matches suggest the merchant should roll up under \(suggestedCanonical).
        Categories seen:
        \(recentCategories.isEmpty ? "uncategorized" : recentCategories.joined(separator: ", ")).
        """
    }

    func merchantFixEvidence(from history: [NormalizedTransaction]) -> [EvidenceReference] {
        history.prefix(3).map { transaction in
            EvidenceReference(
                kind: .merchant,
                referenceID: transaction.id.uuidString,
                label: transaction.merchantRaw,
                snippet: """
                \(transaction.transactionAmount.currencyString(code: transaction.currency ?? "USD"))
                on \(transaction.transactionDate.shortDateString)
                """
            )
        }
    }
}

struct LocalMerchantSuggestionHeuristic {
    func normalize(_ rawMerchant: String) -> String {
        let uppercased = rawMerchant.uppercased()
        let words = uppercased
            .replacingOccurrences(of: #"[*#]\S+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(3)
            .map(\.capitalized)

        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
