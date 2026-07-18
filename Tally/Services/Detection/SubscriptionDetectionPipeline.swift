import Foundation
import SwiftData

extension SubscriptionDetectionService {
    func makeEnvironment(
        in context: ModelContext,
        detectionRun: DetectionRun
    ) throws -> DetectionEnvironment {
        let existingSubscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let reviewRules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        let matchRules = try context.fetch(FetchDescriptor<SubscriptionMatchRule>())

        return DetectionEnvironment(
            context: context,
            detectionRun: detectionRun,
            existingSubscriptions: existingSubscriptions,
            existingByCanonical: deduplicateSubscriptions(existingSubscriptions, in: context),
            rulesByCanonical: deduplicateRules(reviewRules, in: context),
            correctionsByCanonical: deduplicateCorrections(corrections, in: context),
            matchRules: deduplicateMatchRules(matchRules, in: context)
        )
    }

    func fetchTransactions(in context: ModelContext) throws -> [NormalizedTransaction] {
        let descriptor = FetchDescriptor<NormalizedTransaction>(
            sortBy: [SortDescriptor(\.transactionDate, order: .forward)]
        )
        return try context.fetch(descriptor)
    }

    func prepareTransactions(_ transactions: [NormalizedTransaction]) async {
        await resetSubscriptionLinks(for: transactions)
        refreshProcessorMaskedTransactions(transactions)
    }

    func runDetectionPasses(
        on debitTransactions: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        guard Task.isCancelled == false else { return }
        let discoverableTransactions = debitTransactions.filter {
            $0.subscriptionID == nil && state.suppressedTransactionIDs.contains($0.id) == false
        }
        let groups = Dictionary(grouping: discoverableTransactions, by: \.merchantNormalized)
        await rebuildDetectedSubscriptions(
            from: groups,
            environment: environment,
            state: state,
            source: .primary,
            reviewOnly: false
        )
        guard Task.isCancelled == false else { return }

        let remainingDebitTransactions = debitTransactions.filter {
            $0.subscriptionID == nil && state.suppressedTransactionIDs.contains($0.id) == false
        }
        await rebuildFallbackSubscriptions(
            from: remainingDebitTransactions,
            environment: environment,
            state: state
        )
        guard Task.isCancelled == false else { return }

        let postFallbackTransactions = debitTransactions.filter {
            $0.subscriptionID == nil && state.suppressedTransactionIDs.contains($0.id) == false
        }
        await rebuildRecentPurchaseSubscriptions(
            from: postFallbackTransactions,
            environment: environment,
            state: state
        )
        guard Task.isCancelled == false else { return }

        await applyManualSubscriptions(
            from: environment.rulesByCanonical,
            existingByCanonical: environment.existingByCanonical,
            debitTransactions: debitTransactions,
            in: environment.context,
            seenCanonicals: &state.seenCanonicals
        )
    }

    func resetSubscriptionLinks(for transactions: [NormalizedTransaction]) async {
        for (index, transaction) in transactions.enumerated() {
            guard Task.isCancelled == false else { return }
            transaction.subscriptionID = nil
            if index.isMultiple(of: 250) {
                await Task.yield()
            }
        }
    }

    func refreshProcessorMaskedTransactions(_ transactions: [NormalizedTransaction]) {
        let unmasker = PaymentProcessorUnmasker()
        let classifier = HeuristicMerchantClassifier()

        for transaction in transactions {
            guard Task.isCancelled == false else { return }
            let result = unmasker.unmask(
                rawMerchant: transaction.merchantRaw,
                memo: transaction.memo,
                category: transaction.category
            )
            guard result.isPaymentProcessor else {
                continue
            }

            let refreshed = classifier.classify(
                rawMerchant: transaction.merchantRaw,
                memo: transaction.memo,
                category: transaction.category,
                amount: transaction.transactionAmount
            )
            transaction.merchantNormalized = refreshed.canonicalName
            transaction.merchantKind = refreshed.merchantKind
            transaction.merchantSubscriptionAffinity = max(
                transaction.merchantSubscriptionAffinity,
                refreshed.subscriptionAffinity
            )
            transaction.classificationConfidence = max(
                transaction.classificationConfidence,
                refreshed.confidence
            )
            if let serviceCategory = refreshed.serviceCategory.nilIfBlank {
                transaction.category = serviceCategory
            }
        }
    }

    func rebuildDetectedSubscriptions(
        from groups: [String: [NormalizedTransaction]],
        environment: DetectionEnvironment,
        state: DetectionAccumulator,
        source: SubscriptionDetectionSource,
        reviewOnly: Bool
    ) async {
        for (index, merchant) in groups.keys.sorted().enumerated() {
            guard Task.isCancelled == false else { return }
            guard let merchantTransactions = groups[merchant] else {
                continue
            }

            for cluster in candidateClusters(for: merchant, transactions: merchantTransactions) {
                guard Task.isCancelled == false else { return }
                await applyDetectedCluster(
                    cluster,
                    environment: environment,
                    state: state,
                    source: source,
                    reviewOnly: reviewOnly
                )
            }

            if index.isMultiple(of: 8) {
                await Task.yield()
            }
        }
    }

    func rebuildFallbackSubscriptions(
        from transactions: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        for group in fallbackRecoveryGroups(from: transactions) {
            guard Task.isCancelled == false else { return }
            for cluster in candidateClusters(
                for: group.merchant,
                transactions: group.transactions,
                mode: .fallback
            ) {
                guard Task.isCancelled == false else { return }
                await applyDetectedCluster(
                    cluster,
                    environment: environment,
                    state: state,
                    source: .fallback,
                    reviewOnly: true
                )
            }
        }
    }

    func rebuildRecentPurchaseSubscriptions(
        from transactions: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        let singleChargeCandidates = singleChargeCandidates(from: transactions)

        for (index, transaction) in singleChargeCandidates.enumerated() {
            guard Task.isCancelled == false else { return }
            guard let candidate = recentPurchaseCandidate(
                for: transaction,
                environment: environment,
                state: state
            ) else {
                continue
            }

            let disposition = await evaluateRecentPurchase(
                transaction: candidate.transaction,
                canonicalName: candidate.canonicalName,
                displayName: candidate.displayName,
                confidenceBoost: confidenceBoost(for: candidate.correction)
            )

            await applySingleChargeDisposition(
                disposition,
                candidate: candidate,
                environment: environment,
                state: state
            )

            if index.isMultiple(of: 8) {
                await Task.yield()
            }
        }
    }

    func applyDetectedCluster(
        _ cluster: SubscriptionCandidateCluster,
        environment: DetectionEnvironment,
        state: DetectionAccumulator,
        source: SubscriptionDetectionSource,
        reviewOnly: Bool
    ) async {
        let correction = environment.correctionsByCanonical[cluster.canonicalName]
        if handleMerchantCorrectionSuppression(
            correction,
            request: suppressionRequest(
                canonicalName: cluster.canonicalName,
                displayName: cluster.displayName,
                source: source,
                hadRecurringSignals: true,
                importRecordIDs: Set(cluster.transactions.compactMap(\.importRecordID))
            ),
            environment: environment,
            state: state
        ) {
            return
        }

        let disposition = await evaluate(
            cluster: cluster,
            source: source,
            reviewOnly: reviewOnly,
            confidenceBoost: confidenceBoost(for: correction)
        )

        switch disposition {
        case let .suppressed(suppression):
            recordEvidence(
                candidateKey: suppression.canonicalName,
                decision: .autoSuppressed,
                confidence: suppression.confidence,
                deterministicScore: suppression.confidence,
                factors: [
                    SubscriptionEvidenceFactor(
                        key: "category_negative_signal",
                        weight: 0.5,
                        score: 1 - suppression.confidence,
                        source: "deterministic_detection",
                        description: suppression.reason
                    )
                ],
                matchedTransactions: [],
                rejectedTransactions: cluster.transactions,
                rules: [],
                reason: suppression.reason,
                environment: environment
            )
            appendRecurringSuppressionIfNeeded(suppression, to: state)
        case let .detected(summary), let .needsReview(summary):
            await applyRecurringDetection(
                summary,
                cluster: cluster,
                correction: correction,
                environment: environment,
                state: state
            )
        }
    }

    func applySingleChargeDisposition(
        _ disposition: SubscriptionDetectionDisposition,
        candidate: DetectionSingleChargeCandidate,
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        switch disposition {
        case let .suppressed(suppression):
            state.autoSuppressCount += 1
            recordEvidence(
                candidateKey: suppression.canonicalName,
                decision: .autoSuppressed,
                confidence: suppression.confidence,
                deterministicScore: suppression.confidence,
                factors: [
                    SubscriptionEvidenceFactor(
                        key: "category_negative_signal",
                        weight: 0.5,
                        score: 1 - suppression.confidence,
                        source: "single_charge_detection",
                        description: suppression.reason
                    )
                ],
                matchedTransactions: [],
                rejectedTransactions: [candidate.transaction],
                rules: [],
                reason: suppression.reason,
                environment: environment
            )
            state.clusterReports.append(
                SubscriptionClusterReport(
                    canonicalName: suppression.canonicalName,
                    displayName: suppression.displayName,
                    status: .suppressed,
                    source: suppression.detectionSource,
                    hadRecurringSignals: suppression.hadRecurringSignals,
                    reason: suppression.reason,
                    importRecordIDs: suppression.importRecordIDs
                )
            )
        case let .detected(summary), let .needsReview(summary):
            guard state.seenCanonicals.contains(summary.canonicalName) == false else {
                return
            }

            let cluster = SubscriptionCandidateCluster(
                canonicalName: candidate.canonicalName,
                displayName: candidate.displayName,
                transactions: [candidate.transaction]
            )
            let subscription = detectedSubscription(
                from: summary,
                cluster: cluster,
                rule: candidate.rule,
                correction: candidate.correction,
                existing: environment.existingByCanonical[summary.canonicalName]
            )

            if environment.existingByCanonical[summary.canonicalName] == nil {
                environment.context.insert(subscription)
            }

            linkTransactions([candidate.transaction], to: subscription)
            state.seenCanonicals.insert(summary.canonicalName)
            state.candidateCount += 1
            state.needsReviewCount += 1
            let llmContribution = await llmEvidenceContribution(
                for: summary,
                transactions: [candidate.transaction],
                userRuleSummary: userRuleSummary(rule: candidate.rule, correction: candidate.correction)
            )
            if llmContribution != nil {
                state.llmEvaluationCount += 1
            }
            recordEvidence(
                candidateKey: summary.canonicalName,
                subscription: subscription,
                decision: .needsReview,
                confidence: summary.confidence,
                deterministicScore: summary.confidence,
                factors: detectionFactors(
                    summary: summary,
                    transactions: [candidate.transaction]
                ),
                matchedTransactions: [candidate.transaction],
                rejectedTransactions: [],
                rules: [],
                llmContribution: llmContribution,
                reason: summary.reason ?? "Recent charge needs review as a possible subscription.",
                environment: environment
            )
            state.clusterReports.append(
                SubscriptionClusterReport(
                    canonicalName: summary.canonicalName,
                    displayName: summary.displayName,
                    status: .needsReview,
                    source: .recentPurchase,
                    hadRecurringSignals: false,
                    reason: summary.reason,
                    importRecordIDs: Set([candidate.transaction.importRecordID].compactMap { $0 })
                )
            )
        }
    }

}
