import Foundation
import SwiftData

extension SubscriptionDetectionService {
    func synchronizeDerivedMatchRules(
        in context: ModelContext,
        transactions: [NormalizedTransaction]
    ) throws {
        let reviewRules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>())
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let existingRules = try context.fetch(FetchDescriptor<SubscriptionMatchRule>())

        var existingByKey = existingRules.reduce(into: [String: SubscriptionMatchRule]()) { result, rule in
            result[
                matchRuleKey(
                    canonicalName: rule.canonicalName,
                    isNegative: rule.isNegativeRule,
                    source: rule.createdFrom
                )
            ] = rule
        }
        let subscriptionsByCanonical = subscriptions.reduce(into: [String: Subscription]()) { result, subscription in
            result[subscription.canonicalName] = subscription
        }
        let rawMerchantsByCanonical = rawMerchantsByCanonicalName(from: transactions)
        let positiveReviewCanonicals = Set(
            reviewRules
                .filter { $0.isFalsePositive == false }
                .filter {
                    $0.isUserConfirmed ||
                        $0.overridePriceAmount != nil ||
                        $0.overrideCadence != nil ||
                        $0.overrideStatus != nil
                }
                .map(\.canonicalName)
        )

        for correction in corrections where correction.isSubscription == false {
            let key = matchRuleKey(
                canonicalName: correction.canonicalName,
                isNegative: true,
                source: .userCorrection
            )
            if positiveReviewCanonicals.contains(correction.canonicalName) {
                if let existingRule = existingByKey[key] {
                    context.delete(existingRule)
                    existingByKey[key] = nil
                }
                continue
            }

            let rule = existingByKey[key] ?? SubscriptionMatchRule(
                canonicalName: correction.canonicalName,
                isNegativeRule: true,
                createdFrom: .userCorrection
            )
            if existingByKey[key] == nil {
                context.insert(rule)
                existingByKey[key] = rule
            }

            update(
                rule,
                canonicalName: correction.canonicalName,
                subscription: nil,
                rawMerchants: rawMerchantsByCanonical[correction.canonicalName] ?? [],
                amount: nil,
                currency: nil,
                confidence: 1,
                isNegative: true,
                source: .userCorrection,
                priority: 1_100
            )
        }

        for reviewRule in reviewRules {
            guard reviewRule.isFalsePositive ||
                reviewRule.isUserConfirmed ||
                reviewRule.overridePriceAmount != nil ||
                reviewRule.overrideCadence != nil ||
                reviewRule.overrideStatus != nil else {
                continue
            }

            let subscription = subscriptionsByCanonical[reviewRule.canonicalName]
            let isNegative = reviewRule.isFalsePositive
            let key = matchRuleKey(
                canonicalName: reviewRule.canonicalName,
                isNegative: isNegative,
                source: .reviewRule
            )
            let oppositeKey = matchRuleKey(
                canonicalName: reviewRule.canonicalName,
                isNegative: !isNegative,
                source: .reviewRule
            )
            if let oppositeRule = existingByKey[oppositeKey] {
                context.delete(oppositeRule)
                existingByKey[oppositeKey] = nil
            }

            let rule = existingByKey[key] ?? SubscriptionMatchRule(
                subscriptionID: subscription?.id,
                canonicalName: reviewRule.canonicalName,
                isNegativeRule: isNegative,
                createdFrom: .reviewRule
            )
            if existingByKey[key] == nil {
                context.insert(rule)
                existingByKey[key] = rule
            }

            update(
                rule,
                canonicalName: reviewRule.canonicalName,
                subscription: subscription,
                rawMerchants: rawMerchantsByCanonical[reviewRule.canonicalName] ?? [],
                amount: reviewRule.overridePriceAmount ?? subscription?.priceAmount,
                currency: reviewRule.overridePriceCurrency ?? subscription?.priceCurrency,
                confidence: reviewRule.isUserConfirmed ? 1 : 0.86,
                isNegative: isNegative,
                source: .reviewRule,
                priority: isNegative ? 1_000 : 900
            )
        }

        for subscription in subscriptions where shouldDeriveMatchRule(from: subscription) {
            let key = matchRuleKey(
                canonicalName: subscription.canonicalName,
                isNegative: false,
                source: .confirmedSubscription
            )
            let rule = existingByKey[key] ?? SubscriptionMatchRule(
                subscriptionID: subscription.id,
                canonicalName: subscription.canonicalName,
                createdFrom: .confirmedSubscription
            )
            if existingByKey[key] == nil {
                context.insert(rule)
                existingByKey[key] = rule
            }

            update(
                rule,
                canonicalName: subscription.canonicalName,
                subscription: subscription,
                rawMerchants: rawMerchantsByCanonical[subscription.canonicalName] ?? [],
                amount: subscription.priceAmount,
                currency: subscription.priceCurrency,
                confidence: subscription.isUserConfirmed ? 1 : max(subscription.confidenceScore, 0.78),
                isNegative: false,
                source: .confirmedSubscription,
                priority: subscription.isUserConfirmed ? 850 : 700
            )
        }
    }

    func applyMatchRules(
        to debitTransactions: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        let orderedRules = environment.matchRules.sorted {
            if $0.isNegativeRule != $1.isNegativeRule {
                return $0.isNegativeRule && !$1.isNegativeRule
            }
            return $0.priority > $1.priority
        }

        for (index, rule) in orderedRules.enumerated() {
            let matches = debitTransactions.filter { transaction in
                if state.suppressedTransactionIDs.contains(transaction.id) {
                    return false
                }
                if rule.isNegativeRule == false, transaction.subscriptionID != nil {
                    return false
                }
                return ruleMatches(rule, transaction: transaction)
            }

            if rule.isNegativeRule {
                applyNegativeMatchRule(
                    rule,
                    matches: matches,
                    environment: environment,
                    state: state
                )
            } else {
                applyPositiveMatchRule(
                    rule,
                    matches: matches,
                    environment: environment,
                    state: state
                )
            }

            rule.lastReplayAt = .now
            rule.updatedAt = .now

            if index.isMultiple(of: 8) {
                await Task.yield()
            }
        }
    }

    func reconcileOccurrences(
        for subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        detectionRun: DetectionRun,
        in context: ModelContext
    ) throws {
        let existingExpectations = try context.fetch(FetchDescriptor<SubscriptionScheduleExpectation>())
        let existingOccurrences = try context.fetch(FetchDescriptor<SubscriptionOccurrence>())
        var expectationsBySubscription = Dictionary(
            uniqueKeysWithValues: existingExpectations.map { ($0.subscriptionID, $0) }
        )
        let transactionsBySubscription = Dictionary(grouping: transactions.compactMap { transaction -> NormalizedTransaction? in
            transaction.subscriptionID == nil ? nil : transaction
        }, by: { $0.subscriptionID ?? UUID() })

        for subscription in subscriptions {
            let linkedTransactions = (transactionsBySubscription[subscription.id] ?? [])
                .sorted { $0.transactionDate < $1.transactionDate }
            let expectation = expectationsBySubscription[subscription.id] ?? makeScheduleExpectation(
                for: subscription,
                linkedTransactions: linkedTransactions,
                context: context
            )
            expectationsBySubscription[subscription.id] = expectation
            updateScheduleExpectation(
                expectation,
                subscription: subscription,
                linkedTransactions: linkedTransactions
            )
            let previouslyMissedDates = Set(
                existingOccurrences
                    .filter { $0.subscriptionID == subscription.id && $0.status == .missed }
                    .map { Calendar.current.startOfDay(for: $0.expectedDate) }
            )

            for occurrence in existingOccurrences where occurrence.subscriptionID == subscription.id {
                context.delete(occurrence)
            }

            let occurrences = projectedOccurrences(
                for: subscription,
                expectation: expectation,
                linkedTransactions: linkedTransactions,
                detectionRun: detectionRun,
                in: context
            )
            let missedCount = occurrences.filter {
                $0.status == .missed &&
                    previouslyMissedDates.contains(Calendar.current.startOfDay(for: $0.expectedDate)) == false
            }.count
            if missedCount > 0 {
                subscription.confidenceScore = max(
                    0,
                    subscription.confidenceScore - min(0.3, Double(missedCount) * 0.08)
                )
            }
        }
    }
}

extension SubscriptionDetectionService {
    func matchRuleKey(
        canonicalName: String,
        isNegative: Bool,
        source: SubscriptionMatchRuleSource
    ) -> String {
        [
            canonicalName.lowercased(),
            isNegative ? "negative" : "positive",
            source.rawValue
        ].joined(separator: "|")
    }

    func rawMerchantsByCanonicalName(
        from transactions: [NormalizedTransaction]
    ) -> [String: [String]] {
        var result: [String: Set<String>] = [:]
        for transaction in transactions {
            result[transaction.merchantNormalized, default: []].insert(transaction.merchantRaw)
            if let subscriptionID = transaction.subscriptionID {
                result[subscriptionID.uuidString, default: []].insert(transaction.merchantRaw)
            }
        }
        return result.mapValues { Array($0).sorted() }
    }

    func shouldDeriveMatchRule(from subscription: Subscription) -> Bool {
        subscription.creationPath == .manual ||
            subscription.libraryState == .manual ||
            subscription.isUserConfirmed
    }

    func update(
        _ rule: SubscriptionMatchRule,
        canonicalName: String,
        subscription: Subscription?,
        rawMerchants: [String],
        amount: Decimal?,
        currency: String?,
        confidence: Double,
        isNegative: Bool,
        source: SubscriptionMatchRuleSource,
        priority: Int
    ) {
        rule.subscriptionID = subscription?.id ?? rule.subscriptionID
        rule.canonicalName = canonicalName
        rule.allowedRawMerchantsJSON = SubscriptionEvidenceJSON.encodeStrings(rawMerchants)
        rule.requiredTokensJSON = SubscriptionEvidenceJSON.encodeStrings(tokenHints(for: canonicalName))
        rule.amountMedian = isNegative ? nil : amount
        if let amount, isNegative == false {
            let absolute = abs((amount as NSDecimalNumber).doubleValue)
            let tolerance = max(2.5, absolute * rule.amountTolerancePercent)
            rule.amountMinimum = Decimal(absolute - tolerance)
            rule.amountMaximum = Decimal(absolute + tolerance)
        } else {
            rule.amountMinimum = nil
            rule.amountMaximum = nil
        }
        rule.currencyCode = currency?.nilIfBlank
        rule.confidence = confidence
        rule.isNegativeRule = isNegative
        rule.createdFrom = source
        rule.priority = priority
        rule.updatedAt = .now
    }

    func tokenHints(for canonicalName: String) -> [String] {
        canonicalName
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .prefix(3)
            .map { $0 }
    }

    func applyNegativeMatchRule(
        _ rule: SubscriptionMatchRule,
        matches: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) {
        guard matches.isEmpty == false else {
            return
        }
        state.suppressedTransactionIDs.formUnion(matches.map(\.id))
        rule.replayMatchCount = matches.count
        state.autoSuppressCount += 1

        recordEvidence(
            candidateKey: rule.canonicalName,
            decision: .ruleRejected,
            confidence: rule.confidence,
            deterministicScore: rule.confidence,
            factors: [
                SubscriptionEvidenceFactor(
                    key: "user_negative_rule",
                    weight: 1,
                    score: rule.confidence,
                    source: "subscription_match_rule",
                    description: "A saved negative rule suppressed matching transactions."
                )
            ],
            matchedTransactions: [],
            rejectedTransactions: matches,
            rules: [rule],
            reason: "Suppressed by a saved match rule.",
            environment: environment
        )

        state.clusterReports.append(
            SubscriptionClusterReport(
                canonicalName: rule.canonicalName,
                displayName: rule.canonicalName,
                status: .suppressed,
                source: .primary,
                hadRecurringSignals: true,
                reason: "Suppressed by a saved match rule.",
                importRecordIDs: Set(matches.compactMap(\.importRecordID))
            )
        )
    }

    func applyPositiveMatchRule(
        _ rule: SubscriptionMatchRule,
        matches: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) {
        guard matches.isEmpty == false ||
            environment.existingByCanonical[rule.canonicalName] != nil else {
            return
        }

        let existing = environment.existingByCanonical[rule.canonicalName]
        if matches.isEmpty, existing != nil {
            return
        }

        let reviewRule = environment.rulesByCanonical[rule.canonicalName]
        let subscription = existing ?? subscriptionFromMatchRule(
            rule,
            matches: matches,
            reviewRule: reviewRule
        )
        if existing == nil {
            environment.context.insert(subscription)
        }

        for transaction in matches {
            transaction.subscriptionID = subscription.id
        }
        if matches.isEmpty == false {
            refreshSubscriptionFromRuleMatches(
                subscription,
                matches: matches,
                rule: rule,
                reviewRule: reviewRule
            )
        }

        rule.subscriptionID = subscription.id
        rule.replayMatchCount = matches.count
        rule.replayCollisionCount = matches.filter {
            $0.merchantNormalized != rule.canonicalName &&
                $0.merchantRaw.localizedStandardContains(rule.canonicalName) == false
        }.count
        state.ruleMatchCount += matches.count
        state.seenCanonicals.insert(subscription.canonicalName)

        recordEvidence(
            candidateKey: rule.canonicalName,
            subscription: subscription,
            decision: .ruleMatched,
            confidence: rule.confidence,
            deterministicScore: rule.confidence,
            factors: [
                SubscriptionEvidenceFactor(
                    key: "user_confirmed_rule",
                    weight: 0.7,
                    score: rule.confidence,
                    source: "subscription_match_rule",
                    description: "A durable match rule linked these transactions before clustering."
                ),
                SubscriptionEvidenceFactor(
                    key: "amount_band_match",
                    weight: 0.3,
                    score: amountBandScore(rule: rule, matches: matches),
                    source: "subscription_match_rule",
                    description: "Matched charges fit the saved amount window."
                )
            ],
            matchedTransactions: matches,
            rejectedTransactions: [],
            rules: [rule],
            reason: "Linked by a saved match rule before candidate discovery.",
            environment: environment
        )

        state.clusterReports.append(
            SubscriptionClusterReport(
                canonicalName: subscription.canonicalName,
                displayName: subscription.displayName,
                status: .detected,
                source: .primary,
                hadRecurringSignals: true,
                reason: "Linked by a saved match rule before candidate discovery.",
                importRecordIDs: Set(matches.compactMap(\.importRecordID))
            )
        )
    }

    func refreshSubscriptionFromRuleMatches(
        _ subscription: Subscription,
        matches: [NormalizedTransaction],
        rule: SubscriptionMatchRule,
        reviewRule: SubscriptionReviewRule?
    ) {
        let sorted = matches.sorted { $0.transactionDate < $1.transactionDate }
        guard let latest = sorted.last else {
            return
        }

        let cadence = reviewRule?.overrideCadence ?? subscription.cadence
        let amount = reviewRule?.overridePriceAmount ?? abs(latest.transactionAmount)
        let lastChargeDate = reviewRule?.overrideLastChargeDate ?? latest.transactionDate
        subscription.cadence = cadence
        let shouldRefreshAmount = reviewRule?.overridePriceAmount != nil ||
            amountDeltaPercent(expected: subscription.priceAmount, actual: amount).map {
                abs($0) <= 0.12
            } ?? true
        if shouldRefreshAmount {
            subscription.priceAmount = amount
        }
        subscription.priceCurrency = reviewRule?.overridePriceCurrency ?? latest.currency ?? subscription.priceCurrency
        subscription.normalizedMonthlyAmount = normalizeMonthly(price: subscription.priceAmount, cadence: cadence)
        subscription.lastChargeDate = lastChargeDate
        subscription.predictedNextChargeDate = predictNextCharge(from: lastChargeDate, cadence: cadence)
        subscription.firstChargeDate = sorted.first?.transactionDate ?? subscription.firstChargeDate
        if reviewRule?.overrideStatus == nil, subscription.status == .former {
            subscription.status = .active
            subscription.libraryState = subscription.isUserConfirmed ? .confirmed : subscription.libraryState
        }
    }

    func subscriptionFromMatchRule(
        _ rule: SubscriptionMatchRule,
        matches: [NormalizedTransaction],
        reviewRule: SubscriptionReviewRule?
    ) -> Subscription {
        let sorted = matches.sorted { $0.transactionDate < $1.transactionDate }
        let lastChargeDate = sorted.last?.transactionDate
        let amount = reviewRule?.overridePriceAmount ?? rule.amountMedian ?? sorted.last.map { abs($0.transactionAmount) } ?? 0
        let cadence = reviewRule?.overrideCadence ?? SubscriptionCadence.monthly
        return Subscription(
            canonicalName: rule.canonicalName,
            displayName: reviewRule?.overrideDisplayName?.nilIfBlank ?? rule.canonicalName,
            status: reviewRule?.overrideStatus ?? .active,
            libraryState: .confirmed,
            cadence: cadence,
            priceAmount: amount,
            priceCurrency: reviewRule?.overridePriceCurrency?.nilIfBlank ?? rule.currencyCode ?? sorted.last?.currency ?? "USD",
            normalizedMonthlyAmount: normalizeMonthly(price: amount, cadence: cadence),
            lastChargeDate: lastChargeDate,
            predictedNextChargeDate: predictNextCharge(from: lastChargeDate, cadence: cadence),
            confidenceScore: rule.confidence,
            isUserConfirmed: reviewRule?.isUserConfirmed ?? true,
            serviceCategory: reviewRule?.overrideCategory ?? sorted.last?.category,
            detectionReason: "Created from a durable match rule.",
            notes: reviewRule?.notes
        )
    }

    func ruleMatches(_ rule: SubscriptionMatchRule, transaction: NormalizedTransaction) -> Bool {
        if let sourceHint = rule.sourceHint, transaction.source != sourceHint {
            return false
        }
        if let accountHint = rule.accountHint?.nilIfBlank,
           transaction.accountName != accountHint {
            return false
        }
        if let currencyCode = rule.currencyCode?.nilIfBlank {
            let normalizedCurrencyCode = currencyCode.uppercased()
            if let transactionCurrency = transaction.currency?.uppercased() {
                if transactionCurrency != normalizedCurrencyCode {
                    return false
                }
            } else if normalizedCurrencyCode != "USD" {
                return false
            }
        }

        let amount = abs((transaction.transactionAmount as NSDecimalNumber).doubleValue)
        let amountMatchesMinimum = rule.amountMinimum.map {
            amount >= ($0 as NSDecimalNumber).doubleValue
        } ?? true
        let amountMatchesMaximum = rule.amountMaximum.map {
            amount <= ($0 as NSDecimalNumber).doubleValue
        } ?? true
        let amountMatchesBand = amountMatchesMinimum && amountMatchesMaximum
        let canBypassAmountBand = rule.subscriptionID != nil && rule.isNegativeRule == false

        let text = [
            transaction.merchantRaw,
            transaction.merchantNormalized,
            transaction.memo ?? "",
            transaction.category ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
        let allowedRawMerchants = SubscriptionEvidenceJSON.decodeStrings(rule.allowedRawMerchantsJSON)
        let requiredTokens = SubscriptionEvidenceJSON.decodeStrings(rule.requiredTokensJSON)
        let excludedTokens = SubscriptionEvidenceJSON.decodeStrings(rule.excludedTokensJSON)

        if excludedTokens.contains(where: { text.localizedStandardContains($0) }) {
            return false
        }

        let exactCanonicalMatch = transaction.merchantNormalized.caseInsensitiveCompare(rule.canonicalName) == .orderedSame
        let canonicalSearchToken = rule.canonicalName.evidenceSearchToken
        let canonicalTextMatch = canonicalSearchToken.count >= 3 &&
            text.localizedStandardContains(canonicalSearchToken)
        let rawMatch = allowedRawMerchants.isEmpty == false &&
            allowedRawMerchants.contains(transaction.merchantRaw)
        let hasRequiredTokens = requiredTokens.isEmpty == false
        let tokenMatch = hasRequiredTokens &&
            requiredTokens.allSatisfy { text.localizedStandardContains($0) }

        if rawMatch {
            return amountMatchesBand || canBypassAmountBand
        }
        if hasRequiredTokens, tokenMatch == false {
            return false
        }

        let identityMatches = exactCanonicalMatch || canonicalTextMatch || tokenMatch
        guard identityMatches else {
            return false
        }

        return amountMatchesBand || canBypassAmountBand
    }

    func amountBandScore(rule: SubscriptionMatchRule, matches: [NormalizedTransaction]) -> Double {
        guard matches.isEmpty == false else {
            return 0
        }
        return matches.reduce(0.0) { partial, transaction in
            let amount = abs((transaction.transactionAmount as NSDecimalNumber).doubleValue)
            let minimum = rule.amountMinimum.map { ($0 as NSDecimalNumber).doubleValue } ?? amount
            let maximum = rule.amountMaximum.map { ($0 as NSDecimalNumber).doubleValue } ?? amount
            return partial + ((minimum...maximum).contains(amount) ? 1 : 0)
        } / Double(matches.count)
    }

    func detectionFactors(
        summary: SubscriptionSummary,
        transactions: [NormalizedTransaction]
    ) -> [SubscriptionEvidenceFactor] {
        let count = max(transactions.count, 1)
        let averageAffinity = transactions
            .map(\.merchantSubscriptionAffinity)
            .reduce(0, +) / Double(count)
        let averageClassification = transactions
            .map(\.classificationConfidence)
            .reduce(0, +) / Double(count)
        let amounts = transactions.map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }
        let amountScore: Double
        if let minAmount = amounts.min(), let maxAmount = amounts.max(), maxAmount > 0 {
            amountScore = max(0, 1 - ((maxAmount - minAmount) / maxAmount))
        } else {
            amountScore = 0
        }

        return [
            SubscriptionEvidenceFactor(
                key: "cadence_fit",
                weight: 0.35,
                score: summary.cadence == .unknown ? 0 : min(1, Double(transactions.count) / 4),
                source: "deterministic_detection",
                description: "Transactions fit a \(summary.cadence.rawValue) billing cadence."
            ),
            SubscriptionEvidenceFactor(
                key: "amount_stability",
                weight: 0.2,
                score: amountScore,
                source: "deterministic_detection",
                description: "Charge amounts are stable inside the candidate cluster."
            ),
            SubscriptionEvidenceFactor(
                key: "merchant_identity_match",
                weight: 0.25,
                score: averageClassification,
                source: "merchant_classification",
                description: "Merchant classification supports a stable canonical identity."
            ),
            SubscriptionEvidenceFactor(
                key: "known_subscription_descriptor",
                weight: 0.2,
                score: averageAffinity,
                source: "merchant_classification",
                description: "Merchant and descriptor signals look subscription-like."
            )
        ]
    }

    @discardableResult
    func recordEvidence(
        candidateKey: String,
        subscription: Subscription? = nil,
        decision: SubscriptionEvidenceDecision,
        confidence: Double,
        deterministicScore: Double,
        factors: [SubscriptionEvidenceFactor],
        matchedTransactions: [NormalizedTransaction],
        rejectedTransactions: [NormalizedTransaction],
        rules: [SubscriptionMatchRule],
        llmContribution: SubscriptionEvidenceLLMContribution? = nil,
        reason: String,
        environment: DetectionEnvironment
    ) -> SubscriptionDetectionEvidence {
        let factors = llmContribution.map { factors + [$0.factor] } ?? factors
        let evidence = SubscriptionDetectionEvidence(
            detectionRunID: environment.detectionRun.id,
            subscriptionID: subscription?.id,
            candidateKey: candidateKey,
            decision: decision,
            confidence: min(max(confidence, 0), 1),
            deterministicScore: min(max(deterministicScore, 0), 1),
            llmScore: llmContribution.map { min(max($0.score, 0), 1) },
            evidenceFactorsJSON: SubscriptionEvidenceJSON.encodeFactors(factors),
            matchedTransactionIDsJSON: SubscriptionEvidenceJSON.encodeUUIDs(matchedTransactions.map(\.id)),
            rejectedTransactionIDsJSON: SubscriptionEvidenceJSON.encodeUUIDs(rejectedTransactions.map(\.id)),
            ruleIDsJSON: SubscriptionEvidenceJSON.encodeUUIDs(rules.map(\.id)),
            serviceProfileID: rules.first?.serviceProfileID,
            merchantIdentityID: rules.first?.merchantIdentityID,
            llmProviderRawValue: llmContribution?.providerKind?.rawValue,
            llmPromptVersion: llmContribution?.promptVersion,
            llmInputFingerprint: llmContribution?.inputFingerprint,
            llmOutputJSON: llmContribution?.outputJSON,
            reason: reason
        )
        environment.context.insert(evidence)
        return evidence
    }

    func llmEvidenceContribution(
        for summary: SubscriptionSummary,
        transactions: [NormalizedTransaction],
        userRuleSummary: String?
    ) async -> SubscriptionEvidenceLLMContribution? {
        guard shouldRunSubscriptionEvidenceAI(summary: summary) else {
            return nil
        }

        let input = subscriptionEvidenceInput(
            for: summary,
            transactions: transactions,
            userRuleSummary: userRuleSummary
        )
        guard let result = await intelligence.evaluateSubscriptionEvidence(input) else {
            return nil
        }

        let outputJSON = SubscriptionEvidenceJSON.encode(result)
        let score = result.isSubscription ? result.confidence : (1 - result.confidence)
        return SubscriptionEvidenceLLMContribution(
            providerKind: intelligence.evidenceProviderKind,
            promptVersion: 1,
            inputFingerprint: evidenceFingerprint(for: SubscriptionEvidenceJSON.encode(input)),
            outputJSON: outputJSON,
            score: score,
            factor: SubscriptionEvidenceFactor(
                key: "llm_subscription_judgment",
                weight: 0.18,
                score: score,
                source: "local_ai",
                description: result.reasonSummary
            )
        )
    }

    func shouldRunSubscriptionEvidenceAI(summary: SubscriptionSummary) -> Bool {
        guard automaticRecurringClusterEvaluationEnabled else {
            return false
        }
        return summary.status == .needsReview
    }

    func subscriptionEvidenceInput(
        for summary: SubscriptionSummary,
        transactions: [NormalizedTransaction],
        userRuleSummary: String?
    ) -> SubscriptionEvidenceEvaluationInput {
        let sortedTransactions = transactions.sorted { $0.transactionDate < $1.transactionDate }
        let amounts = sortedTransactions.map { abs(($0.transactionAmount as NSDecimalNumber).doubleValue) }
        let averageAffinity = average(
            sortedTransactions.map {
                max($0.merchantSubscriptionAffinity, $0.merchantKind.defaultSubscriptionAffinity)
            }
        )
        let merchantKind = dominantMerchantKind(in: sortedTransactions)

        return SubscriptionEvidenceEvaluationInput(
            candidateKey: summary.canonicalName,
            canonicalName: summary.canonicalName,
            displayName: summary.displayName,
            rawMerchantVariants: uniqueStrings(sortedTransactions.map(\.merchantRaw), limit: 6),
            memoSamples: uniqueStrings(sortedTransactions.compactMap { $0.memo?.nilIfBlank }, limit: 4),
            categorySamples: uniqueStrings(sortedTransactions.compactMap { $0.category?.nilIfBlank }, limit: 4),
            serviceProfileName: nil,
            merchantKind: merchantKind,
            subscriptionAffinity: averageAffinity,
            scheduleSummary: scheduleSummary(for: summary, transactions: sortedTransactions),
            occurrenceSummary: occurrenceSummary(for: sortedTransactions),
            amountSummary: amountSummary(for: amounts, currency: summary.currency),
            negativeSignals: negativeEvidenceSignals(for: sortedTransactions),
            userRuleSummary: userRuleSummary
        )
    }

    func userRuleSummary(
        rule: SubscriptionReviewRule?,
        correction: MerchantCorrection?
    ) -> String? {
        var parts: [String] = []
        if let rule {
            if rule.isFalsePositive {
                parts.append("User review rule marks this merchant as not a subscription.")
            }
            if rule.isUserConfirmed {
                parts.append("User review rule confirms this merchant as a subscription.")
            }
            if rule.overrideCadence != nil || rule.overridePriceAmount != nil {
                parts.append("User review rule includes cadence or amount overrides.")
            }
        }
        if let correction {
            parts.append(
                correction.isSubscription ?
                    "User correction says this merchant is a subscription." :
                    "User correction says this merchant is not a subscription."
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    func scheduleSummary(
        for summary: SubscriptionSummary,
        transactions: [NormalizedTransaction]
    ) -> String {
        [
            "cadence=\(summary.cadence.rawValue)",
            "count=\(transactions.count)",
            "first=\(transactions.first?.transactionDate.ISO8601Format() ?? "unknown")",
            "last=\(transactions.last?.transactionDate.ISO8601Format() ?? "unknown")"
        ].joined(separator: "; ")
    }

    func occurrenceSummary(for transactions: [NormalizedTransaction]) -> String {
        let linkedCount = transactions.filter { $0.subscriptionID != nil }.count
        return "\(linkedCount) linked of \(transactions.count) matched candidate transactions"
    }

    func amountSummary(for amounts: [Double], currency: String) -> String {
        guard let minimum = amounts.min(), let maximum = amounts.max() else {
            return "No amount evidence"
        }
        let average = average(amounts)
        return String(
            format: "%@ %.2f average, %.2f min, %.2f max",
            currency,
            average,
            minimum,
            maximum
        )
    }

    func negativeEvidenceSignals(for transactions: [NormalizedTransaction]) -> [String] {
        var signals: [String] = []
        if transactions.contains(where: transactionLooksLikeRefund) {
            signals.append("Refund or reversal wording appears in the candidate.")
        }
        if transactions.contains(where: hasCommerceNoiseSignals) {
            signals.append("Commerce order wording appears in the candidate.")
        }
        if transactions.contains(where: isFinancialMovement) {
            signals.append("Financial movement wording appears in the candidate.")
        }
        if transactions.contains(where: isRecurringBillOrNonSubscriptionSpend) {
            signals.append("Recurring bill wording could indicate non-subscription spend.")
        }
        return signals
    }

    func uniqueStrings(_ values: [String], limit: Int) -> [String] {
        Array(
            Set(
                values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { $0.isEmpty == false }
            )
            .sorted()
            .prefix(limit)
        )
    }

    func dominantMerchantKind(in transactions: [NormalizedTransaction]) -> MerchantKind {
        let counts = Dictionary(grouping: transactions.map(\.merchantKind), by: { $0 })
            .mapValues(\.count)
        return counts.max {
            if $0.value == $1.value {
                return $0.key.rawValue < $1.key.rawValue
            }
            return $0.value < $1.value
        }?.key ?? .unknown
    }

    func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else {
            return 0
        }
        return values.reduce(0, +) / Double(values.count)
    }

    func evidenceFingerprint(for json: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in json.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

private extension SubscriptionDetectionService {
    func makeScheduleExpectation(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction],
        context: ModelContext
    ) -> SubscriptionScheduleExpectation {
        let expectation = SubscriptionScheduleExpectation(
            subscriptionID: subscription.id,
            cadence: subscription.cadence,
            interval: interval(for: subscription.cadence),
            anchorPolicy: anchorPolicy(for: subscription, linkedTransactions: linkedTransactions),
            dateToleranceBeforeDays: dateTolerance(for: subscription.cadence),
            dateToleranceAfterDays: dateTolerance(for: subscription.cadence),
            gracePeriodDays: graceWindow(for: subscription.cadence),
            confidence: subscription.confidenceScore,
            source: subscription.isUserConfirmed ? .confirmedSubscription : .detectedCandidate
        )
        context.insert(expectation)
        return expectation
    }

    func updateScheduleExpectation(
        _ expectation: SubscriptionScheduleExpectation,
        subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) {
        expectation.cadence = subscription.cadence
        expectation.interval = interval(for: subscription.cadence)
        expectation.anchorPolicy = anchorPolicy(for: subscription, linkedTransactions: linkedTransactions)
        expectation.anchorDay = anchorDay(for: subscription, linkedTransactions: linkedTransactions)
        expectation.anchorWeekday = anchorWeekday(for: subscription, linkedTransactions: linkedTransactions)
        expectation.dateToleranceBeforeDays = dateTolerance(for: subscription.cadence)
        expectation.dateToleranceAfterDays = dateTolerance(for: subscription.cadence)
        expectation.gracePeriodDays = graceWindow(for: subscription.cadence)
        expectation.confidence = subscription.confidenceScore
        expectation.updatedAt = .now
    }

    func projectedOccurrences(
        for subscription: Subscription,
        expectation: SubscriptionScheduleExpectation,
        linkedTransactions: [NormalizedTransaction],
        detectionRun: DetectionRun,
        in context: ModelContext
    ) -> [SubscriptionOccurrence] {
        let expectedDates = projectedExpectedDates(
            for: subscription,
            expectation: expectation,
            linkedTransactions: linkedTransactions
        )
        var unmatchedTransactions = linkedTransactions
        var occurrences: [SubscriptionOccurrence] = []

        for expectedDate in expectedDates {
            let expectedDay = Calendar.current.startOfDay(for: expectedDate)
            let windowStart = Calendar.current.date(
                byAdding: .day,
                value: -expectation.dateToleranceBeforeDays,
                to: expectedDay
            ) ?? expectedDay
            let windowEnd = Calendar.current.date(
                byAdding: .day,
                value: expectation.dateToleranceAfterDays,
                to: expectedDay
            ) ?? expectedDay
            let matchIndex = unmatchedTransactions.firstIndex { transaction in
                let transactionDay = Calendar.current.startOfDay(for: transaction.transactionDate)
                return (windowStart...windowEnd).contains(transactionDay)
            }
            let matchedTransaction = matchIndex.map { unmatchedTransactions.remove(at: $0) }
            let status = occurrenceStatus(
                expectedDate: expectedDate,
                windowEnd: windowEnd,
                matchedTransaction: matchedTransaction,
                subscription: subscription,
                expectation: expectation
            )
            let evidence = occurrenceEvidence(
                status: status,
                subscription: subscription,
                transaction: matchedTransaction,
                expectedDate: expectedDate,
                detectionRun: detectionRun,
                context: context
            )
            let dateDelta = matchedTransaction.map {
                Calendar.current.dateComponents([.day], from: expectedDate, to: $0.transactionDate).day ?? 0
            }
            let amountDelta = matchedTransaction.flatMap {
                amountDeltaPercent(expected: subscription.priceAmount, actual: abs($0.transactionAmount))
            }
            let occurrence = SubscriptionOccurrence(
                subscriptionID: subscription.id,
                scheduleExpectationID: expectation.id,
                expectedDate: expectedDate,
                windowStartDate: windowStart,
                windowEndDate: windowEnd,
                matchedTransactionID: matchedTransaction?.id,
                status: status,
                observedDate: matchedTransaction?.transactionDate,
                observedAmount: matchedTransaction.map { abs($0.transactionAmount) },
                expectedAmount: subscription.priceAmount,
                dateDeltaDays: dateDelta,
                amountDeltaPercent: amountDelta,
                matchConfidence: matchedTransaction == nil ? 0 : 0.92,
                evidenceID: evidence?.id,
                createdByDetectionRunID: detectionRun.id
            )
            context.insert(occurrence)
            occurrences.append(occurrence)
        }

        return occurrences
    }

    func projectedExpectedDates(
        for subscription: Subscription,
        expectation: SubscriptionScheduleExpectation,
        linkedTransactions: [NormalizedTransaction]
    ) -> [Date] {
        guard expectation.cadence != .unknown else {
            return []
        }

        let calendar = Calendar.current
        let anchorCandidates = [
            linkedTransactions.first?.transactionDate,
            subscription.firstChargeDate,
            subscription.lastChargeDate,
            subscription.predictedNextChargeDate
        ].compactMap { $0 }
        guard var cursor = anchorCandidates.min() else {
            return []
        }

        cursor = calendar.startOfDay(for: cursor)
        let reference = calendar.startOfDay(for: .now)
        let cutoffCandidates = [
            reference,
            subscription.predictedNextChargeDate.map { calendar.startOfDay(for: $0) },
            linkedTransactions.last.map { calendar.startOfDay(for: $0.transactionDate) }
        ].compactMap { $0 }
        let cutoff = cutoffCandidates.max() ?? reference
        var dates: [Date] = []
        var guardCount = 0
        while cursor <= cutoff, guardCount < 180 {
            dates.append(cursor)
            guard let next = advanceExpectedDate(cursor, expectation: expectation, calendar: calendar) else {
                break
            }
            cursor = next
            guardCount += 1
        }
        return Array(Set(dates)).sorted()
    }

    func advanceExpectedDate(
        _ date: Date,
        expectation: SubscriptionScheduleExpectation,
        calendar: Calendar
    ) -> Date? {
        let component: Calendar.Component
        let value: Int
        switch expectation.cadence {
        case .monthly:
            component = .month
            value = expectation.interval
        case .quarterly:
            component = .month
            value = expectation.interval * 3
        case .semiannual:
            component = .month
            value = expectation.interval * 6
        case .annual:
            component = .year
            value = expectation.interval
        case .biweekly:
            component = .day
            value = expectation.interval * 14
        case .weekly:
            component = .day
            value = expectation.interval * 7
        case .unknown:
            return nil
        }

        guard let advanced = calendar.date(byAdding: component, value: value, to: date) else {
            return nil
        }

        switch expectation.anchorPolicy {
        case .endOfMonth:
            return calendar.endOfMonth(for: advanced)
        case .exactDayOfMonth, .sameCalendarDate:
            guard let anchorDay = expectation.anchorDay else {
                return advanced
            }
            return calendar.dateByClamping(day: anchorDay, inMonthOf: advanced)
        case .nthWeekday, .sameWeekday, .rollingInterval, .unknown:
            return advanced
        }
    }

    func occurrenceStatus(
        expectedDate: Date,
        windowEnd: Date,
        matchedTransaction: NormalizedTransaction?,
        subscription: Subscription,
        expectation: SubscriptionScheduleExpectation
    ) -> SubscriptionOccurrenceStatus {
        if let matchedTransaction {
            if let delta = amountDeltaPercent(expected: subscription.priceAmount, actual: abs(matchedTransaction.transactionAmount)),
               abs(delta) > max(0.12, expectation.confidence < 0.7 ? 0.2 : 0.12) {
                return .priceChanged
            }
            return .matched
        }

        let graceEnd = Calendar.current.date(
            byAdding: .day,
            value: expectation.gracePeriodDays,
            to: windowEnd
        ) ?? windowEnd
        return graceEnd < Date.now ? .missed : .pending
    }

    func occurrenceEvidence(
        status: SubscriptionOccurrenceStatus,
        subscription: Subscription,
        transaction: NormalizedTransaction?,
        expectedDate: Date,
        detectionRun: DetectionRun,
        context: ModelContext
    ) -> SubscriptionDetectionEvidence? {
        let decision: SubscriptionEvidenceDecision
        let factorKey: String
        let reason: String
        switch status {
        case .matched:
            decision = .occurrenceMatched
            factorKey = "occurrence_coverage"
            reason = "Expected payment matched an observed transaction."
        case .missed:
            decision = .occurrenceMissed
            factorKey = "missed_occurrence_penalty"
            reason = "No matching transaction appeared inside the expected payment window."
        case .priceChanged:
            decision = .priceChanged
            factorKey = "price_change_signal"
            reason = "A matched occurrence moved outside the learned amount tolerance."
        case .pending, .late, .early, .duplicateInCycle, .manualConfirmed, .manualRejected:
            return nil
        }

        let evidence = SubscriptionDetectionEvidence(
            detectionRunID: detectionRun.id,
            subscriptionID: subscription.id,
            candidateKey: "\(subscription.canonicalName):\(expectedDate.ISO8601Format())",
            decision: decision,
            confidence: transaction == nil ? 0.45 : 0.92,
            deterministicScore: transaction == nil ? 0.45 : 0.92,
            evidenceFactorsJSON: SubscriptionEvidenceJSON.encodeFactors([
                SubscriptionEvidenceFactor(
                    key: factorKey,
                    weight: 1,
                    score: transaction == nil ? 0.45 : 0.92,
                    source: "occurrence_reconciliation",
                    description: reason
                )
            ]),
            matchedTransactionIDsJSON: SubscriptionEvidenceJSON.encodeUUIDs(transaction.map { [$0.id] } ?? []),
            reason: reason
        )
        context.insert(evidence)
        return evidence
    }

    func interval(for cadence: SubscriptionCadence) -> Int {
        1
    }

    func dateTolerance(for cadence: SubscriptionCadence) -> Int {
        switch cadence {
        case .annual:
            return 14
        case .quarterly, .semiannual:
            return 7
        case .monthly:
            return 3
        case .biweekly:
            return 2
        case .weekly:
            return 1
        case .unknown:
            return 0
        }
    }

    func anchorPolicy(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> SubscriptionAnchorPolicy {
        switch subscription.cadence {
        case .monthly, .quarterly, .semiannual:
            if linkedTransactions.count >= 2,
               linkedTransactions.allSatisfy({ Calendar.current.isEndOfMonth($0.transactionDate) }) {
                return .endOfMonth
            }
            return .exactDayOfMonth
        case .annual:
            return .sameCalendarDate
        case .weekly, .biweekly:
            return .rollingInterval
        case .unknown:
            return .unknown
        }
    }

    func anchorDay(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> Int? {
        let date = linkedTransactions.last?.transactionDate ?? subscription.lastChargeDate
        return date.map { Calendar.current.component(.day, from: $0) }
    }

    func anchorWeekday(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction]
    ) -> Int? {
        let date = linkedTransactions.last?.transactionDate ?? subscription.lastChargeDate
        return date.map { Calendar.current.component(.weekday, from: $0) }
    }

    func occurrenceAmountMatches(
        transaction: NormalizedTransaction,
        subscription: Subscription
    ) -> Bool {
        let expected = abs((subscription.priceAmount as NSDecimalNumber).doubleValue)
        guard expected > 0 else {
            return true
        }
        let actual = abs((transaction.transactionAmount as NSDecimalNumber).doubleValue)
        return abs(actual - expected) <= max(2.5, expected * 0.2)
    }

    func amountDeltaPercent(expected: Decimal, actual: Decimal) -> Double? {
        let expectedDouble = abs((expected as NSDecimalNumber).doubleValue)
        guard expectedDouble > 0 else {
            return nil
        }
        let actualDouble = abs((actual as NSDecimalNumber).doubleValue)
        return (actualDouble - expectedDouble) / expectedDouble
    }
}

private extension Calendar {
    func isEndOfMonth(_ date: Date) -> Bool {
        component(.day, from: date) == range(of: .day, in: .month, for: date)?.upperBound.advanced(by: -1)
    }

    func endOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        guard let monthStart = self.date(from: components),
              let nextMonth = self.date(byAdding: .month, value: 1, to: monthStart),
              let end = self.date(byAdding: .day, value: -1, to: nextMonth) else {
            return date
        }
        return startOfDay(for: end)
    }

    func dateByClamping(day: Int, inMonthOf date: Date) -> Date {
        var components = dateComponents([.year, .month], from: date)
        let maximumDay = range(of: .day, in: .month, for: date)?.upperBound.advanced(by: -1) ?? day
        components.day = min(day, maximumDay)
        return self.date(from: components).map(startOfDay) ?? date
    }
}

private extension String {
    var evidenceSearchToken: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
