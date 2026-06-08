import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

protocol MerchantClassificationIntelligence: Sendable {
    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async -> MerchantClassificationResult?

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async -> [String: MerchantClassificationResult]?
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

struct MerchantClassificationRequest: Sendable {
    let rawMerchant: String
    let memo: String?
    let category: String?
    let amount: Decimal
}

struct MerchantClassificationBatchResult: Sendable {
    let results: [String: MerchantClassificationResult]
    let strategyUsed: MerchantClassificationStrategy
    let fallbackReason: MerchantClassificationFallbackReason?
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
    ) async -> MerchantClassificationResult {
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

        if let result = await intelligence.classifyMerchant(
            rawMerchant: rawMerchant,
            memo: memo,
            category: category,
            amount: amount
        ) {
            return result
        }

        return heuristicResult
    }

    func classifyBatch(
        _ requests: [MerchantClassificationRequest],
        strategy: MerchantClassificationStrategy
    ) async -> MerchantClassificationBatchResult {
        guard !requests.isEmpty else {
            return MerchantClassificationBatchResult(
                results: [:],
                strategyUsed: strategy,
                fallbackReason: nil
            )
        }

        switch strategy {
        case .heuristicOnly:
            return MerchantClassificationBatchResult(
                results: heuristicResults(for: requests),
                strategyUsed: .heuristicOnly,
                fallbackReason: selectedProviderStatus.isReady ? .confidentHeuristics : .providerUnavailable
            )
        case .individual:
            return await individualBatchResult(for: requests)
        case .providerBatch:
            return await providerBatchResult(for: requests)
        }
    }

    func strategy(forUniqueMerchantCount count: Int) -> MerchantClassificationStrategy {
        count > providerBatchThreshold ? .providerBatch : .individual
    }

    func importStrategy(forUniqueMerchantCount count: Int) -> MerchantClassificationStrategy {
        return strategy(forUniqueMerchantCount: count)
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
    ) async -> MerchantClassificationBatchResult {
        var results: [String: MerchantClassificationResult] = [:]
        var usedProvider = false
        var attemptedProvider = false
        var providerFailed = false

        for request in requests {
            let heuristicResult = heuristic.classify(
                rawMerchant: request.rawMerchant,
                memo: request.memo,
                category: request.category,
                amount: request.amount
            )

            if shouldPreferHeuristic(heuristicResult) {
                results[request.rawMerchant] = heuristicResult
                continue
            }

            attemptedProvider = true
            if let result = await intelligence.classifyMerchant(
                rawMerchant: request.rawMerchant,
                memo: request.memo,
                category: request.category,
                amount: request.amount
            ) {
                results[request.rawMerchant] = result
                usedProvider = true
            } else {
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
            )
        )
    }

    private func providerBatchResult(
        for requests: [MerchantClassificationRequest]
    ) async -> MerchantClassificationBatchResult {
        var results: [String: MerchantClassificationResult] = [:]
        let heuristics = heuristicResults(for: requests)
        var usedProviderBatch = false
        var providerBatchFailed = false

        let aiEligibleRequests = requests.filter { request in
            guard let heuristicResult = heuristics[request.rawMerchant] else {
                return true
            }
            return shouldPreferHeuristic(heuristicResult) == false
        }

        for request in requests
        where aiEligibleRequests.contains(where: { $0.rawMerchant == request.rawMerchant }) == false {
            if let heuristicResult = heuristics[request.rawMerchant] {
                results[request.rawMerchant] = heuristicResult
            }
        }

        for batchStart in stride(from: 0, to: aiEligibleRequests.count, by: providerBatchSize) {
            let batchEnd = min(batchStart + providerBatchSize, aiEligibleRequests.count)
            let batch = Array(aiEligibleRequests[batchStart..<batchEnd])
            if let batchResults = await intelligence.classifyMerchantsBatch(batch),
               batchResults.isEmpty == false {
                usedProviderBatch = true
                for request in batch {
                    if let result = batchResults[request.rawMerchant] {
                        results[request.rawMerchant] = result
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
            )
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
