import Foundation

/// Activity on another card, or merely the passage of time, is not evidence
/// that a payment is absent from the imported account history.
struct AccountObservationCoverage {
    private let datesByAccount: [Account: [Date]]

    @MainActor
    init(transactions: [NormalizedTransaction]) {
        let entries = transactions.compactMap { transaction -> (Account, Date)? in
            guard let account = Self.account(for: transaction), transaction.transactionDate <= .now else { return nil }
            return (account, transaction.transactionDate)
        }
        datesByAccount = Dictionary(grouping: entries, by: { $0.0 }).mapValues { $0.map { $0.1 }.sorted() }
    }

    @MainActor
    func observesMissingPayment(
        expected: Date, schedule: BillingSchedule, charges: [NormalizedTransaction], referenceDate: Date = .now
    ) -> Bool {
        guard let graceEnd = schedule.calendar.date(byAdding: .day,
                                                    value: schedule.cadence.renewalGraceWindowDays,
                                                    to: expected), graceEnd < referenceDate else { return false }
        let next = schedule.next(after: expected) ?? referenceDate
        let cutoff = max(next, graceEnd)
        let accounts = Set(charges.compactMap { Self.account(for: $0) })
        return accounts.contains { account in
            datesByAccount[account, default: []].contains { $0 >= graceEnd && $0 <= cutoff }
        }
    }

    @MainActor
    private static func account(for transaction: NormalizedTransaction) -> Account? {
        guard let name = transaction.externalAccountID?.nilIfBlank ?? transaction.accountName?.nilIfBlank else { return nil }
        return Account(name: name, currency: transaction.currency?.uppercased() ?? "USD")
    }

    private struct Account: Hashable {
        let name: String
        let currency: String
    }
}

extension SubscriptionDetectionService {
    func reconcileLifecycles(
        for subscriptions: [Subscription], transactions: [NormalizedTransaction], environment: DetectionEnvironment
    ) {
        let coverage = AccountObservationCoverage(transactions: transactions)
        let linked = Dictionary(grouping: transactions.filter { $0.subscriptionID != nil }, by: { $0.subscriptionID })
        for subscription in subscriptions {
            let rule = environment.rulesByCanonical[subscription.canonicalName]
            if rule?.overrideStatus == .former ||
                (subscription.creationPath == .manual && subscription.status == .former) {
                subscription.status = .former
                subscription.predictedNextChargeDate = nil
                subscription.detectionReason = "You marked this subscription as ended."
                continue
            }
            let charges = linked[subscription.id, default: []].sorted { $0.transactionDate < $1.transactionDate }
            guard let last = subscription.lastChargeDate, subscription.cadence != .unknown else { continue }
            let schedule = BillingSchedule(cadence: subscription.cadence, dates: charges.isEmpty ? [last] : charges.map(\.transactionDate))
            guard let next = schedule.next(after: last) else { continue }
            if rule?.overrideStatus == .active || subscription.creationPath == .manual {
                subscription.predictedNextChargeDate = next
                continue
            }
            let graceEnd = Calendar.current.date(byAdding: .day, value: subscription.cadence.renewalGraceWindowDays, to: next) ?? next
            if graceEnd >= .now {
                if subscription.status == .former { subscription.status = .active }
                subscription.predictedNextChargeDate = next
                continue
            }
            let firstMissing = coverage.observesMissingPayment(expected: next, schedule: schedule, charges: charges)
            let following = schedule.next(after: next) ?? next
            let followingGrace = Calendar.current.date(byAdding: .day,
                                                       value: subscription.cadence.renewalGraceWindowDays, to: following) ?? following
            let secondMissing = coverage.observesMissingPayment(expected: following, schedule: schedule, charges: charges)
            if firstMissing && (!subscription.cadence.allowsSecondMissTolerance || secondMissing) {
                subscription.status = .former
                subscription.predictedNextChargeDate = nil
                subscription.detectionReason =
                    "Payments stopped while this account continued to appear in your imports. " +
                    "This suggests the subscription ended; it does not confirm a cancellation."
            } else if firstMissing && followingGrace >= .now {
                if subscription.status == .former { subscription.status = .active }
                subscription.predictedNextChargeDate = following
                subscription.detectionReason =
                    "One expected payment is missing. Waiting for the next billing cycle before marking this as ended."
            } else {
                subscription.status = .needsReview
                subscription.predictedNextChargeDate = nil
                subscription.detectionReason =
                    "Recurring payments found in older data. " +
                    "Import recent activity from the same account to check whether this is still active."
            }
        }
    }
}
