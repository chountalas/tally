import Foundation

struct MonthlyIntelligenceBriefService {
    private var intelligence: SubscriptionIntelligenceService { SubscriptionIntelligenceService() }

    func generate(metrics: DashboardMetrics) async -> String {
        await intelligence.generateMonthlyBrief(metrics: metrics)
    }

    func fallbackBrief(metrics: DashboardMetrics) -> String {
        intelligence.fallbackBrief(metrics: metrics)
    }
}
