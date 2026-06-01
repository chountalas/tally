import Foundation

@MainActor
struct AuditIntelligenceService {
    private var intelligence: SubscriptionIntelligenceService { SubscriptionIntelligenceService() }

    func generateOneLiner(
        subscription: Subscription,
        score: AuditScore,
        allActive: [Subscription],
        transactions: [NormalizedTransaction]
    ) async -> String {
        await intelligence.generateAuditOneLiner(
            subscription: subscription,
            score: score,
            allActive: allActive,
            transactions: transactions
        )
    }

    func fallbackOneLiner(
        subscription: Subscription,
        score: AuditScore
    ) -> String {
        intelligence.fallbackAuditOneLiner(subscription: subscription, score: score)
    }
}
