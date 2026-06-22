import Foundation

extension SubscriptionDetectionService {
    func inferCadence(from intervals: [Int], occurrenceCount: Int) -> SubscriptionCadence {
        guard !intervals.isEmpty else {
            return .unknown
        }

        let median = intervals.sorted()[intervals.count / 2]

        if (25...36).contains(median), occurrenceCount >= 3 {
            return .monthly
        }
        if (330...395).contains(median), occurrenceCount >= 2 {
            return .annual
        }
        if (80...100).contains(median), occurrenceCount >= 3 {
            return .quarterly
        }
        if (165...200).contains(median), occurrenceCount >= 2 {
            return .semiannual
        }
        if (12...17).contains(median), occurrenceCount >= 4 {
            return .biweekly
        }
        if (5...9).contains(median), occurrenceCount >= 4 {
            return .weekly
        }

        return .unknown
    }

    func inferSparseCadence(
        from intervals: [Int],
        transactions: [NormalizedTransaction]
    ) -> SubscriptionCadence {
        guard transactions.count == 2,
              intervals.count == 1,
              hasStrongSparseSubscriptionSignals(transactions) else {
            return .unknown
        }

        let interval = intervals[0]
        if (24...38).contains(interval) {
            return .monthly
        }
        if (75...105).contains(interval) {
            return .quarterly
        }
        if (330...395).contains(interval) {
            return .annual
        }
        if (165...200).contains(interval) {
            return .semiannual
        }
        if (12...17).contains(interval) {
            return .biweekly
        }
        if (5...9).contains(interval) {
            return .weekly
        }

        return .unknown
    }

    func hasStrongSparseSubscriptionSignals(_ transactions: [NormalizedTransaction]) -> Bool {
        guard transactions.isEmpty == false else {
            return false
        }

        let keywordSupport = keywordSupportScore(for: transactions)
        let affinity = averageSubscriptionAffinity(for: transactions)
        let excludedCount = transactions.filter(isExcludedCategory).count

        if affinity >= 0.85, excludedCount == 0 {
            return true
        }

        return keywordSupport >= 0.7 && affinity >= 0.65 && excludedCount == 0
    }

    func minimumOccurrences(for cadence: SubscriptionCadence) -> Int {
        switch cadence {
        case .annual, .semiannual:
            return 2
        case .monthly, .quarterly:
            return 3
        case .biweekly, .weekly:
            return 4
        case .unknown:
            return .max
        }
    }

    func recurrenceConsistency(for intervals: [Int], cadence: SubscriptionCadence) -> Double {
        guard !intervals.isEmpty, let expected = cadence.cycleDays else {
            return 0
        }

        let averageDeviation = intervals.reduce(0.0) { partial, interval in
            partial + abs(Double(interval - expected))
        } / Double(intervals.count)

        let tolerance: Double
        switch cadence {
        case .monthly:
            tolerance = 7
        case .annual:
            tolerance = 30
        case .quarterly:
            tolerance = 10
        case .semiannual:
            tolerance = 14
        case .biweekly:
            tolerance = 3
        case .weekly:
            tolerance = 2
        case .unknown:
            tolerance = 0
        }

        guard tolerance > 0 else {
            return 0
        }

        return max(0, 1 - (averageDeviation / tolerance))
    }

    func amountStabilityScore(for priceVariation: Double) -> Double {
        max(0, 1 - min(priceVariation / 0.6, 1))
    }

    func inferStatus(
        lastChargeDate: Date?,
        cadence: SubscriptionCadence,
        referenceDate: Date = .now
    ) -> SubscriptionStatus {
        guard let lastChargeDate else {
            return .needsReview
        }

        guard let nextChargeDate = predictNextCharge(from: lastChargeDate, cadence: cadence) else {
            return .needsReview
        }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: referenceDate)
        let daysUntilExpectedRenewal = calendar.dateComponents(
            [.day],
            from: today,
            to: calendar.startOfDay(for: nextChargeDate)
        ).day ?? 0
        if daysUntilExpectedRenewal >= -graceWindow(for: cadence) {
            return .active
        }

        guard cadence.allowsSecondMissTolerance else {
            return .former
        }

        if let followingChargeDate = cadence.advance(nextChargeDate, using: calendar) {
            let daysUntilSecondMiss = calendar.dateComponents(
                [.day],
                from: today,
                to: calendar.startOfDay(for: followingChargeDate)
            ).day ?? 0
            if daysUntilSecondMiss >= -graceWindow(for: cadence) {
                return .active
            }
        }

        return .former
    }

    func predictNextCharge(from lastChargeDate: Date?, cadence: SubscriptionCadence) -> Date? {
        guard let lastChargeDate else {
            return nil
        }

        return cadence.advance(lastChargeDate)
    }

    func normalizeMonthly(price: Decimal, cadence: SubscriptionCadence) -> Decimal {
        switch cadence {
        case .monthly:
            return price
        case .annual:
            return price / 12
        case .quarterly:
            return price / 3
        case .semiannual:
            return price / 6
        case .biweekly:
            return price * Decimal(26) / 12
        case .weekly:
            return price * Decimal(52) / 12
        case .unknown:
            return price
        }
    }

    func graceWindow(for cadence: SubscriptionCadence) -> Int {
        cadence.renewalGraceWindowDays
    }
}
