import Foundation
import SwiftData

extension SubscriptionDetectionService {
    func deduplicateSubscriptions(_ subscriptions: [Subscription], in context: ModelContext) -> [String: Subscription] {
        var byCanonical: [String: Subscription] = [:]

        for subscription in subscriptions.sorted(by: { $0.createdAt < $1.createdAt }) {
            if let existing = byCanonical[subscription.canonicalName] {
                context.delete(existing)
            }
            byCanonical[subscription.canonicalName] = subscription
        }

        return byCanonical
    }

    func deduplicateRules(
        _ rules: [SubscriptionReviewRule],
        in context: ModelContext
    ) -> [String: SubscriptionReviewRule] {
        var byCanonical: [String: SubscriptionReviewRule] = [:]

        for rule in rules.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let existing = byCanonical[rule.canonicalName] {
                context.delete(existing)
            }
            byCanonical[rule.canonicalName] = rule
        }

        return byCanonical
    }

    func deduplicateCorrections(
        _ corrections: [MerchantCorrection],
        in context: ModelContext
    ) -> [String: MerchantCorrection] {
        var byCanonical: [String: MerchantCorrection] = [:]

        for correction in corrections.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            if let existing = byCanonical[correction.canonicalName] {
                context.delete(existing)
            }
            byCanonical[correction.canonicalName] = correction
        }

        return byCanonical
    }

    func deduplicateMatchRules(
        _ rules: [SubscriptionMatchRule],
        in context: ModelContext
    ) -> [SubscriptionMatchRule] {
        var byKey: [String: SubscriptionMatchRule] = [:]

        for rule in rules.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let key = [
                rule.canonicalName.lowercased(),
                rule.isNegativeRule ? "negative" : "positive",
                rule.createdFromRawValue
            ].joined(separator: "|")
            if let existing = byKey[key] {
                context.delete(existing)
            }
            byKey[key] = rule
        }

        return Array(byKey.values)
    }

    func manualSubscription(from rule: SubscriptionReviewRule, existing: Subscription?) -> Subscription? {
        guard rule.isFalsePositive == false,
              let priceAmount = rule.overridePriceAmount,
              let displayName = rule.overrideDisplayName?.nilIfBlank ?? rule.canonicalName.nilIfBlank else {
            return nil
        }

        let resolvedCadence = rule.overrideCadence ?? .unknown
        let resolvedStatus = rule.overrideStatus ?? (resolvedCadence == .unknown ? .needsReview : .active)
        let resolvedCategory = rule.overrideCategory?.nilIfBlank
        let resolvedCurrency = rule.overridePriceCurrency?.nilIfBlank ?? "USD"
        let normalizedMonthlyAmount = normalizeMonthly(price: priceAmount, cadence: resolvedCadence)
        let lastChargeDate = rule.overrideLastChargeDate ?? existing?.lastChargeDate
        let nextChargeDate = predictNextCharge(from: lastChargeDate, cadence: resolvedCadence)

        let subscription = existing ?? Subscription(
            canonicalName: rule.canonicalName,
            displayName: displayName,
            status: resolvedStatus,
            libraryState: resolvedStatus == .former ? .inactive : .manual,
            creationPath: .manual,
            cadence: resolvedCadence,
            priceAmount: priceAmount,
            priceCurrency: resolvedCurrency,
            normalizedMonthlyAmount: normalizedMonthlyAmount,
            lastChargeDate: lastChargeDate,
            predictedNextChargeDate: nextChargeDate,
            confidenceScore: 1,
            isUserConfirmed: rule.isUserConfirmed,
            serviceCategory: resolvedCategory,
            detectionReason: nil,
            notes: rule.notes?.nilIfBlank
        )

        subscription.displayName = displayName
        subscription.status = resolvedStatus
        subscription.libraryState = resolvedStatus == .former ? .inactive : .manual
        subscription.creationPath = .manual
        subscription.cadence = resolvedCadence
        subscription.priceAmount = priceAmount
        subscription.priceCurrency = resolvedCurrency
        subscription.normalizedMonthlyAmount = normalizedMonthlyAmount
        subscription.lastChargeDate = lastChargeDate
        subscription.predictedNextChargeDate = nextChargeDate
        subscription.confidenceScore = 1
        subscription.serviceCategory = resolvedCategory
        subscription.detectionReason = nil
        subscription.notes = rule.notes?.nilIfBlank
        subscription.isUserConfirmed = rule.isUserConfirmed
        subscription.firstChargeDate = nil
        subscription.tenureMonths = nil
        subscription.priceChangePercent = nil

        return subscription
    }

    func shouldLinkTransactionToManualRule(_ transaction: NormalizedTransaction, rule: SubscriptionReviewRule) -> Bool {
        guard rule.isFalsePositive == false else {
            return false
        }

        let explicitKeywords = hasExplicitSubscriptionKeywords(transaction) ||
            explicitClusterDescriptor(for: transaction) != nil
        let priceMatches: Bool = {
            guard let overridePrice = rule.overridePriceAmount else {
                return explicitKeywords
            }

            let targetAmount = abs((overridePrice as NSDecimalNumber).doubleValue)
            let transactionAmount = absoluteAmount(for: transaction)
            return abs(targetAmount - transactionAmount) <= max(2.5, targetAmount * 0.12)
        }()

        if explicitKeywords {
            return priceMatches
        }

        if transaction.merchantKind.isUsuallyNonSubscription {
            return false
        }

        guard transaction.merchantSubscriptionAffinity >= 0.75 else {
            return false
        }

        return priceMatches
    }
}
