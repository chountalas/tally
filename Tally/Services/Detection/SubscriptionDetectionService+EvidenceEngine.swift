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
        _ rules: [SubscriptionMatchRule],
        to debitTransactions: [NormalizedTransaction],
        environment: DetectionEnvironment,
        state: DetectionAccumulator
    ) async {
        let orderedRules = rules.sorted {
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
                displayName: subscription.displayName,
                status: .detected,
                source: .primary,
                hadRecurringSignals: true,
                reason: "Linked by a saved match rule before candidate discovery.",
                importRecordIDs: Set(matches.compactMap(\.importRecordID)),
                subscriptionID: subscription.id
            )
        )
    }

    func refreshSubscriptionFromRuleMatches(
        _ subscription: Subscription,
        matches: [NormalizedTransaction],
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
        subscription.normalizedMonthlyAmount = cadence.normalizedMonthlyAmount(for: subscription.priceAmount)
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
            normalizedMonthlyAmount: cadence.normalizedMonthlyAmount(for: amount),
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
        if rule.createdFrom == .hiddenSuggestion {
            guard rule.hiddenImportScope.contains(transaction.importRecordID) else {
                return false
            }
        }

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
        // Only an exact service identity can follow a price change outside the saved band.
        // A broader merchant/token match still needs the band to distinguish parallel plans.
        let canBypassAmountBand = rule.subscriptionID != nil && rule.isNegativeRule == false &&
            transaction.merchantNormalized.caseInsensitiveCompare(rule.canonicalName) == .orderedSame

        let text = [
            transaction.merchantRaw,
            transaction.merchantNormalized,
            transaction.memo ?? "",
            transaction.category ?? ""
        ]
            .joined(separator: " ")
            .lowercased()
        guard let allowedRawMerchants = SubscriptionEvidenceJSON.decodeStrings(rule.allowedRawMerchantsJSON),
              let requiredTokens = SubscriptionEvidenceJSON.decodeStrings(rule.requiredTokensJSON),
              let excludedTokens = SubscriptionEvidenceJSON.decodeStrings(rule.excludedTokensJSON) else {
            return false
        }

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
        guard intelligence.usage != .backgroundAutomation else {
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

private extension String {
    var evidenceSearchToken: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
