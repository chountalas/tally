import Foundation

struct DashboardMetrics {
    let monthlyRunRate: Decimal
    let annualizedSpend: Decimal
    let activeCount: Int
    let annualCount: Int
    let monthlyCount: Int
    let needsReviewCount: Int
    let upcomingRenewals: [Subscription]
    let probableRenewals: [Subscription]
    let monthlySpend: [MonthlySpendPoint]
    let yearlySpend: [YearlySpendPoint]
    let opportunities: [SavingsOpportunity]
    let actNowItems: [RenewalDecisionItem]
    let overlapGroups: [OverlapGroup]
    let priceChangedSubscriptions: [Subscription]

    var averagePerSubscription: Decimal {
        guard activeCount > 0 else { return 0 }
        return monthlyRunRate / Decimal(activeCount)
    }

    var monthlyChange: MetricChange? {
        guard monthlySpend.count >= 2 else { return nil }
        let sorted = monthlySpend.sorted { $0.month < $1.month }
        let current = sorted[sorted.count - 1].totalSpend
        let previous = sorted[sorted.count - 2].totalSpend
        guard previous > 0 else { return nil }
        let diff = current - previous
        let isUp = diff >= 0
        return MetricChange(
            label: abs(diff).currencyString(),
            isPositive: !isUp
        )
    }

    var annualChange: MetricChange? {
        guard yearlySpend.count >= 2 else { return nil }
        let sorted = yearlySpend.sorted { $0.year < $1.year }
        let current = sorted[sorted.count - 1].totalSpend
        let previous = sorted[sorted.count - 2].totalSpend
        guard previous > 0 else { return nil }
        let pctChange = ((current - previous) / previous * 100)
        let isUp = pctChange >= 0
        let pctNumber = NSDecimalNumber(decimal: abs(pctChange))
        let pctStr = "\(pctNumber.rounding(accordingToBehavior: nil).intValue)% YoY"
        return MetricChange(
            label: pctStr,
            isPositive: !isUp
        )
    }

    init(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        referenceDate: Date = .now
    ) {
        let activeSubscriptions = Self.currentActiveSubscriptions(
            from: subscriptions,
            referenceDate: referenceDate
        )
        let debitTransactions = transactions.filter { $0.transactionAmount < 0 }
        let transactionsBySubscription = Dictionary(
            grouping: debitTransactions.filter { $0.subscriptionID != nil }
        ) { $0.subscriptionID! }
        let subscriptionDebitTransactions = debitTransactions.filter { $0.subscriptionID != nil }

        monthlyRunRate = activeSubscriptions.reduce(Decimal.zero) { $0 + $1.normalizedMonthlyAmount }
        annualizedSpend = monthlyRunRate * 12
        activeCount = activeSubscriptions.count
        annualCount = activeSubscriptions.filter { $0.cadence == .annual }.count
        monthlyCount = activeSubscriptions.filter { $0.cadence == .monthly }.count
        needsReviewCount = subscriptions.filter { $0.status == .needsReview }.count
        let renewalCutoff =
            Calendar.current.date(byAdding: .day, value: 90, to: referenceDate) ?? .distantFuture
        upcomingRenewals = Self.upcomingRenewals(
            from: activeSubscriptions,
            renewalCutoff: renewalCutoff,
            referenceDate: referenceDate
        )
        probableRenewals = Self.probableRenewals(
            from: subscriptions,
            renewalCutoff: renewalCutoff,
            transactionsBySubscription: transactionsBySubscription,
            referenceDate: referenceDate
        )
        monthlySpend = DashboardMetrics.buildMonthlySpend(from: subscriptionDebitTransactions)
        yearlySpend = DashboardMetrics.buildYearlySpend(from: subscriptionDebitTransactions)
        opportunities = DashboardMetrics.buildOpportunities(
            subscriptions: activeSubscriptions,
            transactionsBySubscription: transactionsBySubscription
        )
        actNowItems = DashboardMetrics.buildActNowItems(
            subscriptions: activeSubscriptions,
            transactionsBySubscription: transactionsBySubscription,
            opportunities: opportunities,
            referenceDate: referenceDate
        )
        overlapGroups = Self.overlapGroups(from: activeSubscriptions)
        priceChangedSubscriptions = activeSubscriptions
            .filter { subscription in
                Self.priceIncreasePercent(in: transactionsBySubscription[subscription.id] ?? []) != nil
            }
            .sorted {
                (Self.priceIncreasePercent(in: transactionsBySubscription[$0.id] ?? []) ?? 0) >
                    (Self.priceIncreasePercent(in: transactionsBySubscription[$1.id] ?? []) ?? 0)
            }
    }
}

struct MonthlySpendPoint: Identifiable {
    let month: Date
    let totalSpend: Decimal

    var id: Date { month }
}

struct YearlySpendPoint: Identifiable {
    let year: Int
    let totalSpend: Decimal

    var id: Int { year }
}

struct SavingsOpportunity: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
    let priority: Int
}

struct RenewalDecisionItem: Identifiable {
    let subscriptionID: UUID
    let subscriptionName: String
    let renewalDate: Date?
    let price: Decimal
    let currencyCode: String
    let action: RenewalAction
    let detail: String

    var id: UUID { subscriptionID }
}

enum RenewalAction: String {
    case keep
    case review
    case cancel
}

struct OverlapGroup: Identifiable {
    let category: String
    let subscriptions: [Subscription]
    let monthlyExposure: Decimal
    var id: String { category }
}

struct MetricChange {
    let label: String
    let isPositive: Bool
}
