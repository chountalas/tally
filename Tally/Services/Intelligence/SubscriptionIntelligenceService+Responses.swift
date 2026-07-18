import Foundation

extension SubscriptionIntelligenceService {
    @MainActor
    func draftResponse(
        for route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) async -> IntelligenceResponse {
        switch route {
        case .savingsReview:
            return savingsResponse(query: query, tooling: tooling)
        case .upcomingRenewals:
            return renewalsResponse(query: query, tooling: tooling)
        case .priceChangeExplanation:
            return priceChangeResponse(query: query, tooling: tooling)
        case .merchantFix:
            return await merchantFixResponse(query: query, tooling: tooling)
        }
    }

    @MainActor
    func savingsResponse(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) -> IntelligenceResponse {
        let subscriptions = tooling.allSubscriptions()
        let transactions = tooling.allTransactions()
        let metrics = DashboardMetrics(subscriptions: subscriptions, transactions: transactions)

        guard metrics.activeCount > 0 else {
            return emptySavingsResponse()
        }

        var summaryParts = [baseSavingsSummary(metrics: metrics)]
        var evidence: [EvidenceReference] = []
        var actions: [IntelligenceActionSuggestion] = []
        let topOverlap = tooling.overlapAnalysis().first
        let topIncrease = metrics.priceChangedSubscriptions.first

        appendSavingsOverlap(
            topOverlap,
            summaryParts: &summaryParts,
            evidence: &evidence,
            actions: &actions
        )
        appendSavingsIncrease(
            topIncrease,
            tooling: tooling,
            summaryParts: &summaryParts,
            evidence: &evidence,
            actions: &actions
        )
        actions.append(openAuditAction())

        return IntelligenceResponse(
            headline: topOverlap == nil
                ? "Savings opportunities look limited"
                : "You likely have a trim opportunity",
            summary: summaryParts.joined(separator: " "),
            evidence: Array(evidence.prefix(3)),
            actions: Array(actions.prefix(3)),
            followUps: [
                "What renews in the next 30 days?",
                "Why did one of these prices change?",
                "Which overlap should I cut first?"
            ],
            confidence: topOverlap == nil && topIncrease == nil ? 0.58 : 0.79
        )
    }

    @MainActor
    func renewalsResponse(
        query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) -> IntelligenceResponse {
        let days = query.days ?? 30
        let renewals = tooling.upcomingRenewals(days: days)

        guard renewals.isEmpty == false else {
            return emptyRenewalsResponse(days: days)
        }

        let upcoming = Array(renewals.prefix(3))
        let totalUpcoming = upcoming.reduce(Decimal.zero) { $0 + $1.priceAmount }

        return IntelligenceResponse(
            headline: "\(renewals.count) renewal\(renewals.count == 1 ? "" : "s") are coming up",
            summary: """
            The next \(days) days include about \(totalUpcoming.currencyString()) of
            scheduled renewals, led by \(upcoming.map(\.displayName).joined(separator: ", ")).
            """,
            evidence: renewalEvidence(for: upcoming),
            actions: renewalActions(for: renewals.first),
            followUps: [
                "Which of these should I review first?",
                "What can I cancel before it renews?"
            ],
            confidence: 0.88
        )
    }

}

extension SubscriptionIntelligenceService {
    func baseSavingsSummary(metrics: DashboardMetrics) -> String {
        """
        You are carrying \(metrics.monthlyRunRate.currencyString()) per month across
        \(metrics.activeCount) active subscriptions.
        """
    }

    func appendSavingsOverlap(
        _ overlap: OverlapGroup?,
        summaryParts: inout [String],
        evidence: inout [EvidenceReference],
        actions: inout [IntelligenceActionSuggestion]
    ) {
        guard let overlap else {
            return
        }

        summaryParts.append(
            """
            The biggest overlap is \(overlap.category) at
            \(overlap.monthlyExposure.currencyString()) per month.
            """
        )
        evidence.append(
            EvidenceReference(
                kind: .overlap,
                referenceID: overlap.category.lowercased(),
                label: overlap.category,
                snippet: overlap.subscriptions.map(\.displayName).joined(separator: ", ")
            )
        )
        if let first = overlap.subscriptions.first {
            actions.append(
                IntelligenceActionSuggestion(
                    id: "subscription:\(first.id.uuidString)",
                    title: "Open \(first.displayName)",
                    action: .openSubscription(first.id),
                    requiresConfirmation: false
                )
            )
        }
    }

    func appendSavingsIncrease(
        _ subscription: Subscription?,
        tooling: SubscriptionIntelligenceTooling,
        summaryParts: inout [String],
        evidence: inout [EvidenceReference],
        actions: inout [IntelligenceActionSuggestion]
    ) {
        guard let subscription, let pct = subscription.priceChangePercent else {
            return
        }

        summaryParts.append(
            "\(subscription.displayName) is up \(pct.percentString) from its earlier baseline."
        )
        evidence.append(
            EvidenceReference(
                kind: .subscription,
                referenceID: subscription.id.uuidString,
                label: subscription.displayName,
                snippet: """
                Latest normalized cost
                \(subscription.normalizedMonthlyAmount.currencyString(code: subscription.priceCurrency))
                """
            )
        )
        actions.append(
            tooling.draftReviewUpdate(
                subscriptionID: subscription.id,
                fields: [
                    "status": SubscriptionStatus.needsReview.rawValue,
                    "notes": "Copilot flagged a recent price increase for review."
                ]
            )
        )
    }

    func openAuditAction() -> IntelligenceActionSuggestion {
        IntelligenceActionSuggestion(
            id: "tab:audit",
            title: "Open audit",
            action: .openTab(.audit),
            requiresConfirmation: false
        )
    }

    func emptyRenewalsResponse(days: Int) -> IntelligenceResponse {
        IntelligenceResponse(
            headline: "No renewals are due soon",
            summary: """
            Nothing in your active library is expected to renew in the next \(days)
            days.
            """,
            evidence: [],
            actions: [
                IntelligenceActionSuggestion(
                    id: "tab:calendar",
                    title: "Open calendar reminders",
                    action: .openTab(.calendar),
                    requiresConfirmation: false
                )
            ],
            followUps: [
                "What can I cancel instead?",
                "Show the next 90 days instead."
            ],
            confidence: 0.84
        )
    }

    func renewalEvidence(for renewals: [Subscription]) -> [EvidenceReference] {
        let referenceDate = Date()
        return renewals.map { subscription in
            let renewalDate = DashboardMetrics.currentRenewalDate(
                for: subscription,
                referenceDate: referenceDate
            )
            return EvidenceReference(
                kind: .renewal,
                referenceID: subscription.id.uuidString,
                label: subscription.displayName,
                snippet: """
                \(subscription.priceAmount.currencyString(code: subscription.priceCurrency))
                on \(renewalDate?.shortDateString ?? "Unknown")
                """
            )
        }
    }

    func renewalActions(for firstRenewal: Subscription?) -> [IntelligenceActionSuggestion] {
        var actions: [IntelligenceActionSuggestion] = []
        if let firstRenewal {
            actions.append(
                IntelligenceActionSuggestion(
                    id: "subscription:\(firstRenewal.id.uuidString)",
                    title: "Open \(firstRenewal.displayName)",
                    action: .openSubscription(firstRenewal.id),
                    requiresConfirmation: false
                )
            )
        }
        actions.append(
            IntelligenceActionSuggestion(
                id: "tab:calendar",
                title: "Open calendar",
                action: .openTab(.calendar),
                requiresConfirmation: false
            )
        )
        return actions
    }
}
