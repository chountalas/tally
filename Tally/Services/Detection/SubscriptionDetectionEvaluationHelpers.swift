import Foundation

extension SubscriptionDetectionService {
    func singleChargeCandidates(
        from transactions: [NormalizedTransaction]
    ) -> [NormalizedTransaction] {
        Dictionary(grouping: transactions, by: \.merchantNormalized)
            .values
            .compactMap { group in
                guard group.count == 1 else {
                    return nil
                }
                return group.first
            }
            .sorted { lhs, rhs in
                lhs.transactionDate > rhs.transactionDate
            }
    }

    func recentPurchaseCandidate(
        for transaction: NormalizedTransaction,
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) -> DetectionSingleChargeCandidate? {
        guard shouldEvaluateSingleCharge(transaction) else {
            return nil
        }

        let displayName = recentPurchaseDisplayName(for: transaction)
        let canonicalName = displayName
        guard state.seenCanonicals.contains(canonicalName) == false else {
            return nil
        }

        let correction = environment.correctionsByCanonical[canonicalName]
        if handleMerchantCorrectionSuppression(
            correction,
            request: suppressionRequest(
                canonicalName: canonicalName,
                displayName: displayName,
                source: .recentPurchase,
                hadRecurringSignals: false,
                importRecordIDs: Set([transaction.importRecordID].compactMap { $0 })
            ),
            environment: environment,
            state: state
        ) {
            return nil
        }

        let rule = environment.rulesByCanonical[canonicalName]
        if handleFalsePositiveRule(
            rule,
            canonicalName: canonicalName,
            environment: environment
        ) {
            return nil
        }

        return DetectionSingleChargeCandidate(
            transaction: transaction,
            canonicalName: canonicalName,
            displayName: displayName,
            rule: rule,
            correction: correction
        )
    }

    func suppressionRequest(
        canonicalName: String,
        displayName: String,
        source: SubscriptionDetectionSource,
        hadRecurringSignals: Bool,
        importRecordIDs: Set<UUID>
    ) -> DetectionSuppressionRequest {
        DetectionSuppressionRequest(
            canonicalName: canonicalName,
            displayName: displayName,
            source: source,
            hadRecurringSignals: hadRecurringSignals,
            reason: "Suppressed using a saved user correction.",
            importRecordIDs: importRecordIDs
        )
    }

    func appendRecurringSuppressionIfNeeded(
        _ suppression: SubscriptionSuppression,
        to state: DetectionAccumulator
    ) {
        guard suppression.hadRecurringSignals else {
            return
        }

        state.clusterReports.append(
            SubscriptionClusterReport(
                displayName: suppression.displayName,
                status: .suppressed,
                source: suppression.detectionSource,
                hadRecurringSignals: suppression.hadRecurringSignals,
                reason: suppression.reason,
                importRecordIDs: suppression.importRecordIDs
            )
        )
        state.autoSuppressCount += 1
    }

    func applyRecurringDetection(
        _ summary: SubscriptionSummary,
        cluster: SubscriptionCandidateCluster,
        correction: MerchantCorrection?,
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        guard state.seenCanonicals.contains(summary.canonicalName) == false else {
            return
        }

        let rule = environment.rulesByCanonical[summary.canonicalName]
        if handleFalsePositiveRule(
            rule,
            canonicalName: summary.canonicalName,
            environment: environment
        ) {
            return
        }

        let subscription = detectedSubscription(
            from: summary,
            cluster: cluster,
            rule: rule,
            correction: correction,
            existing: environment.existingByCanonical[summary.canonicalName]
        )

        if environment.existingByCanonical[summary.canonicalName] == nil {
            environment.context.insert(subscription)
        }

        state.seenCanonicals.insert(summary.canonicalName)
        state.candidateCount += 1
        if summary.status == .needsReview {
            state.needsReviewCount += 1
        } else {
            state.autoConfirmCount += 1
        }
        linkTransactions(cluster.transactions, to: subscription)
        let llmContribution = await llmEvidenceContribution(
            for: summary,
            transactions: cluster.transactions,
            userRuleSummary: userRuleSummary(rule: rule, correction: correction)
        )
        if llmContribution != nil {
            state.llmEvaluationCount += 1
        }
        recordEvidence(
            candidateKey: summary.canonicalName,
            subscription: subscription,
            decision: summary.status == .needsReview ? .needsReview : .autoConfirmed,
            confidence: summary.confidence,
            deterministicScore: summary.confidence,
            factors: detectionFactors(
                summary: summary,
                transactions: cluster.transactions
            ),
            matchedTransactions: cluster.transactions,
            rejectedTransactions: [],
            rules: [],
            llmContribution: llmContribution,
            reason: summary.reason ?? "Detected from recurring transaction evidence.",
            environment: environment
        )
        state.clusterReports.append(
            SubscriptionClusterReport(
                displayName: summary.displayName,
                status: summary.status == .needsReview ? .needsReview : .detected,
                source: summary.detectionSource,
                hadRecurringSignals: true,
                reason: summary.reason,
                importRecordIDs: Set(cluster.transactions.compactMap(\.importRecordID))
            )
        )
    }
}
