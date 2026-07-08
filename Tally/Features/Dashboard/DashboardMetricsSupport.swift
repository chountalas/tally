import Foundation

extension DashboardMetrics {
    static let priceIncreaseThreshold = 0.05

    static func currentActiveSubscriptions(
        from subscriptions: [Subscription],
        referenceDate: Date = .now
    ) -> [Subscription] {
        subscriptions.filter {
            displayStatus(for: $0, referenceDate: referenceDate) == .active
        }
    }

    static func displayStatus(
        for subscription: Subscription,
        referenceDate: Date = .now
    ) -> SubscriptionStatus {
        guard subscription.status == .active else {
            return subscription.status
        }
        guard subscription.predictedNextChargeDate != nil else {
            return .active
        }
        return currentRenewalDate(for: subscription, referenceDate: referenceDate) == nil
            ? .former
            : .active
    }

    static func currentRenewalDate(
        for subscription: Subscription,
        referenceDate: Date = .now
    ) -> Date? {
        guard let renewalDate = subscription.predictedNextChargeDate else {
            return nil
        }

        if renewalDate >= staleRenewalCutoff(for: subscription, referenceDate: referenceDate) {
            return renewalDate
        }

        guard subscription.cadence.allowsSecondMissTolerance,
              let followingRenewalDate = subscription.cadence.advance(renewalDate),
              followingRenewalDate >= staleRenewalCutoff(for: subscription, referenceDate: referenceDate)
        else {
            return nil
        }

        return followingRenewalDate
    }

    static func upcomingRenewals(
        from subscriptions: [Subscription],
        renewalCutoff: Date,
        referenceDate: Date = .now
    ) -> [Subscription] {
        subscriptions
            .filter {
                guard let renewalDate = currentRenewalDate(for: $0, referenceDate: referenceDate) else {
                    return false
                }
                return renewalDate < renewalCutoff
            }
            .sorted {
                (currentRenewalDate(for: $0, referenceDate: referenceDate) ?? .distantFuture) <
                    (currentRenewalDate(for: $1, referenceDate: referenceDate) ?? .distantFuture)
            }
    }

    static func projectedRenewalDates(
        for subscription: Subscription,
        inVisibleMonth viewMonth: Date,
        calendar: Calendar = .current,
        referenceDate: Date = .now
    ) -> [Date] {
        guard let currentRenewalDate = currentRenewalDate(
            for: subscription,
            referenceDate: referenceDate
        ) else {
            return []
        }

        let anchor = calendar.startOfDay(for: subscription.lastChargeDate ?? currentRenewalDate)
        let displayStart = calendar.startOfDay(for: currentRenewalDate)
        let visibleStart = calendar.startOfDay(for: viewMonth)
        let visibleEnd = calendar.startOfDay(
            for: calendar.date(byAdding: .month, value: 1, to: visibleStart) ?? visibleStart
        )

        var dates: [Date] = []
        var period = 0
        var previous: Date?
        while period < 800 {
            let projected: Date?
            if period == 0 {
                projected = anchor
            } else {
                projected = subscription.cadence.tallyAdvanced(anchor, by: period, using: calendar)
            }

            guard let current = projected.map(calendar.startOfDay(for:)) else {
                break
            }
            if let previous, current <= previous {
                break
            }
            if current >= visibleEnd {
                break
            }
            if current >= visibleStart, current >= displayStart {
                dates.append(current)
            }

            previous = current
            period += 1
        }

        return dates
    }

    static func probableRenewals(
        from subscriptions: [Subscription],
        renewalCutoff: Date,
        transactionsBySubscription: [UUID: [NormalizedTransaction]],
        referenceDate: Date = .now
    ) -> [Subscription] {
        subscriptions
            .filter { subscription in
                guard subscription.status == .needsReview,
                      let nextChargeDate = currentRenewalDate(
                        for: subscription,
                        referenceDate: referenceDate
                      ),
                      nextChargeDate < renewalCutoff else {
                    return false
                }

                let linkedCount = transactionsBySubscription[subscription.id]?.count ?? 0
                return linkedCount == 1
            }
            .sorted {
                (currentRenewalDate(for: $0, referenceDate: referenceDate) ?? .distantFuture) <
                    (currentRenewalDate(for: $1, referenceDate: referenceDate) ?? .distantFuture)
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
            let exposure = monthlyExposure.currencyString()
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
                  linkedTransactions.count >= 2 else {
                continue
            }

            guard let percentChange = priceIncreasePercent(in: linkedTransactions) else {
                continue
            }

            let formattedPercent = percentChange.percentString
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
        opportunities: [SavingsOpportunity],
        referenceDate: Date = .now
    ) -> [RenewalDecisionItem] {
        let soon = subscriptions
            .compactMap { subscription -> (subscription: Subscription, renewalDate: Date)? in
                guard let date = currentRenewalDate(
                    for: subscription,
                    referenceDate: referenceDate
                ) else { return nil }
                let cutoff = Calendar.current.date(byAdding: .day, value: 30, to: referenceDate)
                    ?? .distantFuture
                guard date <= cutoff else { return nil }
                return (subscription, date)
            }
            .sorted {
                $0.renewalDate < $1.renewalDate
            }

        return soon.map { subscription, renewalDate in
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
                renewalDate: renewalDate,
                price: subscription.priceAmount,
                currencyCode: subscription.priceCurrency,
                action: action,
                detail: renewalDecisionDetail(
                    renewalDate: renewalDate,
                    action: action,
                    reasons: reasons
                )
            )
        }
    }

    static func hasPriceIncrease(in transactions: [NormalizedTransaction]) -> Bool {
        priceIncreasePercent(in: transactions) != nil
    }

    static func priceIncreasePercent(in transactions: [NormalizedTransaction]) -> Double? {
        guard transactions.count >= 2,
              let latest = transactions.max(by: { $0.transactionDate < $1.transactionDate }) else {
            return nil
        }

        let earlier = transactions
            .filter { $0.id != latest.id }
            .map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }

        guard !earlier.isEmpty else {
            return nil
        }

        let average = earlier.reduce(0, +) / Double(earlier.count)
        let latestAmount = abs((latest.transactionAmount as NSDecimalNumber).doubleValue)
        guard average > 0 else {
            return nil
        }

        let percentChange = (latestAmount - average) / average
        return percentChange >= priceIncreaseThreshold ? percentChange : nil
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

    private static func staleRenewalCutoff(
        for subscription: Subscription,
        referenceDate: Date,
        calendar: Calendar = .current
    ) -> Date {
        let today = calendar.startOfDay(for: referenceDate)
        return calendar.date(
            byAdding: .day,
            value: -subscription.cadence.renewalGraceWindowDays,
            to: today
        ) ?? .distantPast
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
