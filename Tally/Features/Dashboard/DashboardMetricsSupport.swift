import Foundation

extension DashboardMetrics {
    static func upcomingRenewals(
        from subscriptions: [Subscription],
        renewalCutoff: Date
    ) -> [Subscription] {
        subscriptions
            .filter { ($0.predictedNextChargeDate ?? .distantFuture) < renewalCutoff }
            .sorted {
                ($0.predictedNextChargeDate ?? .distantFuture) <
                    ($1.predictedNextChargeDate ?? .distantFuture)
            }
    }

    static func probableRenewals(
        from subscriptions: [Subscription],
        renewalCutoff: Date,
        transactionsBySubscription: [UUID: [NormalizedTransaction]]
    ) -> [Subscription] {
        subscriptions
            .filter { subscription in
                guard subscription.status == .needsReview,
                      let nextChargeDate = subscription.predictedNextChargeDate,
                      nextChargeDate < renewalCutoff else {
                    return false
                }

                let linkedCount = transactionsBySubscription[subscription.id]?.count ?? 0
                return linkedCount == 1
            }
            .sorted {
                ($0.predictedNextChargeDate ?? .distantFuture) <
                    ($1.predictedNextChargeDate ?? .distantFuture)
            }
    }

    static func overlapGroups(from subscriptions: [Subscription]) -> [OverlapGroup] {
        let categoryGroups = Dictionary(grouping: subscriptions) {
            $0.serviceCategory?.lowercased() ?? "uncategorized"
        }

        return categoryGroups.compactMap { category, groupedSubscriptions -> OverlapGroup? in
            guard groupedSubscriptions.count > 1, category != "uncategorized" else {
                return nil
            }

            return OverlapGroup(
                category: groupedSubscriptions.first?.serviceCategory ?? category.capitalized,
                subscriptions: groupedSubscriptions,
                monthlyExposure: groupedSubscriptions.reduce(.zero) {
                    $0 + $1.normalizedMonthlyAmount
                }
            )
        }
    }

    static func buildMonthlySpend(
        from debitTransactions: [NormalizedTransaction]
    ) -> [MonthlySpendPoint] {
        let grouped = Dictionary(grouping: debitTransactions) { transaction in
            let components = Calendar.current.dateComponents(
                [.year, .month],
                from: transaction.transactionDate
            )
            return Calendar.current.date(from: components) ?? transaction.transactionDate
        }

        return grouped.map { month, items in
            let total = items.reduce(Decimal.zero) { partial, item in
                partial + abs(item.transactionAmount)
            }
            return MonthlySpendPoint(month: month, totalSpend: total)
        }
        .sorted { $0.month < $1.month }
    }

    static func buildYearlySpend(
        from debitTransactions: [NormalizedTransaction]
    ) -> [YearlySpendPoint] {
        let grouped = Dictionary(grouping: debitTransactions) { transaction in
            Calendar.current.component(.year, from: transaction.transactionDate)
        }

        return grouped.map { year, items in
            let total = items.reduce(Decimal.zero) { partial, item in
                partial + abs(item.transactionAmount)
            }
            return YearlySpendPoint(year: year, totalSpend: total)
        }
        .sorted { $0.year < $1.year }
    }

    static func buildOpportunities(
        subscriptions: [Subscription],
        transactionsBySubscription: [UUID: [NormalizedTransaction]]
    ) -> [SavingsOpportunity] {
        var items: [SavingsOpportunity] = []

        let categoryGroups = Dictionary(grouping: subscriptions) { subscription in
            subscription.serviceCategory?.lowercased() ?? "uncategorized"
        }

        for (_, group) in categoryGroups where group.count > 1 {
            let category = group.first?.serviceCategory ?? "Uncategorized"
            let names = group.map(\.displayName).sorted().joined(separator: ", ")
            let monthlyExposure = group.reduce(Decimal.zero) { $0 + $1.normalizedMonthlyAmount }
            let exposure = monthlyExposure.formatted(.currency(code: "USD"))
            items.append(
                SavingsOpportunity(
                    title: "Overlap in \(category)",
                    detail: "\(names) are all active in the same category. Review \(exposure) per month.",
                    priority: 0
                )
            )
        }

        for subscription in subscriptions {
            guard let linkedTransactions = transactionsBySubscription[subscription.id],
                  linkedTransactions.count >= 2,
                  let latest = linkedTransactions.max(by: { $0.transactionDate < $1.transactionDate }) else {
                continue
            }

            let earlierAmounts = linkedTransactions
                .filter { $0.id != latest.id }
                .map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }

            guard !earlierAmounts.isEmpty else {
                continue
            }

            let baseline = earlierAmounts.reduce(0, +) / Double(earlierAmounts.count)
            let latestAmount = abs((latest.transactionAmount as NSDecimalNumber).doubleValue)
            guard baseline > 0 else {
                continue
            }

            let percentChange = (latestAmount - baseline) / baseline
            guard percentChange >= 0.08 else {
                continue
            }

            let formattedPercent = percentChange.formatted(
                .percent.precision(.fractionLength(0))
            )
            items.append(
                SavingsOpportunity(
                    title: "Price increase: \(subscription.displayName)",
                    detail: "Latest charge is \(formattedPercent) above the earlier average.",
                    priority: 1
                )
            )
        }

        return items.sorted { $0.priority < $1.priority }
    }

    static func buildActNowItems(
        subscriptions: [Subscription],
        transactionsBySubscription: [UUID: [NormalizedTransaction]],
        opportunities: [SavingsOpportunity]
    ) -> [RenewalDecisionItem] {
        let soon = subscriptions
            .filter {
                guard let date = $0.predictedNextChargeDate else { return false }
                let cutoff = Calendar.current.date(byAdding: .day, value: 30, to: .now)
                    ?? .distantFuture
                return date <= cutoff
            }
            .sorted {
                ($0.predictedNextChargeDate ?? .distantFuture) <
                    ($1.predictedNextChargeDate ?? .distantFuture)
            }

        return soon.map { subscription in
            let linkedTransactions = transactionsBySubscription[subscription.id] ?? []
            let overlap = subscription.serviceCategory
                .map { category in
                    opportunities.contains { $0.title.localizedStandardContains(category) }
                } ?? false
            let hasPriceIncrease = hasPriceIncrease(in: linkedTransactions)
            let action: RenewalAction

            if subscription.status == .needsReview || subscription.confidenceScore < 0.75 {
                action = .review
            } else if overlap || hasPriceIncrease {
                action = .review
            } else {
                action = .keep
            }

            let reasons = [
                overlap ? "category overlap" : nil,
                hasPriceIncrease ? "price increase" : nil,
                subscription.confidenceScore < 0.75 ? "low confidence" : nil
            ].compactMap { $0 }

            return RenewalDecisionItem(
                subscriptionID: subscription.id,
                subscriptionName: subscription.displayName,
                renewalDate: subscription.predictedNextChargeDate,
                price: subscription.priceAmount,
                currencyCode: subscription.priceCurrency,
                action: action,
                detail: renewalDecisionDetail(
                    renewalDate: subscription.predictedNextChargeDate,
                    action: action,
                    reasons: reasons
                )
            )
        }
    }

    static func hasPriceIncrease(in transactions: [NormalizedTransaction]) -> Bool {
        guard transactions.count >= 2,
              let latest = transactions.max(by: { $0.transactionDate < $1.transactionDate }) else {
            return false
        }

        let earlier = transactions
            .filter { $0.id != latest.id }
            .map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }

        guard !earlier.isEmpty else {
            return false
        }

        let average = earlier.reduce(0, +) / Double(earlier.count)
        let latestAmount = abs((latest.transactionAmount as NSDecimalNumber).doubleValue)
        guard average > 0 else {
            return false
        }

        return ((latestAmount - average) / average) >= 0.08
    }

    private static func renewalDecisionDetail(
        renewalDate: Date?,
        action: RenewalAction,
        reasons: [String]
    ) -> String {
        let renewalContext = renewalDate.map { "Renews \($0.shortDateString)." }

        let reasonSummary: String
        switch action {
        case .keep:
            reasonSummary = "No risk signals detected."
        case .review:
            if reasons.isEmpty {
                reasonSummary = "Check this before the next renewal posts."
            } else {
                reasonSummary = "Review because \(joinedReasons(reasons))."
            }
        case .cancel:
            if reasons.isEmpty {
                reasonSummary = "Likely safe to cut before the next renewal."
            } else {
                reasonSummary = "Cancel because \(joinedReasons(reasons))."
            }
        }

        return [renewalContext, reasonSummary]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private static func joinedReasons(_ reasons: [String]) -> String {
        switch reasons.count {
        case 0:
            return "missing context"
        case 1:
            return reasons[0]
        case 2:
            return "\(reasons[0]) and \(reasons[1])"
        default:
            let leading = reasons.dropLast().joined(separator: ", ")
            return "\(leading), and \(reasons.last ?? "")"
        }
    }
}
