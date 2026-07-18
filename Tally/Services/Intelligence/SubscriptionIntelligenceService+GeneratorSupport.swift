import Foundation

private struct CachedIntelligenceResult<Value: Sendable>: Sendable {
    let value: Value
    let expiresAt: Date

    var isExpired: Bool {
        expiresAt <= .now
    }
}

private actor SubscriptionIntelligenceResultCache {
    static let shared = SubscriptionIntelligenceResultCache()

    private let ttl: TimeInterval = 60 * 60 * 24
    private let cacheVersion = "2026-04-14"
    private var merchantClassifications: [String: CachedIntelligenceResult<MerchantClassificationResult>] = [:]
    private var recurringClusterEvaluations: [String: CachedIntelligenceResult<RecurringClusterEvaluationResult>] = [:]
    private var singleChargeEvaluations: [String: CachedIntelligenceResult<SingleChargeEvaluationResult>] = [:]
    private var subscriptionEvidenceEvaluations: [String: CachedIntelligenceResult<SubscriptionEvidenceEvaluationResult>] = [:]

    nonisolated var version: String { cacheVersion }

    func merchantClassification(for key: String) -> MerchantClassificationResult? {
        value(for: key, in: &merchantClassifications)
    }

    func storeMerchantClassification(_ value: MerchantClassificationResult, for key: String) {
        merchantClassifications[key] = entry(for: value)
    }

    func recurringClusterEvaluation(for key: String) -> RecurringClusterEvaluationResult? {
        value(for: key, in: &recurringClusterEvaluations)
    }

    func storeRecurringClusterEvaluation(_ value: RecurringClusterEvaluationResult, for key: String) {
        recurringClusterEvaluations[key] = entry(for: value)
    }

    func singleChargeEvaluation(for key: String) -> SingleChargeEvaluationResult? {
        value(for: key, in: &singleChargeEvaluations)
    }

    func storeSingleChargeEvaluation(_ value: SingleChargeEvaluationResult, for key: String) {
        singleChargeEvaluations[key] = entry(for: value)
    }

    func subscriptionEvidenceEvaluation(for key: String) -> SubscriptionEvidenceEvaluationResult? {
        value(for: key, in: &subscriptionEvidenceEvaluations)
    }

    func storeSubscriptionEvidenceEvaluation(
        _ value: SubscriptionEvidenceEvaluationResult,
        for key: String
    ) {
        subscriptionEvidenceEvaluations[key] = entry(for: value)
    }

    func invalidateAll() {
        merchantClassifications.removeAll()
        recurringClusterEvaluations.removeAll()
        singleChargeEvaluations.removeAll()
        subscriptionEvidenceEvaluations.removeAll()
    }

    private func entry<Value: Sendable>(for value: Value) -> CachedIntelligenceResult<Value> {
        CachedIntelligenceResult(value: value, expiresAt: Date().addingTimeInterval(ttl))
    }

    private func value<Value: Sendable>(
        for key: String,
        in storage: inout [String: CachedIntelligenceResult<Value>]
    ) -> Value? {
        guard let cached = storage[key] else {
            return nil
        }
        guard cached.isExpired == false else {
            storage.removeValue(forKey: key)
            return nil
        }
        return cached.value
    }
}

extension SubscriptionIntelligenceService {
    static func invalidateCachedEvaluations() async {
        await SubscriptionIntelligenceResultCache.shared.invalidateAll()
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult? {
        guard let generator else {
            return nil
        }

        let cacheKey = merchantClassificationCacheKey(
            rawMerchant: rawMerchant,
            memo: memo,
            category: category,
            amount: amount
        )
        if let cached = await SubscriptionIntelligenceResultCache.shared.merchantClassification(for: cacheKey) {
            return cached
        }

        do {
            let result = try await generator.classifyMerchant(
                rawMerchant: rawMerchant,
                memo: memo,
                category: category,
                amount: amount
            )
            guard let sanitized = sanitizedClassificationResult(result) else {
                return nil
            }
            await SubscriptionIntelligenceResultCache.shared.storeMerchantClassification(
                sanitized,
                for: cacheKey
            )
            return sanitized
        } catch {
            guard (error is CancellationError) == false, Task.isCancelled == false else {
                throw error
            }
            return nil
        }
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult]? {
        guard let generator, requests.isEmpty == false else {
            return nil
        }

        var resolved: [String: MerchantClassificationResult] = [:]
        var uncached: [MerchantClassificationRequest] = []

        for request in requests {
            let cacheKey = merchantClassificationCacheKey(
                rawMerchant: request.rawMerchant,
                memo: request.memo,
                category: request.category,
                amount: request.amount
            )
            if let cached = await SubscriptionIntelligenceResultCache.shared.merchantClassification(for: cacheKey) {
                resolved[request.rawMerchant] = cached
            } else {
                uncached.append(request)
            }
        }

        if uncached.isEmpty {
            return resolved
        }

        do {
            let results = try await generator.classifyMerchantsBatch(uncached)
            let sanitized = results.compactMapValues(sanitizedClassificationResult)
            guard sanitized.isEmpty == false else {
                return resolved.isEmpty ? nil : resolved
            }

            for request in uncached {
                guard let value = sanitized[request.rawMerchant] else {
                    continue
                }
                let cacheKey = merchantClassificationCacheKey(
                    rawMerchant: request.rawMerchant,
                    memo: request.memo,
                    category: request.category,
                    amount: request.amount
                )
                await SubscriptionIntelligenceResultCache.shared.storeMerchantClassification(
                    value,
                    for: cacheKey
                )
                resolved[request.rawMerchant] = value
            }

            return resolved.isEmpty ? nil : resolved
        } catch {
            guard (error is CancellationError) == false, Task.isCancelled == false else {
                throw error
            }
            return resolved.isEmpty ? nil : resolved
        }
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async -> RecurringClusterEvaluationResult? {
        guard let generator else {
            return nil
        }

        let cacheKey = recurringClusterCacheKey(input)
        if let cached = await SubscriptionIntelligenceResultCache.shared.recurringClusterEvaluation(for: cacheKey) {
            return cached
        }

        do {
            let result = try await generator.evaluateRecurringCluster(input)
            let sanitized = sanitizeRecurringClusterResult(result)
            await SubscriptionIntelligenceResultCache.shared.storeRecurringClusterEvaluation(
                sanitized,
                for: cacheKey
            )
            return sanitized
        } catch {
            return nil
        }
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async -> SingleChargeEvaluationResult? {
        guard let generator else {
            return nil
        }

        let cacheKey = singleChargeCacheKey(input)
        if let cached = await SubscriptionIntelligenceResultCache.shared.singleChargeEvaluation(for: cacheKey) {
            return cached
        }

        do {
            let result = try await generator.evaluateSingleCharge(input)
            let sanitized = sanitizeSingleChargeResult(result)
            await SubscriptionIntelligenceResultCache.shared.storeSingleChargeEvaluation(
                sanitized,
                for: cacheKey
            )
            return sanitized
        } catch {
            return nil
        }
    }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async -> SubscriptionEvidenceEvaluationResult? {
        guard let generator else {
            return nil
        }

        let cacheKey = subscriptionEvidenceCacheKey(input)
        if let cached = await SubscriptionIntelligenceResultCache.shared.subscriptionEvidenceEvaluation(for: cacheKey) {
            return cached
        }

        do {
            let result = try await generator.evaluateSubscriptionEvidence(input)
            let sanitized = sanitizeSubscriptionEvidenceResult(result)
            await SubscriptionIntelligenceResultCache.shared.storeSubscriptionEvidenceEvaluation(
                sanitized,
                for: cacheKey
            )
            return sanitized
        } catch {
            return nil
        }
    }

    static func makeDefaultGenerator(
        usage: SubscriptionIntelligenceUsage = .interactive,
        preferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager()
    ) -> (any SubscriptionIntelligenceGenerating)? {
        return AIProviderRegistry.defaultGenerator(
            preferences: preferences,
            gemmaModelManager: gemmaModelManager,
            allowsModelAdoption: usage != .backgroundAutomation
        )
    }

    private func merchantClassificationCacheKey(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) -> String {
        [
            SubscriptionIntelligenceResultCache.shared.version,
            rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            memo?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            category?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "",
            amount.description
        ].joined(separator: "|")
    }

    private func recurringClusterCacheKey(_ input: RecurringClusterEvaluationInput) -> String {
        [
            SubscriptionIntelligenceResultCache.shared.version,
            input.canonicalName.lowercased(),
            input.displayName.lowercased(),
            input.rawMerchantVariants.joined(separator: ",").lowercased(),
            input.sampleMemos.joined(separator: "|").lowercased(),
            input.sampleCategories.joined(separator: "|").lowercased(),
            String(input.chargeCount),
            input.intervals.map(String.init).joined(separator: ","),
            input.firstChargeDate?.ISO8601Format() ?? "",
            input.lastChargeDate?.ISO8601Format() ?? "",
            String(format: "%.4f", input.amountMinimum),
            String(format: "%.4f", input.amountMaximum),
            String(format: "%.4f", input.amountVariation),
            input.detectedCadence.rawValue,
            input.merchantKind.rawValue,
            String(format: "%.4f", input.subscriptionAffinity),
            String(format: "%.4f", input.classificationConfidence),
            String(format: "%.4f", input.intervalConsistency),
            String(format: "%.4f", input.amountStability),
            String(format: "%.4f", input.keywordSupport),
            String(format: "%.4f", input.descriptorStrength),
            String(format: "%.4f", input.negativePenalty)
        ].joined(separator: "|")
    }

    private func singleChargeCacheKey(_ input: SingleChargeEvaluationInput) -> String {
        [
            SubscriptionIntelligenceResultCache.shared.version,
            input.canonicalName.lowercased(),
            input.displayName.lowercased(),
            input.rawMerchant.lowercased(),
            input.memo?.lowercased() ?? "",
            input.category?.lowercased() ?? "",
            input.amount.description,
            input.transactionDate.ISO8601Format(),
            input.merchantKind.rawValue,
            String(format: "%.4f", input.subscriptionAffinity),
            String(format: "%.4f", input.classificationConfidence),
            input.suggestedCadence.rawValue
        ].joined(separator: "|")
    }

    private func subscriptionEvidenceCacheKey(_ input: SubscriptionEvidenceEvaluationInput) -> String {
        [
            SubscriptionIntelligenceResultCache.shared.version,
            input.candidateKey.lowercased(),
            input.canonicalName.lowercased(),
            input.displayName.lowercased(),
            input.rawMerchantVariants.joined(separator: ",").lowercased(),
            input.memoSamples.joined(separator: "|").lowercased(),
            input.categorySamples.joined(separator: "|").lowercased(),
            input.serviceProfileName?.lowercased() ?? "",
            input.merchantKind.rawValue,
            String(format: "%.4f", input.subscriptionAffinity),
            input.scheduleSummary.lowercased(),
            input.occurrenceSummary.lowercased(),
            input.amountSummary.lowercased(),
            input.negativeSignals.joined(separator: "|").lowercased(),
            input.userRuleSummary?.lowercased() ?? ""
        ].joined(separator: "|")
    }
}

extension SubscriptionIntelligenceService {
    func sanitizeRecurringClusterResult(
        _ result: RecurringClusterEvaluationResult
    ) -> RecurringClusterEvaluationResult {
        RecurringClusterEvaluationResult(
            isSubscription: result.isSubscription,
            confidence: min(max(result.confidence, 0), 1),
            reasonSummary: result.reasonSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            negativeSignals: result.negativeSignals
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
    }

    func sanitizeSingleChargeResult(
        _ result: SingleChargeEvaluationResult
    ) -> SingleChargeEvaluationResult {
        SingleChargeEvaluationResult(
            isLikelySubscription: result.isLikelySubscription,
            confidence: min(max(result.confidence, 0), 1),
            reasonSummary: result.reasonSummary.trimmingCharacters(in: .whitespacesAndNewlines),
            negativeSignals: result.negativeSignals
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
    }

    func sanitizeSubscriptionEvidenceResult(
        _ result: SubscriptionEvidenceEvaluationResult
    ) -> SubscriptionEvidenceEvaluationResult {
        SubscriptionEvidenceEvaluationResult(
            isSubscription: result.isSubscription,
            confidence: min(max(result.confidence, 0), 1),
            likelyServiceName: result.likelyServiceName?.nilIfBlank,
            likelyPlanDescriptor: result.likelyPlanDescriptor?.nilIfBlank,
            positiveSignals: result.positiveSignals
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false },
            negativeSignals: result.negativeSignals
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false },
            reasonSummary: result.reasonSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    func sanitizedClassificationResult(
        _ result: MerchantClassificationResult
    ) -> MerchantClassificationResult? {
        let canonicalName = result.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let serviceCategory = result.serviceCategory.trimmingCharacters(in: .whitespacesAndNewlines)

        guard canonicalName.isEmpty == false, serviceCategory.isEmpty == false else {
            return nil
        }
        guard AIServiceCategoryValidator.isValid(serviceCategory) else {
            return nil
        }

        let compactCategory = serviceCategory
            .replacingOccurrences(of: #"[^A-Za-z&/\-\s]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard compactCategory.isEmpty == false else {
            return nil
        }

        return MerchantClassificationResult(
            canonicalName: canonicalName,
            serviceCategory: compactCategory,
            merchantKind: result.merchantKind,
            subscriptionAffinity: min(max(result.subscriptionAffinity, 0), 1),
            confidence: min(max(result.confidence, 0), 1)
        )
    }

    func factsString(for response: IntelligenceResponse) -> String {
        let evidence = response.evidence
            .map { "- \($0.label): \($0.snippet)" }
            .joined(separator: "\n")
        let actions = response.actions.map(\.title).joined(separator: ", ")

        return """
        Headline: \(response.headline)
        Summary: \(response.summary)
        Evidence:
        \(evidence)
        Actions: \(actions)
        Confidence: \(response.confidence)
        """
    }

    func merge(copy: IntelligenceCopyPayload, onto draft: IntelligenceResponse) -> IntelligenceResponse? {
        let headline = copy.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = copy.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let followUps = copy.followUps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }

        guard headline.isEmpty == false, summary.isEmpty == false else {
            return nil
        }

        return IntelligenceResponse(
            headline: headline,
            summary: summary,
            evidence: draft.evidence,
            actions: draft.actions,
            followUps: followUps.isEmpty ? draft.followUps : Array(followUps.prefix(4)),
            confidence: draft.confidence
        )
    }
}
