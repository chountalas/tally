import Foundation
import OSLog

private let gemmaInferenceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Tally",
    category: "GemmaInference"
)

protocol GemmaTextGeneratingRuntime: Sendable {
    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String
}

private struct GemmaRuntimeAdapter: GemmaTextGeneratingRuntime {
    let runtime: GemmaRuntime

    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        try await runtime.generateText(
            modelURL: modelURL,
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: maxTokens,
            temperature: temperature
        )
    }
}

private struct GemmaCopyEnvelope: Decodable {
    let headline: String
    let summary: String
    let followUps: [String]
}

private struct GemmaRecurringClusterEnvelope: Decodable {
    let isSubscription: Bool
    let confidence: Double
    let reasonSummary: String
    let negativeSignals: [String]
}

private struct GemmaSingleChargeEnvelope: Decodable {
    let isLikelySubscription: Bool
    let confidence: Double
    let reasonSummary: String
    let negativeSignals: [String]
}

private struct GemmaSubscriptionEvidenceEnvelope: Decodable {
    let isSubscription: Bool
    let confidence: Double
    let likelyServiceName: String?
    let likelyPlanDescriptor: String?
    let positiveSignals: [String]
    let negativeSignals: [String]
    let reasonSummary: String
}

private struct GemmaBatchClassificationItem: Codable {
    let rawMerchant: String
    let canonicalName: String
    let serviceCategory: String
    let merchantKind: MerchantKind
    let subscriptionAffinity: Double
    let confidence: Double
}

private struct GemmaBatchClassificationEnvelope: Decodable {
    let classifications: [GemmaBatchClassificationItem]
}

struct GemmaLocalIntelligenceGenerator: SubscriptionIntelligenceGenerating {
    let modelURL: URL
    private let runtime: any GemmaTextGeneratingRuntime
    private let maxBatchClassificationRequests = 3

    var evidenceProviderKind: AIProviderKind? { .gemmaLocal }

    init(
        modelURL: URL,
        runtime: any GemmaTextGeneratingRuntime = GemmaRuntimeAdapter(runtime: .shared)
    ) {
        self.modelURL = modelURL
        self.runtime = runtime
    }

    func generateCopy(
        route: SubscriptionIntelligenceRoute,
        query: IntelligenceQuery,
        facts: String,
        draft: IntelligenceResponse
    ) async throws -> IntelligenceCopyPayload {
        let envelope: GemmaCopyEnvelope = try await decodeJSON(
            type: GemmaCopyEnvelope.self,
            systemPrompt: """
            You are Gemma 4 running locally inside Tally, a privacy-first subscription tracker.
            Return strict JSON only.
            Keep the meaning grounded in the supplied facts and do not invent evidence.
            followUps must contain 1 to 3 concise prompts.
            """,
            userPrompt: """
            Route: \(route.rawValue)
            User query: \(query.prompt)
            Existing draft headline: \(draft.headline)
            Existing draft summary: \(draft.summary)
            Facts:
            \(facts)

            Return JSON:
            {
              "headline": "string",
              "summary": "string",
              "followUps": ["string"]
            }
            """
        )

        return IntelligenceCopyPayload(
            headline: envelope.headline,
            summary: envelope.summary,
            followUps: envelope.followUps
        )
    }

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult {
        try await decodeJSON(
            type: MerchantClassificationResult.self,
            systemPrompt: merchantClassificationSystemPrompt,
            userPrompt: """
            Merchant: \(rawMerchant)
            Memo: \(memo ?? "None")
            Category: \(category ?? "None")
            Amount: \(amount)

            Valid merchantKind values: \(MerchantKind.allCases.map(\.rawValue).joined(separator: ", "))
            Return strict JSON only using exactly this schema:
            {
              "canonicalName": "string",
              "serviceCategory": "string",
              "merchantKind": "string",
              "subscriptionAffinity": 0.0,
              "confidence": 0.0
            }

            Requirements:
            - canonicalName must be a stable consumer-facing brand name.
            - serviceCategory must be a short label like Streaming, Software, Membership, Utilities, Retail, Dining, Groceries, Travel, Health, Marketplace, or Uncategorized.
            - merchantKind must be one of the allowed values above.
            - subscriptionAffinity and confidence must be numbers between 0 and 1.
            - Do not include any extra keys.
            """
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        try await classifyMerchantsBatchChunked(requests)
    }

    private func classifyMerchantsBatchChunked(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        guard requests.isEmpty == false else {
            return [:]
        }

        if requests.count > maxBatchClassificationRequests {
            gemmaInferenceLogger.notice(
                "Gemma batch classification split requests=\(requests.count, privacy: .public) chunk_size=\(maxBatchClassificationRequests, privacy: .public)"
            )
            return try await classifyMerchantsByChunks(
                requests,
                chunkSize: maxBatchClassificationRequests
            )
        }

        do {
            try Task.checkCancellation()
            let results = try await classifyMerchantsBatchChunk(requests)
            try Task.checkCancellation()
            return results
        } catch {
            guard (error is CancellationError) == false, Task.isCancelled == false else {
                throw error
            }
            guard requests.count > 1, shouldSplitBatch(after: error) else {
                throw error
            }

            let reducedChunkSize = max(1, requests.count / 2)
            gemmaInferenceLogger.notice(
                "Gemma batch classification retrying with smaller chunks requests=\(requests.count, privacy: .public) chunk_size=\(reducedChunkSize, privacy: .public)"
            )
            return try await classifyMerchantsByChunks(
                requests,
                chunkSize: reducedChunkSize
            )
        }
    }

    private func classifyMerchantsByChunks(
        _ requests: [MerchantClassificationRequest],
        chunkSize: Int
    ) async throws -> [String: MerchantClassificationResult] {
        try Task.checkCancellation()
        var mergedResults: [String: MerchantClassificationResult] = [:]

        for chunkStart in stride(from: 0, to: requests.count, by: chunkSize) {
            try Task.checkCancellation()
            let chunkEnd = min(chunkStart + chunkSize, requests.count)
            let chunk = Array(requests[chunkStart..<chunkEnd])
            let chunkResults = try await classifyMerchantsBatchChunked(chunk)
            mergedResults.merge(chunkResults) { _, replacement in replacement }
        }

        return mergedResults
    }

    private func classifyMerchantsBatchChunk(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult] {
        let requestsPayload = requests.map { request in
            """
            {
              "rawMerchant": \(jsonString(request.rawMerchant)),
              "memo": \(jsonString(request.memo ?? "None")),
              "category": \(jsonString(request.category ?? "None")),
              "amount": \(jsonString(request.amount.description))
            }
            """
        }.joined(separator: ",\n")

        let envelope: GemmaBatchClassificationEnvelope = try await decodeJSON(
            type: GemmaBatchClassificationEnvelope.self,
            systemPrompt: merchantClassificationSystemPrompt,
            userPrompt: """
            Classify every merchant below and return strict JSON only.
            Valid merchantKind values: \(MerchantKind.allCases.map(\.rawValue).joined(separator: ", "))

            Return:
            {
              "classifications": [
                {
                  "rawMerchant": "string",
                  "canonicalName": "string",
                  "serviceCategory": "string",
                  "merchantKind": "string",
                  "subscriptionAffinity": 0.0,
                  "confidence": 0.0
                }
              ]
            }

            Requests:
            [
            \(requestsPayload)
            ]
            """
        )

        var requestsByMerchant: [String: MerchantClassificationRequest] = [:]
        for request in requests {
            requestsByMerchant[request.rawMerchant] = request
        }
        var results: [String: MerchantClassificationResult] = [:]
        var duplicateCount = 0
        var replacedDuplicateCount = 0

        for item in envelope.classifications {
            let rawMerchant = item.rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let request = requestsByMerchant[rawMerchant] else {
                continue
            }

            let candidate = normalizedBatchResult(from: item, fallbackRequest: request)
            if let existing = results[rawMerchant] {
                duplicateCount += 1
                if shouldReplaceBatchResult(existing: existing, candidate: candidate) {
                    results[rawMerchant] = candidate
                    replacedDuplicateCount += 1
                }
            } else {
                results[rawMerchant] = candidate
            }
        }

        var fallbackCount = 0
        for request in requests where results[request.rawMerchant] == nil {
            results[request.rawMerchant] = degradedBatchFallback(for: request)
            fallbackCount += 1
        }

        gemmaInferenceLogger.notice(
            "Gemma batch classification completed requests=\(requests.count, privacy: .public) results=\(results.count, privacy: .public) duplicates=\(duplicateCount, privacy: .public) replaced_duplicates=\(replacedDuplicateCount, privacy: .public) fallbacks=\(fallbackCount, privacy: .public)"
        )

        return results
    }

    private func shouldSplitBatch(after error: Error) -> Bool {
        if let runtimeError = error as? GemmaRuntimeError {
            switch runtimeError {
            case .promptExceedsContextWindow, .tokenizationFailed, .decodeFailed:
                return true
            case .frameworkUnavailable, .modelLoadFailed, .contextCreationFailed,
                 .samplerCreationFailed, .promptFormattingFailed:
                // Environment failures won't be fixed by a smaller batch.
                return false
            }
        }

        // Malformed JSON on a multi-request prompt usually means the model
        // conflated entries; smaller batches recover those.
        return error is DecodingError
    }

    func evaluateRecurringCluster(
        _ input: RecurringClusterEvaluationInput
    ) async throws -> RecurringClusterEvaluationResult {
        let envelope: GemmaRecurringClusterEnvelope = try await decodeJSON(
            type: GemmaRecurringClusterEnvelope.self,
            systemPrompt: """
            You are Gemma 4 running locally inside Tally, a privacy-first subscription tracker.
            Evaluate whether a recurring cluster looks like a real subscription.
            Look at the full cluster evidence, not just a single transaction.
            Repeated grocery trips, marketplace orders, restaurants, salons, pharmacies, and ad hoc retail
            spending are usually not subscriptions unless there is explicit membership, plan, autopay, or
            subscription wording.
            IMPORTANT EDGE CASES:
            - Gym memberships, recurring therapy memberships, and wellness subscriptions with "membership",
              "monthly", or "plan" wording ARE subscriptions even though the merchant is medical or wellness.
            - Monthly or annual charges to membership retailers like Costco, Sam's Club, and Walmart+ with
              membership wording are subscriptions.
            - SaaS charges via payment processors like Stripe, Paddle, Gumroad, and Shopify are very likely subscriptions.
            Use merchant identity, charge cadence, amount shape, timing span, and noisy one-off signals together.
            Base the decision on the evidence. High-confidence signals should produce a strong answer.
            Do not hedge when the evidence is clear in either direction.
            Return strict JSON only and stay grounded in the evidence.
            """,
            userPrompt: """
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant variants: \(input.rawMerchantVariants.joined(separator: ", "))
            Sample memos: \(input.sampleMemos.joined(separator: " | "))
            Sample categories: \(input.sampleCategories.joined(separator: " | "))
            Charge count: \(input.chargeCount)
            Intervals: \(input.intervals.map(String.init).joined(separator: ", "))
            First charge date: \(input.firstChargeDate?.ISO8601Format() ?? "None")
            Last charge date: \(input.lastChargeDate?.ISO8601Format() ?? "None")
            Amount minimum: \(input.amountMinimum)
            Amount maximum: \(input.amountMaximum)
            Amount variation: \(input.amountVariation)
            Detected cadence: \(input.detectedCadence.rawValue)
            Merchant kind: \(input.merchantKind.rawValue)
            Subscription affinity: \(input.subscriptionAffinity)
            Classification confidence: \(input.classificationConfidence)
            Interval consistency: \(input.intervalConsistency)
            Amount stability: \(input.amountStability)
            Keyword support: \(input.keywordSupport)
            Descriptor strength: \(input.descriptorStrength)
            Negative penalty: \(input.negativePenalty)

            Return JSON:
            {
              "isSubscription": true,
              "confidence": 0.0,
              "reasonSummary": "string",
              "negativeSignals": ["string"]
            }
            """
        )

        return RecurringClusterEvaluationResult(
            isSubscription: envelope.isSubscription,
            confidence: envelope.confidence,
            reasonSummary: envelope.reasonSummary,
            negativeSignals: envelope.negativeSignals
        )
    }

    func evaluateSingleCharge(
        _ input: SingleChargeEvaluationInput
    ) async throws -> SingleChargeEvaluationResult {
        let envelope: GemmaSingleChargeEnvelope = try await decodeJSON(
            type: GemmaSingleChargeEnvelope.self,
            systemPrompt: """
            You are Gemma 4 running locally inside Tally, a privacy-first subscription tracker.
            Evaluate whether a single charge is likely part of a subscription.
            Distinguish new subscriptions and trial conversions from one-time purchases.
            Be conservative. Grocery trips, marketplace orders, restaurants, salons, pharmacies, travel,
            and ad hoc shopping are usually not subscriptions unless there is explicit membership, plan,
            annual, monthly, renewal, or subscription wording.
            IMPORTANT EDGE CASES:
            - Gym memberships and recurring wellness subscriptions with "membership" or "monthly" wording
              ARE subscriptions.
            - SaaS charges via payment processors like Stripe, Paddle, Gumroad, and Shopify are very likely subscriptions.
            Base your decision on the evidence. SaaS, streaming, membership, and utility merchants with
            explicit plan language warrant high confidence. Ambiguous merchants warrant lower confidence.
            Do not hedge when the evidence is clear in either direction.
            Return strict JSON only and avoid speculation.
            """,
            userPrompt: """
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant: \(input.rawMerchant)
            Memo: \(input.memo ?? "None")
            Category: \(input.category ?? "None")
            Amount: \(input.amount)
            Transaction date: \(input.transactionDate.formatted(date: .abbreviated, time: .omitted))
            Merchant kind: \(input.merchantKind.rawValue)
            Subscription affinity: \(input.subscriptionAffinity)
            Classification confidence: \(input.classificationConfidence)
            Suggested cadence: \(input.suggestedCadence.rawValue)

            Return JSON:
            {
              "isLikelySubscription": true,
              "confidence": 0.0,
              "reasonSummary": "string",
              "negativeSignals": ["string"]
            }
            """
        )

        return SingleChargeEvaluationResult(
            isLikelySubscription: envelope.isLikelySubscription,
            confidence: envelope.confidence,
            reasonSummary: envelope.reasonSummary,
            negativeSignals: envelope.negativeSignals
        )
    }

    func evaluateSubscriptionEvidence(
        _ input: SubscriptionEvidenceEvaluationInput
    ) async throws -> SubscriptionEvidenceEvaluationResult {
        let envelope: GemmaSubscriptionEvidenceEnvelope = try await decodeJSON(
            type: GemmaSubscriptionEvidenceEnvelope.self,
            systemPrompt: """
            You are Gemma 4 running locally inside Tally, a privacy-first subscription tracker.
            Evaluate structured subscription evidence. You are not the source of truth.
            Tally will combine your JSON evidence with deterministic rules, merchant identity,
            expected occurrences, and transaction history.
            Look for contradictions, processor ambiguity, service identity clues, trial-to-paid patterns,
            and false-positive categories. Return strict JSON only.
            """,
            userPrompt: """
            Candidate key: \(input.candidateKey)
            Canonical merchant: \(input.canonicalName)
            Display name: \(input.displayName)
            Raw merchant variants: \(input.rawMerchantVariants.joined(separator: ", "))
            Memo samples: \(input.memoSamples.joined(separator: " | "))
            Category samples: \(input.categorySamples.joined(separator: " | "))
            Service profile: \(input.serviceProfileName ?? "None")
            Merchant kind: \(input.merchantKind.rawValue)
            Subscription affinity: \(input.subscriptionAffinity)
            Schedule summary: \(input.scheduleSummary)
            Occurrence summary: \(input.occurrenceSummary)
            Amount summary: \(input.amountSummary)
            Negative signals: \(input.negativeSignals.joined(separator: " | "))
            User rule summary: \(input.userRuleSummary ?? "None")

            Return JSON:
            {
              "isSubscription": true,
              "confidence": 0.0,
              "likelyServiceName": "string or null",
              "likelyPlanDescriptor": "string or null",
              "positiveSignals": ["string"],
              "negativeSignals": ["string"],
              "reasonSummary": "string"
            }
            """
        )

        return SubscriptionEvidenceEvaluationResult(
            isSubscription: envelope.isSubscription,
            confidence: envelope.confidence,
            likelyServiceName: envelope.likelyServiceName,
            likelyPlanDescriptor: envelope.likelyPlanDescriptor,
            positiveSignals: envelope.positiveSignals,
            negativeSignals: envelope.negativeSignals,
            reasonSummary: envelope.reasonSummary
        )
    }

    private var merchantClassificationSystemPrompt: String {
        """
        You are Gemma 4 running locally inside Tally, a privacy-first subscription tracker.
        Classify transaction merchants for subscription detection, merchant normalization,
        and service identity cleanup.
        Return strict JSON only.
        Focus on merchant identity and type, not prose.
        Stable brands and compact service categories are preferred.
        Grocery stores, restaurants, salons, pharmacies, and one-off marketplaces are usually not subscriptions.
        Repeated visits to grocery stores, restaurants, medical providers, chiropractors, therapists, salons,
        pharmacies, gas stations, and marketplaces are usually not subscriptions unless the merchant identity itself
        clearly points to a membership or subscription business.
        Favor stable consumer-facing brand names over descriptors or processor text.
        If the evidence is weak, lower confidence rather than over-asserting.
        """
    }

    private func decodeJSON<T: Decodable>(
        type: T.Type,
        systemPrompt: String,
        userPrompt: String
    ) async throws -> T {
        let rawOutput = try await generateRawText(
            telemetryLabel: String(describing: T.self),
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxTokens: 400
        )

        let jsonCandidates = normalizedJSONDataCandidates(from: rawOutput)
        guard jsonCandidates.isEmpty == false else {
            gemmaInferenceLogger.error(
                "Gemma parse failed for \(String(describing: T.self), privacy: .public): no JSON payload found in model output"
            )
            throw GemmaRuntimeError.tokenizationFailed
        }

        let decoder = JSONDecoder()
        var lastError: Error?

        for jsonData in jsonCandidates {
            do {
                return try decoder.decode(T.self, from: jsonData)
            } catch {
                lastError = error
            }
        }

        if let lastError {
            gemmaInferenceLogger.error(
                "Gemma decode failed for \(String(describing: T.self), privacy: .public): candidates=\(jsonCandidates.count, privacy: .public) output_chars=\(rawOutput.count, privacy: .public) decode_error=true"
            )
            throw lastError
        }

        throw GemmaRuntimeError.tokenizationFailed
    }

    private func generateRawText(
        telemetryLabel: String,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int
    ) async throws -> String {
        let start = Date()

        do {
            let text = try await runtime.generateText(
                modelURL: modelURL,
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                maxTokens: maxTokens,
                temperature: 0
            )
            let durationMilliseconds = Date().timeIntervalSince(start) * 1_000
            gemmaInferenceLogger.notice(
                "Gemma inference completed label=\(telemetryLabel, privacy: .public) latency_ms=\(durationMilliseconds, privacy: .public) chars=\(text.count, privacy: .public)"
            )
            return text
        } catch {
            let durationMilliseconds = Date().timeIntervalSince(start) * 1_000
            gemmaInferenceLogger.error(
                "Gemma inference failed label=\(telemetryLabel, privacy: .public) latency_ms=\(durationMilliseconds, privacy: .public) error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            throw error
        }
    }

    private func normalizedJSONDataCandidates(from rawOutput: String) -> [Data] {
        let trimmed = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [Data] = []
        var seenPayloads = Set<String>()

        if let data = trimmed.data(using: .utf8),
           (try? JSONSerialization.jsonObject(with: data)) != nil {
            candidates.append(data)
            seenPayloads.insert(trimmed)
        }

        for candidate in extractJSONSubstrings(from: trimmed) where seenPayloads.contains(candidate) == false {
            guard let data = candidate.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) != nil
            else {
                continue
            }
            candidates.append(data)
            seenPayloads.insert(candidate)
        }

        return candidates
    }

    private func extractJSONSubstrings(from text: String) -> [String] {
        var substrings: [String] = []
        var searchIndex = text.startIndex

        while searchIndex < text.endIndex {
            guard let startIndex = text[searchIndex...].firstIndex(where: { $0 == "{" || $0 == "[" }) else {
                break
            }

            if let match = balancedJSONSubstring(in: text, startingAt: startIndex) {
                substrings.append(match.json)
                searchIndex = text.index(after: match.endIndex)
            } else {
                searchIndex = text.index(after: startIndex)
            }
        }

        return substrings
    }

    private func balancedJSONSubstring(
        in text: String,
        startingAt startIndex: String.Index
    ) -> (json: String, endIndex: String.Index)? {
        let openingCharacter = text[startIndex]
        let closingCharacter: Character = openingCharacter == "{" ? "}" : "]"

        var depth = 0
        var isInsideString = false
        var isEscaped = false

        for index in text[startIndex...].indices {
            let character = text[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                    continue
                }

                if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
                continue
            }

            if character == "\"" {
                isInsideString = true
                continue
            }

            if character == openingCharacter {
                depth += 1
            } else if character == closingCharacter {
                depth -= 1
                if depth == 0 {
                    return (String(text[startIndex...index]), index)
                }
            }
        }

        return nil
    }

    private func jsonString(_ value: String) -> String {
        let data = try? JSONEncoder().encode(value)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }

    private func normalizedBatchResult(
        from item: GemmaBatchClassificationItem,
        fallbackRequest: MerchantClassificationRequest
    ) -> MerchantClassificationResult {
        let canonicalName = item.canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        let merchantKind = item.merchantKind
        let fallback = degradedBatchFallback(for: fallbackRequest)

        return MerchantClassificationResult(
            canonicalName: canonicalName.isEmpty ? fallback.canonicalName : canonicalName,
            serviceCategory: normalizedServiceCategory(
                item.serviceCategory,
                merchantKind: merchantKind
            ),
            merchantKind: merchantKind,
            subscriptionAffinity: min(max(item.subscriptionAffinity, 0), 1),
            confidence: min(max(item.confidence, 0), 1)
        )
    }

    private func degradedBatchFallback(
        for request: MerchantClassificationRequest
    ) -> MerchantClassificationResult {
        MerchantClassificationResult(
            canonicalName: request.rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines),
            serviceCategory: MerchantKind.unknown.defaultServiceCategory,
            merchantKind: .unknown,
            subscriptionAffinity: MerchantKind.unknown.defaultSubscriptionAffinity,
            confidence: 0
        )
    }

    private func shouldReplaceBatchResult(
        existing: MerchantClassificationResult,
        candidate: MerchantClassificationResult
    ) -> Bool {
        if candidate.confidence != existing.confidence {
            return candidate.confidence > existing.confidence
        }

        if candidate.subscriptionAffinity != existing.subscriptionAffinity {
            return candidate.subscriptionAffinity > existing.subscriptionAffinity
        }

        return candidate.canonicalName.count < existing.canonicalName.count
    }

    private func normalizedServiceCategory(
        _ rawCategory: String,
        merchantKind: MerchantKind
    ) -> String {
        let trimmedCategory = rawCategory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedCategory.isEmpty == false else {
            return merchantKind.defaultServiceCategory
        }

        return AIServiceCategoryValidator.isValid(trimmedCategory)
            ? trimmedCategory
            : merchantKind.defaultServiceCategory
    }
}
