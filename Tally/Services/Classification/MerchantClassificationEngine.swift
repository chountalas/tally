import Foundation

protocol MerchantClassificationIntelligence: Sendable {
    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async throws -> MerchantClassificationResult?

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async throws -> [String: MerchantClassificationResult]?
}

extension SubscriptionIntelligenceService: MerchantClassificationIntelligence {}

enum MerchantClassificationStrategy: Sendable {
    case individual
    case providerBatch
    case heuristicOnly
}

enum MerchantClassificationFallbackReason: Sendable, Equatable {
    case providerUnavailable
    case confidentHeuristics
    case providerFailed
    case partialProviderFailure
}

struct MerchantClassificationBatchResult: Sendable {
    let results: [String: MerchantClassificationResult]
    let strategyUsed: MerchantClassificationStrategy
    let fallbackReason: MerchantClassificationFallbackReason?
    let currentCacheableRawMerchants: Set<String>
}

struct MerchantClassificationEngine: Sendable {
    private let heuristic = HeuristicMerchantClassifier()
    private let intelligence: any MerchantClassificationIntelligence
    private let selectedProviderKind: AIProviderKind
    private let selectedProviderStatus: AIProviderStatusSnapshot
    private let providerBatchThreshold = 25
    private let providerBatchSize = 20

    init(
        preferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        intelligence: (any MerchantClassificationIntelligence)? = nil
    ) {
        self.selectedProviderKind = preferences.selectedKind
        self.selectedProviderStatus = AIProviderRegistry.statusSnapshot(
            for: preferences.selectedKind,
            gemmaModelManager: gemmaModelManager
        )
        self.intelligence = intelligence ?? SubscriptionIntelligenceService(
            usage: .backgroundAutomation,
            preferences: preferences,
            gemmaModelManager: gemmaModelManager
        )
    }

    func classify(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal,
        strategy: MerchantClassificationStrategy = .individual
    ) async throws -> MerchantClassificationResult {
        try Task.checkCancellation()
        let heuristicResult = heuristic.classify(
            rawMerchant: rawMerchant,
            memo: memo,
            category: category,
            amount: amount
        )

        if strategy == .heuristicOnly {
            return heuristicResult
        }

        if shouldPreferHeuristic(heuristicResult) {
            return heuristicResult
        }

        do {
            if let result = try await intelligence.classifyMerchant(
                rawMerchant: rawMerchant,
                memo: memo,
                category: category,
                amount: amount
            ) {
                return result
            }
        } catch {
            guard (error is CancellationError) == false, Task.isCancelled == false else {
                throw error
            }
            return heuristicResult
        }

        return heuristicResult
    }

    func classifyBatch(
        _ requests: [MerchantClassificationRequest],
        strategy: MerchantClassificationStrategy
    ) async throws -> MerchantClassificationBatchResult {
        guard !requests.isEmpty else {
            return MerchantClassificationBatchResult(
                results: [:],
                strategyUsed: strategy,
                fallbackReason: nil,
                currentCacheableRawMerchants: []
            )
        }

        switch strategy {
        case .heuristicOnly:
            let results = heuristicResults(for: requests)
            return MerchantClassificationBatchResult(
                results: results,
                strategyUsed: .heuristicOnly,
                fallbackReason: selectedProviderStatus.isReady ? .confidentHeuristics : .providerUnavailable,
                currentCacheableRawMerchants: selectedProviderStatus.isReady ? Set(results.keys) : []
            )
        case .individual:
            return try await individualBatchResult(for: requests)
        case .providerBatch:
            return try await providerBatchResult(for: requests)
        }
    }

    func strategy(forUniqueMerchantCount count: Int) -> MerchantClassificationStrategy {
        count > providerBatchThreshold ? .providerBatch : .individual
    }

    func availabilitySummary(
        for strategy: MerchantClassificationStrategy,
        uniqueMerchantCount: Int,
        fallbackReason: MerchantClassificationFallbackReason? = nil
    ) -> String {
        let merchantLabel = uniqueMerchantCount == 1 ? "merchant" : "merchants"

        switch fallbackReason {
        case .providerFailed:
            return """
            \(selectedProviderKind.title) was attempted but could not complete. Falling back to
            heuristic classification for \(uniqueMerchantCount) unique \(merchantLabel).
            """
        case .partialProviderFailure:
            return """
            Used \(selectedProviderKind.title) classification with heuristic fallback for some of
            \(uniqueMerchantCount) unique \(merchantLabel).
            """
        case .providerUnavailable:
            return """
            \(selectedProviderKind.title) is unavailable: \(selectedProviderStatus.detail) Falling back to
            heuristic classification for \(uniqueMerchantCount) unique \(merchantLabel).
            """
        case .confidentHeuristics:
            return """
            Used heuristic classification for \(uniqueMerchantCount) unique \(merchantLabel)
            because local rules were confident enough to skip AI.
            """
        case nil:
            break
        }

        if strategy == .heuristicOnly {
            if selectedProviderStatus.isReady == false {
                return """
                \(selectedProviderKind.title) is unavailable: \(selectedProviderStatus.detail) Falling back to
                heuristic classification for \(uniqueMerchantCount) unique \(uniqueMerchantCount == 1 ? "merchant" : "merchants").
                """
            }

            return """
            Used heuristic classification for \(uniqueMerchantCount) unique \(merchantLabel)
            because local rules were confident enough to skip AI.
            """
        }

        if strategy == .providerBatch {
            return """
            Used \(selectedProviderKind.title) batch classification for \(uniqueMerchantCount) unique
            \(merchantLabel).
            """
        }

        return intelligenceAvailabilitySummary()
    }

    private func heuristicResults(
        for requests: [MerchantClassificationRequest]
    ) -> [String: MerchantClassificationResult] {
        Dictionary(uniqueKeysWithValues: requests.map { request in
            (
                request.rawMerchant,
                heuristic.classify(
                    rawMerchant: request.rawMerchant,
                    memo: request.memo,
                    category: request.category,
                    amount: request.amount
                )
            )
        })
    }

    private func individualBatchResult(
        for requests: [MerchantClassificationRequest]
    ) async throws -> MerchantClassificationBatchResult {
        var results: [String: MerchantClassificationResult] = [:]
        var usedProvider = false
        var attemptedProvider = false
        var providerFailed = false
        var currentCacheableRawMerchants: Set<String> = []

        for request in requests {
            try Task.checkCancellation()
            let heuristicResult = heuristic.classify(
                rawMerchant: request.rawMerchant,
                memo: request.memo,
                category: request.category,
                amount: request.amount
            )

            if shouldPreferHeuristic(heuristicResult) {
                results[request.rawMerchant] = heuristicResult
                currentCacheableRawMerchants.insert(request.rawMerchant)
                continue
            }

            attemptedProvider = true
            do {
                if let result = try await intelligence.classifyMerchant(
                    rawMerchant: request.rawMerchant,
                    memo: request.memo,
                    category: request.category,
                    amount: request.amount
                ) {
                    results[request.rawMerchant] = result
                    usedProvider = true
                    currentCacheableRawMerchants.insert(request.rawMerchant)
                } else {
                    results[request.rawMerchant] = heuristicResult
                    providerFailed = true
                }
            } catch {
                guard (error is CancellationError) == false, Task.isCancelled == false else {
                    throw error
                }
                results[request.rawMerchant] = heuristicResult
                providerFailed = true
            }
        }
        return MerchantClassificationBatchResult(
            results: results,
            strategyUsed: usedProvider ? .individual : .heuristicOnly,
            fallbackReason: providerFallbackReason(
                attemptedProvider: attemptedProvider,
                usedProvider: usedProvider,
                providerFailed: providerFailed
            ),
            currentCacheableRawMerchants: currentCacheableRawMerchants
        )
    }

    private func providerBatchResult(
        for requests: [MerchantClassificationRequest]
    ) async throws -> MerchantClassificationBatchResult {
        var results: [String: MerchantClassificationResult] = [:]
        let heuristics = heuristicResults(for: requests)
        var usedProviderBatch = false
        var providerBatchFailed = false
        var currentCacheableRawMerchants: Set<String> = []

        let aiEligibleRequests = requests.filter { request in
            guard let heuristicResult = heuristics[request.rawMerchant] else {
                return true
            }
            return shouldPreferHeuristic(heuristicResult) == false
        }
        let aiEligibleRawMerchants = Set(aiEligibleRequests.map(\.rawMerchant))

        for request in requests
        where aiEligibleRawMerchants.contains(request.rawMerchant) == false {
            if let heuristicResult = heuristics[request.rawMerchant] {
                results[request.rawMerchant] = heuristicResult
                currentCacheableRawMerchants.insert(request.rawMerchant)
            }
        }

        for batchStart in stride(from: 0, to: aiEligibleRequests.count, by: providerBatchSize) {
            try Task.checkCancellation()
            let batchEnd = min(batchStart + providerBatchSize, aiEligibleRequests.count)
            let batch = Array(aiEligibleRequests[batchStart..<batchEnd])
            if let batchResults = try await intelligence.classifyMerchantsBatch(batch),
               batchResults.isEmpty == false {
                usedProviderBatch = true
                for request in batch {
                    if let result = batchResults[request.rawMerchant] {
                        results[request.rawMerchant] = result
                        currentCacheableRawMerchants.insert(request.rawMerchant)
                    } else {
                        providerBatchFailed = true
                        results[request.rawMerchant] = heuristics[request.rawMerchant]
                    }
                }
            } else {
                providerBatchFailed = true
                for request in batch {
                    results[request.rawMerchant] = heuristics[request.rawMerchant]
                }
            }
        }

        return MerchantClassificationBatchResult(
            results: results,
            strategyUsed: usedProviderBatch ? .providerBatch : .heuristicOnly,
            fallbackReason: providerFallbackReason(
                attemptedProvider: aiEligibleRequests.isEmpty == false,
                usedProvider: usedProviderBatch,
                providerFailed: providerBatchFailed
            ),
            currentCacheableRawMerchants: currentCacheableRawMerchants
        )
    }

    private func providerFallbackReason(
        attemptedProvider: Bool,
        usedProvider: Bool,
        providerFailed: Bool
    ) -> MerchantClassificationFallbackReason? {
        if providerFailed {
            if selectedProviderStatus.isReady == false {
                return .providerUnavailable
            }

            return usedProvider ? .partialProviderFailure : .providerFailed
        }

        if attemptedProvider == false {
            return .confidentHeuristics
        }

        return nil
    }

    private func intelligenceAvailabilitySummary() -> String {
        let selectedProvider = selectedProviderKind
        guard selectedProviderStatus.isReady else {
            return """
            \(selectedProvider.title) is unavailable: \(selectedProviderStatus.detail). Falling back to
            heuristic classification.
            """
        }

        return "\(selectedProvider.title) classification is available on this device."
    }

    private func shouldPreferHeuristic(_ result: MerchantClassificationResult) -> Bool {
        guard result.confidence >= 0.9 else {
            return false
        }

        return result.subscriptionAffinity >= 0.95 || result.subscriptionAffinity <= 0.05
    }
}
