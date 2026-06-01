import Foundation

struct AuditScore: Identifiable {
    let subscriptionID: UUID
    let subscriptionName: String
    let cancelWorthiness: Int
    let action: AuditAction
    let reasons: [String]
    let monthlyAmount: Decimal
    var id: UUID { subscriptionID }
}

enum AuditEngine {
    static func score(
        subscription: Subscription,
        allActive: [Subscription],
        transactions: [NormalizedTransaction]
    ) -> AuditScore {
        var points = 0
        var reasons: [String] = []

        // Overlap penalty (+25)
        let categoryPeers = allActive.filter {
            $0.id != subscription.id &&
            $0.serviceCategory == subscription.serviceCategory &&
            subscription.serviceCategory?.isEmpty == false &&
            subscription.serviceCategory != "Uncategorized"
        }
        if !categoryPeers.isEmpty {
            points += 25
            let peerNames = categoryPeers.map(\.displayName).joined(separator: ", ")
            let categoryName = subscription.serviceCategory ?? "same category"
            reasons.append("Overlaps with \(peerNames) in \(categoryName).")
        }

        // Price increase penalty (+20)
        if let change = subscription.priceChangePercent, change > 0.05 {
            points += 20
            reasons.append("Price increased \(change.percentString) since first charge.")
        }

        // Low confidence (+15)
        if subscription.confidenceScore < 0.75 {
            points += 15
            reasons.append("Detection confidence is low (\(subscription.confidenceScore.percentString)).")
        }

        // High cost - top quartile (+15)
        let amounts = allActive.map { $0.normalizedMonthlyAmount.doubleValue }.sorted()
        let p75 = amounts.isEmpty ? 0 : amounts[min(amounts.count - 1, amounts.count * 3 / 4)]
        if subscription.normalizedMonthlyAmount.doubleValue >= p75 && p75 > 0 {
            points += 15
            reasons.append("In the top 25% of your monthly costs.")
        }

        // Needs a decision (+15)
        if subscription.status == .needsReview {
            points += 15
            reasons.append("Still needs your call before it is tracked.")
        }

        // Short tenure bonus (-10)
        if let tenure = subscription.tenureMonths, tenure < 6 {
            points = max(0, points - 10)
        }

        let clampedPoints = min(100, max(0, points))
        return AuditScore(
            subscriptionID: subscription.id,
            subscriptionName: subscription.displayName,
            cancelWorthiness: clampedPoints,
            action: action(for: clampedPoints),
            reasons: reasons.isEmpty ? ["No risk signals detected."] : reasons,
            monthlyAmount: subscription.normalizedMonthlyAmount
        )
    }

    static func action(for score: Int) -> AuditAction {
        if score >= 50 { return .cancel }
        if score >= 25 { return .review }
        return .keep
    }

    static func rankAll(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction]
    ) -> [AuditScore] {
        let active = subscriptions.filter { $0.status == .active }
        return active
            .map { score(subscription: $0, allActive: active, transactions: transactions) }
            .sorted { $0.cancelWorthiness > $1.cancelWorthiness }
    }
}
