import Foundation

enum SubscriptionDetectionSource {
    case primary
    case fallback
    case recentPurchase
}

enum SubscriptionDetectionDisposition {
    case detected(SubscriptionSummary)
    case needsReview(SubscriptionSummary)
    case suppressed(SubscriptionSuppression)
}

struct SubscriptionSuppression {
    let canonicalName: String
    let displayName: String
    let confidence: Double
    let reason: String
    let hadRecurringSignals: Bool
    let detectionSource: SubscriptionDetectionSource
    let importRecordIDs: Set<UUID>
}

extension SubscriptionDetectionService {
    func evaluate(
        cluster: SubscriptionCandidateCluster,
        source: SubscriptionDetectionSource = .primary,
        reviewOnly: Bool = false,
        confidenceBoost: Double = 0
    ) async -> SubscriptionDetectionDisposition {
        let orderedTransactions = cluster.transactions.sorted { $0.transactionDate < $1.transactionDate }
        guard let scoringInput = makeScoringInput(from: orderedTransactions) else {
            return .suppressed(
                SubscriptionSuppression(
                    canonicalName: cluster.canonicalName,
                    displayName: cluster.displayName,
                    confidence: 0,
                    reason: "Not enough recurring evidence to evaluate this merchant cluster yet.",
                    hadRecurringSignals: false,
                    detectionSource: source,
                    importRecordIDs: Set(cluster.transactions.compactMap(\.importRecordID))
                )
            )
        }

        let snapshot = makeScoringSnapshot(
            for: orderedTransactions,
            intervals: scoringInput.intervals,
            cadence: scoringInput.cadence
        )
        guard shouldHardReject(transactions: orderedTransactions, snapshot: snapshot) == false else {
            return .suppressed(
                SubscriptionSuppression(
                    canonicalName: cluster.canonicalName,
                    displayName: cluster.displayName,
                    confidence: 0,
                    reason: suppressionReason(for: snapshot),
                    hadRecurringSignals: true,
                    detectionSource: source,
                    importRecordIDs: Set(cluster.transactions.compactMap(\.importRecordID))
                )
            )
        }

        let baseScore = baseScore(for: snapshot)
        let (finalConfidence, reason) = await resolvedConfidenceAndReason(
            for: cluster,
            orderedTransactions: orderedTransactions,
            intervals: scoringInput.intervals,
            snapshot: snapshot,
            baseScore: baseScore,
            confidenceBoost: confidenceBoost
        )
        let evidence = candidateEvidence(for: snapshot)
        let shouldSurfaceForReview = shouldSurfaceForReview(
            snapshot: snapshot,
            finalConfidence: finalConfidence,
            source: source,
            evidence: evidence
        )
        guard finalConfidence >= 0.38 || shouldSurfaceForReview else {
            return .suppressed(
                SubscriptionSuppression(
                    canonicalName: cluster.canonicalName,
                    displayName: cluster.displayName,
                    confidence: finalConfidence,
                    reason: reason,
                    hadRecurringSignals: recurringEvidenceScore(for: snapshot) >= 0.7,
                    detectionSource: source,
                    importRecordIDs: Set(cluster.transactions.compactMap(\.importRecordID))
                )
            )
        }

        let summary = summary(
            for: cluster,
            orderedTransactions: orderedTransactions,
            snapshot: snapshot,
            confidence: finalConfidence,
            reason: reason,
            forceNeedsReview: reviewOnly,
            detectionSource: source,
            evidence: evidence
        )
        return summary.status == .needsReview ? .needsReview(summary) : .detected(summary)
    }

    func evaluateRecentPurchase(
        transaction: NormalizedTransaction,
        canonicalName: String,
        displayName: String,
        confidenceBoost: Double = 0
    ) async -> SubscriptionDetectionDisposition {
        let cadence = inferredSingleChargeCadence(for: transaction)
        guard cadence != .unknown else {
            return .suppressed(
                SubscriptionSuppression(
                    canonicalName: canonicalName,
                    displayName: displayName,
                    confidence: 0,
                    reason: "Recent charge did not provide enough cadence evidence yet.",
                    hadRecurringSignals: false,
                    detectionSource: .recentPurchase,
                    importRecordIDs: Set([transaction.importRecordID].compactMap { $0 })
                )
            )
        }

        let baseScore = recentPurchaseBaseScore(for: transaction)
        let draftReason = recentPurchaseReason(for: transaction, cadence: cadence)
        let (finalConfidence, reason) = await resolvedSingleChargeConfidenceAndReason(
            for: transaction,
            canonicalName: canonicalName,
            displayName: displayName,
            cadence: cadence,
            baseScore: baseScore,
            draftReason: draftReason,
            confidenceBoost: confidenceBoost
        )

        guard finalConfidence >= 0.62 else {
            return .suppressed(
                SubscriptionSuppression(
                    canonicalName: canonicalName,
                    displayName: displayName,
                    confidence: finalConfidence,
                    reason: reason,
                    hadRecurringSignals: false,
                    detectionSource: .recentPurchase,
                    importRecordIDs: Set([transaction.importRecordID].compactMap { $0 })
                )
            )
        }

        let summary = singleChargeSummary(
            for: transaction,
            canonicalName: canonicalName,
            displayName: displayName,
            cadence: cadence,
            confidence: finalConfidence,
            reason: reason
        )
        return .needsReview(summary)
    }
}

private extension SubscriptionDetectionService {
    func makeScoringInput(
        from orderedTransactions: [NormalizedTransaction]
    ) -> SubscriptionScoringInput? {
        guard orderedTransactions.count >= 2 else {
            return nil
        }

        let refundSignals = orderedTransactions.filter(transactionLooksLikeRefund).count
        guard refundSignals < orderedTransactions.count else {
            return nil
        }

        let intervals = zip(orderedTransactions, orderedTransactions.dropFirst()).map { lhs, rhs in
            Calendar.current.dateComponents([.day], from: lhs.transactionDate, to: rhs.transactionDate).day ?? 0
        }
        let cadence = inferCadence(
            from: intervals,
            occurrenceCount: orderedTransactions.count
        )

        if cadence != .unknown,
           orderedTransactions.count >= minimumOccurrences(for: cadence) {
            return SubscriptionScoringInput(intervals: intervals, cadence: cadence)
        }

        let sparseCadence = inferSparseCadence(
            from: intervals,
            transactions: orderedTransactions
        )
        guard sparseCadence != .unknown else {
            return nil
        }

        return SubscriptionScoringInput(intervals: intervals, cadence: sparseCadence)
    }

    func makeScoringSnapshot(
        for orderedTransactions: [NormalizedTransaction],
        intervals: [Int],
        cadence: SubscriptionCadence
    ) -> SubscriptionScoringSnapshot {
        let priceSamples = orderedTransactions.map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }
        let averagePrice = priceSamples.reduce(0, +) / Double(priceSamples.count)
        let minPrice = priceSamples.min() ?? averagePrice
        let maxPrice = priceSamples.max() ?? averagePrice
        let priceVariation = maxPrice > 0 ? (maxPrice - minPrice) / maxPrice : 0
        let dominantKind = dominantMerchantKind(for: orderedTransactions)
        let memoDiversity = memoDiversityScore(for: orderedTransactions)
        let descriptorStrength = descriptorStrength(for: orderedTransactions)
        let classificationConfidence = averageClassificationConfidence(for: orderedTransactions)
        let negativePenalty = min(
            1,
            categoryPenalty(for: orderedTransactions, dominantMerchantKind: dominantKind) +
            memoDiversityPenalty(
                memoDiversity: memoDiversity,
                descriptorStrength: descriptorStrength
            ) +
            financialMovementPenalty(for: orderedTransactions) +
            amountVariationPenalty(priceVariation: priceVariation) +
            appointmentPenalty(for: orderedTransactions) +
            marketplacePenalty(for: orderedTransactions)
        )

        return SubscriptionScoringSnapshot(
            cadence: cadence,
            transactionCount: orderedTransactions.count,
            averagePrice: averagePrice,
            minPrice: minPrice,
            maxPrice: maxPrice,
            priceVariation: priceVariation,
            intervalConsistency: recurrenceConsistency(for: intervals, cadence: cadence),
            amountStability: amountStabilityScore(for: priceVariation),
            keywordSupport: keywordSupportScore(for: orderedTransactions),
            dominantMerchantKind: dominantKind,
            merchantAffinity: averageSubscriptionAffinity(for: orderedTransactions),
            classificationConfidence: classificationConfidence,
            memoDiversity: memoDiversity,
            descriptorStrength: descriptorStrength,
            negativePenalty: negativePenalty,
            excludedCategoryCount: orderedTransactions.filter(isExcludedCategory).count,
            financialMovementCount: orderedTransactions.filter(isFinancialMovement).count,
            recurringBillOrNonSubscriptionCount: orderedTransactions.filter(isRecurringBillOrNonSubscriptionSpend).count,
            commerceNoiseCount: orderedTransactions.filter(hasCommerceNoiseSignals).count,
            knownSubscriptionSignalCount: orderedTransactions.filter(hasKnownSubscriptionServiceSignal).count,
            hasExplicitSubscriptionWording: orderedTransactions.contains(where: hasExplicitSubscriptionKeywords),
            hasStrongSubscriptionWording: orderedTransactions.contains(where: hasStrongSubscriptionWording)
        )
    }

    func baseScore(for snapshot: SubscriptionScoringSnapshot) -> Double {
        let weights: (interval: Double, amount: Double, keyword: Double, affinity: Double, negative: Double, classification: Double)
        switch snapshot.cadence {
        case .annual, .semiannual:
            weights = (interval: 0.22, amount: 0.16, keyword: 0.18, affinity: 0.20, negative: 0.12, classification: 0.12)
        default:
            weights = (interval: 0.32, amount: 0.18, keyword: 0.14, affinity: 0.14, negative: 0.12, classification: 0.10)
        }

        return max(
            0,
            min(
                0.99,
                (snapshot.intervalConsistency * weights.interval) +
                (snapshot.amountStability * weights.amount) +
                (snapshot.keywordSupport * weights.keyword) +
                (snapshot.merchantAffinity * weights.affinity) +
                (snapshot.lowNegativeSignalScore * weights.negative) +
                (snapshot.classificationConfidence * weights.classification)
            )
        )
    }

    func resolvedConfidenceAndReason(
        for cluster: SubscriptionCandidateCluster,
        orderedTransactions: [NormalizedTransaction],
        intervals: [Int],
        snapshot: SubscriptionScoringSnapshot,
        baseScore: Double,
        confidenceBoost: Double
    ) async -> (confidence: Double, reason: String) {
        let draftReason = reasonSummary(for: snapshot)
        guard automaticRecurringClusterEvaluationEnabled,
              shouldRunSecondPassAI(baseScore: baseScore, snapshot: snapshot) else {
            return (min(0.99, baseScore + confidenceBoost), draftReason)
        }

        let aiInput = makeRecurringClusterEvaluationInput(
            for: cluster,
            orderedTransactions: orderedTransactions,
            intervals: intervals,
            snapshot: snapshot
        )
        guard let evaluation = await intelligence.evaluateRecurringCluster(aiInput) else {
            return (min(0.99, baseScore + confidenceBoost), draftReason)
        }

        let aiScore = evaluation.isSubscription ? evaluation.confidence : (1 - evaluation.confidence)
        let finalConfidence = blendedAIDetectionConfidence(
            baseScore: baseScore,
            aiScore: aiScore,
            snapshot: snapshot,
            confidenceBoost: confidenceBoost
        )
        let finalReason = mergedReason(
            from: draftReason,
            evaluation: evaluation,
            finalConfidence: finalConfidence
        )
        return (finalConfidence, finalReason)
    }

    func resolvedSingleChargeConfidenceAndReason(
        for transaction: NormalizedTransaction,
        canonicalName: String,
        displayName: String,
        cadence: SubscriptionCadence,
        baseScore: Double,
        draftReason: String,
        confidenceBoost: Double
    ) async -> (confidence: Double, reason: String) {
        guard shouldRunSingleChargeAI(baseScore: baseScore, transaction: transaction) else {
            return (min(0.99, baseScore + confidenceBoost), draftReason)
        }

        let input = SingleChargeEvaluationInput(
            canonicalName: canonicalName,
            displayName: displayName,
            rawMerchant: transaction.merchantRaw,
            memo: transaction.memo,
            category: transaction.category,
            amount: abs(transaction.transactionAmount),
            transactionDate: transaction.transactionDate,
            merchantKind: transaction.merchantKind,
            subscriptionAffinity: max(
                transaction.merchantSubscriptionAffinity,
                transaction.merchantKind.defaultSubscriptionAffinity
            ),
            classificationConfidence: transaction.classificationConfidence,
            suggestedCadence: cadence
        )

        guard let evaluation = await intelligence.evaluateSingleCharge(input) else {
            return (min(0.99, baseScore + confidenceBoost), draftReason)
        }

        let aiScore = evaluation.isLikelySubscription ? evaluation.confidence : (1 - evaluation.confidence)
        let finalConfidence = blendedAISingleChargeConfidence(
            baseScore: baseScore,
            aiScore: aiScore,
            transaction: transaction,
            confidenceBoost: confidenceBoost
        )
        let finalReason = mergedSingleChargeReason(
            from: draftReason,
            evaluation: evaluation,
            finalConfidence: finalConfidence
        )
        return (finalConfidence, finalReason)
    }

    func makeRecurringClusterEvaluationInput(
        for cluster: SubscriptionCandidateCluster,
        orderedTransactions: [NormalizedTransaction],
        intervals: [Int],
        snapshot: SubscriptionScoringSnapshot
    ) -> RecurringClusterEvaluationInput {
        RecurringClusterEvaluationInput(
            canonicalName: cluster.canonicalName,
            displayName: cluster.displayName,
            rawMerchantVariants: Array(Set(orderedTransactions.map(\.merchantRaw))).sorted(),
            sampleMemos: Array(
                Set(
                    orderedTransactions.compactMap { $0.memo?.nilIfBlank }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                )
            )
            .sorted()
            .prefix(4)
            .map { $0 },
            sampleCategories: Array(
                Set(orderedTransactions.compactMap { $0.category?.nilIfBlank })
            )
            .sorted()
            .prefix(3)
            .map { $0 },
            chargeCount: orderedTransactions.count,
            intervals: intervals,
            firstChargeDate: orderedTransactions.first?.transactionDate,
            lastChargeDate: orderedTransactions.last?.transactionDate,
            amountMinimum: snapshot.minPrice,
            amountMaximum: snapshot.maxPrice,
            amountVariation: snapshot.priceVariation,
            detectedCadence: snapshot.cadence,
            merchantKind: snapshot.dominantMerchantKind,
            subscriptionAffinity: snapshot.merchantAffinity,
            classificationConfidence: snapshot.classificationConfidence,
            intervalConsistency: snapshot.intervalConsistency,
            amountStability: snapshot.amountStability,
            keywordSupport: snapshot.keywordSupport,
            descriptorStrength: snapshot.descriptorStrength,
            negativePenalty: snapshot.negativePenalty
        )
    }

    func blendedAIDetectionConfidence(
        baseScore: Double,
        aiScore: Double,
        snapshot: SubscriptionScoringSnapshot,
        confidenceBoost: Double
    ) -> Double {
        let aiWeight: Double
        if (0.45...0.82).contains(baseScore) || snapshot.dominantMerchantKind == .unknown {
            aiWeight = 0.55
        } else if snapshot.dominantMerchantKind == .membershipRetailer || snapshot.dominantMerchantKind == .marketplace {
            aiWeight = 0.45
        } else {
            aiWeight = 0.35
        }

        return max(
            0,
            min(0.99, (baseScore * (1 - aiWeight)) + (aiScore * aiWeight) + confidenceBoost)
        )
    }

    func blendedAISingleChargeConfidence(
        baseScore: Double,
        aiScore: Double,
        transaction: NormalizedTransaction,
        confidenceBoost: Double
    ) -> Double {
        let aiWeight: Double
        if (0.45...0.82).contains(baseScore) || transaction.merchantKind == .unknown {
            aiWeight = 0.6
        } else {
            aiWeight = 0.4
        }

        return max(
            0,
            min(0.99, (baseScore * (1 - aiWeight)) + (aiScore * aiWeight) + confidenceBoost)
        )
    }

    func mergedReason(
        from draftReason: String,
        evaluation: RecurringClusterEvaluationResult,
        finalConfidence: Double
    ) -> String {
        let resolvedReason = evaluation.reasonSummary.isEmpty ? draftReason : evaluation.reasonSummary
        guard evaluation.negativeSignals.isEmpty == false, finalConfidence < 0.9 else {
            return resolvedReason
        }

        return ([resolvedReason] + evaluation.negativeSignals)
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
    }

    func mergedSingleChargeReason(
        from draftReason: String,
        evaluation: SingleChargeEvaluationResult,
        finalConfidence: Double
    ) -> String {
        let resolvedReason = evaluation.reasonSummary.isEmpty ? draftReason : evaluation.reasonSummary
        guard evaluation.negativeSignals.isEmpty == false, finalConfidence < 0.9 else {
            return resolvedReason
        }

        return ([resolvedReason] + evaluation.negativeSignals)
            .filter { $0.isEmpty == false }
            .joined(separator: " • ")
    }

    func averageClassificationConfidence(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        return transactions
            .map(\.classificationConfidence)
            .reduce(0, +) / Double(transactions.count)
    }

    func recurringEvidenceScore(for snapshot: SubscriptionScoringSnapshot) -> Double {
        max(
            snapshot.intervalConsistency,
            max(snapshot.keywordSupport, snapshot.merchantAffinity)
        )
    }

    func candidateEvidence(
        for snapshot: SubscriptionScoringSnapshot
    ) -> SubscriptionCandidateEvidence {
        let strongCadence = snapshot.intervalConsistency >= 0.78
        let twoChargeMonthlyCadence =
            snapshot.transactionCount == 2 &&
            snapshot.cadence == .monthly &&
            snapshot.intervalConsistency >= 0.25
        let strongMerchant = snapshot.merchantAffinity >= 0.78 || snapshot.keywordSupport >= 0.45
        let strongClassification = snapshot.classificationConfidence >= 0.72
        let twoChargeMonthlyClassification =
            strongClassification ||
            (snapshot.hasExplicitSubscriptionWording && snapshot.keywordSupport >= 0.5)
        let supportsVariableBilling =
            snapshot.priceVariation <= 0.45 &&
            snapshot.intervalConsistency >= 0.72 &&
            snapshot.merchantAffinity >= 0.82 &&
            snapshot.dominantMerchantKind == .softwareOrSaaS
        let supportsSparseAutoConfirm =
            snapshot.transactionCount == 2 &&
            (snapshot.cadence == .annual || snapshot.cadence == .semiannual) &&
            strongCadence &&
            strongMerchant &&
            strongClassification &&
            snapshot.lowNegativeSignalScore >= 0.72
        let supportsTwoChargeMonthlyAutoConfirm =
            snapshot.transactionCount == 2 &&
            snapshot.cadence == .monthly &&
            twoChargeMonthlyCadence &&
            strongMerchant &&
            twoChargeMonthlyClassification &&
            snapshot.amountStability >= 0.85 &&
            snapshot.lowNegativeSignalScore >= 0.82 &&
            snapshot.keywordSupport >= 0.35 &&
            (
                snapshot.dominantMerchantKind == .subscriptionService ||
                snapshot.dominantMerchantKind == .softwareOrSaaS ||
                snapshot.dominantMerchantKind == .mediaStreaming
            )
        let supportsKnownServiceAutoConfirm =
            snapshot.transactionCount >= 2 &&
            snapshot.cadence != .unknown &&
            snapshot.knownSubscriptionSignalCount >= max(1, snapshot.transactionCount - 1) &&
            snapshot.recurringBillOrNonSubscriptionCount == 0 &&
            snapshot.commerceNoiseCount == 0 &&
            snapshot.financialMovementCount == 0 &&
            strongMerchant &&
            snapshot.classificationConfidence >= 0.55 &&
            snapshot.lowNegativeSignalScore >= 0.52 &&
            snapshot.amountStability >= 0.65
        let obviousNegative =
            (
                snapshot.dominantMerchantKind.isUsuallyNonSubscription &&
                snapshot.keywordSupport < 0.35 &&
                snapshot.descriptorStrength < 0.3
            ) ||
            (
                snapshot.financialMovementCount == snapshot.transactionCount &&
                snapshot.hasStrongSubscriptionWording == false
            ) ||
            (
                snapshot.recurringBillOrNonSubscriptionCount >= max(1, snapshot.transactionCount - 1) &&
                snapshot.hasExplicitSubscriptionWording == false
            ) ||
            (
                snapshot.commerceNoiseCount >= max(1, snapshot.transactionCount - 1) &&
                snapshot.hasExplicitSubscriptionWording == false
            )

        return SubscriptionCandidateEvidence(
            strongCadence: strongCadence,
            strongMerchant: strongMerchant,
            strongClassification: strongClassification,
            supportsVariableBilling: supportsVariableBilling,
            supportsSparseAutoConfirm: supportsSparseAutoConfirm,
            supportsTwoChargeMonthlyAutoConfirm: supportsTwoChargeMonthlyAutoConfirm,
            supportsKnownServiceAutoConfirm: supportsKnownServiceAutoConfirm,
            obviousNegative: obviousNegative,
            lowNegativeSignalScore: snapshot.lowNegativeSignalScore,
            amountStability: snapshot.amountStability
        )
    }

    func shouldSurfaceForReview(
        snapshot: SubscriptionScoringSnapshot,
        finalConfidence: Double,
        source: SubscriptionDetectionSource,
        evidence: SubscriptionCandidateEvidence
    ) -> Bool {
        if evidence.shouldAutoConfirm(
            confidence: finalConfidence,
            occurrenceCount: snapshot.transactionCount,
            requiredOccurrences: minimumOccurrences(for: snapshot.cadence)
        ) {
            return false
        }

        let reviewThreshold = source == .fallback ? 0.42 : 0.48
        guard finalConfidence >= reviewThreshold else {
            return false
        }
        guard snapshot.financialMovementCount < snapshot.transactionCount else {
            return false
        }
        guard snapshot.recurringBillOrNonSubscriptionCount < snapshot.transactionCount ||
                snapshot.hasExplicitSubscriptionWording else {
            return false
        }
        guard snapshot.commerceNoiseCount < snapshot.transactionCount ||
                snapshot.hasExplicitSubscriptionWording else {
            return false
        }
        guard snapshot.negativePenalty < 0.6 else {
            return false
        }

        let strongTiming = evidence.strongCadence
        let merchantSignals = evidence.strongMerchant
        let weakClassification = snapshot.classificationConfidence < 0.76
        let unstableAmounts = snapshot.amountStability < 0.5 && evidence.supportsVariableBilling == false

        if source == .fallback {
            return strongTiming && merchantSignals
        }

        return strongTiming && merchantSignals && (weakClassification || unstableAmounts || finalConfidence < 0.72)
    }

    func suppressionReason(for snapshot: SubscriptionScoringSnapshot) -> String {
        if snapshot.dominantMerchantKind.isUsuallyNonSubscription && snapshot.keywordSupport == 0 {
            return "Recurring pattern suppressed because the merchant profile looks non-subscription."
        }
        if snapshot.financialMovementCount >= max(1, snapshot.transactionCount - 1),
           snapshot.hasStrongSubscriptionWording == false {
            return "Recurring pattern suppressed because it looks like bank movement, not subscription spend."
        }
        if snapshot.recurringBillOrNonSubscriptionCount >= max(1, snapshot.transactionCount - 1),
           snapshot.hasExplicitSubscriptionWording == false {
            return "Recurring pattern suppressed because it looks like a bill or purchase stream, not a subscription."
        }
        if snapshot.commerceNoiseCount >= max(1, snapshot.transactionCount - 1),
           snapshot.hasExplicitSubscriptionWording == false {
            return "Recurring pattern suppressed because it looks like repeated commerce activity."
        }
        if snapshot.excludedCategoryCount >= max(2, snapshot.transactionCount - 1),
           snapshot.keywordSupport == 0 {
            return "Recurring pattern suppressed because nearly every charge falls into excluded categories."
        }
        return "Recurring pattern suppressed because the cluster still looks too noisy to trust."
    }

    func summary(
        for cluster: SubscriptionCandidateCluster,
        orderedTransactions: [NormalizedTransaction],
        snapshot: SubscriptionScoringSnapshot,
        confidence: Double,
        reason: String,
        forceNeedsReview: Bool,
        detectionSource: SubscriptionDetectionSource,
        evidence: SubscriptionCandidateEvidence
    ) -> SubscriptionSummary {
        let lastChargeDate = orderedTransactions.last?.transactionDate
        let status: SubscriptionStatus
        let inferredLifecycleStatus = inferStatus(lastChargeDate: lastChargeDate, cadence: snapshot.cadence)
        let confirmationThreshold: Double = switch snapshot.dominantMerchantKind {
        case .subscriptionService, .softwareOrSaaS, .mediaStreaming:
            0.72
        case .membershipRetailer:
            0.76
        case .utilityOrBiller:
            0.90
        case .unknown:
            0.82
        case .marketplace, .groceryRetailer, .restaurant, .medicalOrWellnessProvider, .transportOrTravel, .generalRetail:
            0.86
        }

        let classificationThreshold: Double = snapshot.dominantMerchantKind == .unknown ? 0.45 : 0.35
        let requiredOccurrences = minimumOccurrences(for: snapshot.cadence)
        let hasStrongManagedLibrarySignals =
            snapshot.intervalConsistency >= 0.8 &&
            (snapshot.amountStability >= 0.7 || evidence.supportsVariableBilling) &&
            snapshot.merchantAffinity >= 0.88 &&
            snapshot.classificationConfidence >= 0.82 &&
            snapshot.negativePenalty < 0.25 &&
            (snapshot.dominantMerchantKind == .softwareOrSaaS ||
             snapshot.dominantMerchantKind == .subscriptionService ||
             snapshot.dominantMerchantKind == .mediaStreaming)

        if shouldInferLongCancelledStatus(
            inferredLifecycleStatus: inferredLifecycleStatus,
            snapshot: snapshot,
            confidence: confidence,
            evidence: evidence
        ) {
            status = .former
        } else if forceNeedsReview {
            status = .needsReview
        } else if evidence.supportsTwoChargeMonthlyAutoConfirm, confidence >= 0.62 {
            status = inferredLifecycleStatus
        } else if evidence.supportsKnownServiceAutoConfirm, confidence >= 0.62 {
            status = inferredLifecycleStatus
        } else if orderedTransactions.count < requiredOccurrences && evidence.supportsSparseAutoConfirm == false {
            status = .needsReview
        } else if evidence.shouldAutoConfirm(
            confidence: confidence,
            occurrenceCount: orderedTransactions.count,
            requiredOccurrences: requiredOccurrences
        ) {
            status = inferredLifecycleStatus
        } else if hasStrongManagedLibrarySignals {
            status = inferredLifecycleStatus
        } else if confidence >= confirmationThreshold,
                  snapshot.classificationConfidence >= classificationThreshold {
            status = inferredLifecycleStatus
        } else {
            status = .needsReview
        }

        return SubscriptionSummary(
            canonicalName: cluster.canonicalName,
            displayName: cluster.displayName,
            cadence: snapshot.cadence,
            status: status,
            priceAmount: Decimal(snapshot.averagePrice),
            currency: orderedTransactions.last?.currency ?? "USD",
            lastChargeDate: lastChargeDate,
            confidence: confidence,
            category: orderedTransactions.last?.category?.nilIfBlank
                ?? snapshot.dominantMerchantKind.defaultServiceCategory,
            reason: reason,
            detectionSource: detectionSource
        )
    }

    func shouldInferLongCancelledStatus(
        inferredLifecycleStatus: SubscriptionStatus,
        snapshot: SubscriptionScoringSnapshot,
        confidence: Double,
        evidence: SubscriptionCandidateEvidence
    ) -> Bool {
        guard inferredLifecycleStatus == .former,
              snapshot.cadence != .unknown,
              evidence.obviousNegative == false,
              snapshot.negativePenalty < 0.6,
              confidence >= 0.55 else {
            return false
        }

        let hasRecurringProof =
            evidence.strongCadence &&
            snapshot.amountStability >= 0.45 &&
            snapshot.transactionCount >= minimumOccurrences(for: snapshot.cadence)
        let hasSubscriptionProof =
            evidence.strongMerchant ||
            snapshot.hasExplicitSubscriptionWording ||
            snapshot.classificationConfidence >= 0.68

        return hasRecurringProof && hasSubscriptionProof
    }

    func singleChargeSummary(
        for transaction: NormalizedTransaction,
        canonicalName: String,
        displayName: String,
        cadence: SubscriptionCadence,
        confidence: Double,
        reason: String
    ) -> SubscriptionSummary {
        let amount = abs(transaction.transactionAmount)
        return SubscriptionSummary(
            canonicalName: canonicalName,
            displayName: displayName,
            cadence: cadence,
            status: .needsReview,
            priceAmount: amount,
            currency: transaction.currency ?? "USD",
            lastChargeDate: transaction.transactionDate,
            confidence: confidence,
            category: transaction.category?.nilIfBlank
                ?? transaction.merchantKind.defaultServiceCategory,
            reason: reason,
            detectionSource: .recentPurchase
        )
    }
}

struct SubscriptionSummary {
    let canonicalName: String
    let displayName: String
    let cadence: SubscriptionCadence
    let status: SubscriptionStatus
    let priceAmount: Decimal
    let currency: String
    let lastChargeDate: Date?
    let confidence: Double
    let category: String?
    let reason: String?
    let detectionSource: SubscriptionDetectionSource
}

private struct SubscriptionScoringInput {
    let intervals: [Int]
    let cadence: SubscriptionCadence
}

struct SubscriptionScoringSnapshot {
    let cadence: SubscriptionCadence
    let transactionCount: Int
    let averagePrice: Double
    let minPrice: Double
    let maxPrice: Double
    let priceVariation: Double
    let intervalConsistency: Double
    let amountStability: Double
    let keywordSupport: Double
    let dominantMerchantKind: MerchantKind
    let merchantAffinity: Double
    let classificationConfidence: Double
    let memoDiversity: Double
    let descriptorStrength: Double
    let negativePenalty: Double
    let excludedCategoryCount: Int
    let financialMovementCount: Int
    let recurringBillOrNonSubscriptionCount: Int
    let commerceNoiseCount: Int
    let knownSubscriptionSignalCount: Int
    let hasExplicitSubscriptionWording: Bool
    let hasStrongSubscriptionWording: Bool

    var lowNegativeSignalScore: Double {
        max(0, 1 - negativePenalty)
    }
}

struct SubscriptionCandidateEvidence {
    let strongCadence: Bool
    let strongMerchant: Bool
    let strongClassification: Bool
    let supportsVariableBilling: Bool
    let supportsSparseAutoConfirm: Bool
    let supportsTwoChargeMonthlyAutoConfirm: Bool
    let supportsKnownServiceAutoConfirm: Bool
    let obviousNegative: Bool
    let lowNegativeSignalScore: Double
    let amountStability: Double

    func shouldAutoConfirm(
        confidence: Double,
        occurrenceCount: Int,
        requiredOccurrences: Int
    ) -> Bool {
        guard obviousNegative == false else {
            return false
        }

        if supportsSparseAutoConfirm && confidence >= 0.72 {
            return true
        }

        if supportsTwoChargeMonthlyAutoConfirm && confidence >= 0.62 {
            return true
        }

        if supportsKnownServiceAutoConfirm && confidence >= 0.62 {
            return true
        }

        guard occurrenceCount >= requiredOccurrences else {
            return false
        }

        guard strongCadence, strongMerchant, lowNegativeSignalScore >= 0.7 else {
            return false
        }

        let stableEnough = amountStability >= 0.45 || supportsVariableBilling
        guard stableEnough else {
            return false
        }

        return confidence >= 0.68 && (strongClassification || supportsVariableBilling)
    }
}
