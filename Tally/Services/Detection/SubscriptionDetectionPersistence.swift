import Foundation
import SwiftData

extension SubscriptionDetectionService {
    func handleFalsePositiveRule(
        _ rule: SubscriptionReviewRule?,
        canonicalName: String,
        environment: DetectionEnvironment
    ) -> Bool {
        guard rule?.isFalsePositive == true else {
            return false
        }

        if let existing = environment.existingByCanonical[canonicalName] {
            environment.context.delete(existing)
        }
        return true
    }

    func handleMerchantCorrectionSuppression(
        _ correction: MerchantCorrection?,
        request: DetectionSuppressionRequest,
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) -> Bool {
        guard correction?.isSubscription == false else {
            return false
        }

        if let existing = environment.existingByCanonical[request.canonicalName] {
            environment.context.delete(existing)
        }

        state.clusterReports.append(
            SubscriptionClusterReport(
                canonicalName: request.canonicalName,
                displayName: request.displayName,
                status: .suppressed,
                source: request.source,
                hadRecurringSignals: request.hadRecurringSignals,
                reason: request.reason,
                importRecordIDs: request.importRecordIDs
            )
        )
        state.autoSuppressCount += 1
        recordEvidence(
            candidateKey: request.canonicalName,
            decision: .autoSuppressed,
            confidence: 1,
            deterministicScore: 1,
            factors: [
                SubscriptionEvidenceFactor(
                    key: "user_negative_rule",
                    weight: 1,
                    score: 1,
                    source: "merchant_correction",
                    description: request.reason
                )
            ],
            matchedTransactions: [],
            rejectedTransactions: [],
            rules: [],
            reason: request.reason,
            environment: environment
        )
        return true
    }

    func confidenceBoost(for correction: MerchantCorrection?) -> Double {
        correction?.isSubscription == true ? 0.30 : 0
    }

    func detectedSubscription(
        from summary: SubscriptionSummary,
        cluster: SubscriptionCandidateCluster,
        rule: SubscriptionReviewRule?,
        correction: MerchantCorrection?,
        existing: Subscription?
    ) -> Subscription {
        let resolvedCadence = rule?.overrideCadence ?? correction?.correctedCadence ?? summary.cadence
        let resolvedLastChargeDate = rule?.overrideLastChargeDate ?? summary.lastChargeDate
        let resolution = DetectedSubscriptionResolution(
            summary: summary,
            rule: rule,
            cadence: resolvedCadence,
            lastChargeDate: resolvedLastChargeDate,
            nextChargeDate: predictNextCharge(
                from: resolvedLastChargeDate,
                cadence: resolvedCadence
            ),
            normalizedMonthlyAmount: normalizeMonthly(
                price: rule?.overridePriceAmount ?? summary.priceAmount,
                cadence: resolvedCadence
            )
        )
        let subscription = existing ?? Subscription(
            canonicalName: summary.canonicalName,
            displayName: resolution.displayName,
            status: resolution.status,
            cadence: resolution.cadence,
            priceAmount: resolution.priceAmount,
            priceCurrency: resolution.priceCurrency,
            normalizedMonthlyAmount: resolution.normalizedMonthlyAmount,
            lastChargeDate: resolution.lastChargeDate,
            predictedNextChargeDate: resolution.nextChargeDate,
            confidenceScore: summary.confidence,
            isUserConfirmed: rule?.isUserConfirmed ?? correction?.isSubscription == true,
            serviceCategory: resolution.category,
            detectionReason: summary.reason,
            notes: rule?.notes?.nilIfBlank
        )

        applyDetectedSubscriptionFields(
            subscription,
            context: DetectedSubscriptionUpdateContext(
                summary: summary,
                cluster: cluster,
                rule: rule,
                correction: correction,
                resolution: resolution
            )
        )
        return subscription
    }

    func applyDetectedSubscriptionFields(
        _ subscription: Subscription,
        context: DetectedSubscriptionUpdateContext
    ) {
        subscription.displayName = context.resolution.displayName
        subscription.status = context.resolution.status
        subscription.libraryState = resolvedLibraryState(
            summary: context.summary,
            rule: context.rule,
            correction: context.correction,
            existing: subscription
        )
        if subscription.creationPath != .manual {
            subscription.creationPath = context.summary.detectionSource == .recentPurchase ? .refreshed : .imported
        }
        subscription.cadence = context.resolution.cadence
        subscription.priceAmount = context.resolution.priceAmount
        subscription.priceCurrency = context.resolution.priceCurrency
        subscription.normalizedMonthlyAmount = context.resolution.normalizedMonthlyAmount
        subscription.lastChargeDate = context.resolution.lastChargeDate
        subscription.predictedNextChargeDate = context.resolution.nextChargeDate
        subscription.confidenceScore = context.summary.confidence
        subscription.serviceCategory = context.resolution.category
        subscription.detectionReason = context.summary.reason
        subscription.notes = context.rule?.notes?.nilIfBlank
        subscription.isUserConfirmed =
            context.rule?.isUserConfirmed ?? context.correction?.isSubscription == true
        if subscription.serviceIdentifier?.nilIfBlank == nil {
            subscription.serviceIdentifier = ServiceLogoDatabase.suggestedIdentifier(
                displayName: subscription.displayName,
                canonicalName: subscription.canonicalName
            )
        }
        subscription.firstChargeDate = context.cluster.transactions.map(\.transactionDate).min()
        subscription.tenureMonths = subscriptionTenureMonths(for: context.cluster)
        subscription.priceChangePercent = priceChangePercent(for: context.cluster)
    }

    func resolvedLibraryState(
        summary: SubscriptionSummary,
        rule: SubscriptionReviewRule?,
        correction: MerchantCorrection?,
        existing: Subscription?
    ) -> SubscriptionLibraryState {
        if existing?.creationPath == .manual {
            return existing?.status == .former ? .inactive : .manual
        }
        // A user's review-rule status override is authoritative over the detector's
        // freshly-inferred summary status. Without this, an edited detected
        // subscription the user kept active would be reverted to former/inactive on
        // the next rebuild whenever its last charge looks stale, because the summary
        // status (not the override) drove the library state.
        let effectiveStatus = rule?.overrideStatus ?? summary.status
        if rule?.isUserConfirmed == true || correction?.isSubscription == true {
            return effectiveStatus == .former ? .inactive : .confirmed
        }
        if effectiveStatus == .former {
            return .inactive
        }
        if effectiveStatus == .needsReview {
            return .suggested
        }
        return .confirmed
    }

    func subscriptionTenureMonths(for cluster: SubscriptionCandidateCluster) -> Int? {
        guard let firstChargeDate = cluster.transactions.map(\.transactionDate).min() else {
            return nil
        }

        return Calendar.current.dateComponents([.month], from: firstChargeDate, to: .now).month
    }

    func priceChangePercent(for cluster: SubscriptionCandidateCluster) -> Double? {
        let amounts = cluster.transactions
            .sorted { $0.transactionDate < $1.transactionDate }
            .map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }

        guard amounts.count >= 2,
              let first = amounts.first,
              first > 0,
              let last = amounts.last else {
            return nil
        }

        let change = (last - first) / first
        return abs(change) >= 0.03 ? change : nil
    }

    func linkTransactions(
        _ transactions: [NormalizedTransaction],
        to subscription: Subscription
    ) {
        if subscription.libraryState == .ignored {
            for transaction in transactions where transaction.subscriptionID == subscription.id {
                transaction.subscriptionID = nil
            }
            return
        }

        for transaction in transactions {
            transaction.subscriptionID = subscription.id
        }
    }

    func applyManualSubscriptions(
        from rulesByCanonical: [String: SubscriptionReviewRule],
        existingByCanonical: [String: Subscription],
        debitTransactions: [NormalizedTransaction],
        in context: ModelContext,
        seenCanonicals: inout Set<String>
    ) async {
        for (index, entry) in rulesByCanonical.sorted(by: { $0.key < $1.key }).enumerated() {
            let (canonicalName, rule) = entry
            guard !seenCanonicals.contains(canonicalName) else {
                continue
            }
            guard let subscription = manualSubscription(
                from: rule,
                existing: existingByCanonical[canonicalName]
            ) else {
                continue
            }

            if existingByCanonical[canonicalName] == nil {
                context.insert(subscription)
            }

            linkTransactions(
                matching: canonicalName,
                from: debitTransactions,
                to: subscription,
                rule: rule
            )
            seenCanonicals.insert(canonicalName)

            if index.isMultiple(of: 8) {
                await Task.yield()
            }
        }
    }

    func linkTransactions(
        matching canonicalName: String,
        from debitTransactions: [NormalizedTransaction],
        to subscription: Subscription,
        rule: SubscriptionReviewRule
    ) {
        guard subscription.libraryState != .ignored else {
            return
        }

        for transaction in debitTransactions where transaction.subscriptionID == nil {
            guard transaction.merchantNormalized == canonicalName else {
                continue
            }
            guard shouldLinkTransactionToManualRule(transaction, rule: rule) else {
                continue
            }
            transaction.subscriptionID = subscription.id
        }
    }

    func removeStaleSubscriptions(
        from existingSubscriptions: [Subscription],
        keeping seenCanonicals: Set<String>,
        reviewRules: [String: SubscriptionReviewRule],
        in context: ModelContext
    ) {
        for subscription in existingSubscriptions
        where !seenCanonicals.contains(subscription.canonicalName) {
            if reviewRules[subscription.canonicalName]?.isFalsePositive == true {
                context.delete(subscription)
                continue
            }
            if subscription.creationPath == .manual ||
                subscription.libraryState == .manual ||
                subscription.isUserConfirmed {
                continue
            }
            context.delete(subscription)
        }
    }
}
