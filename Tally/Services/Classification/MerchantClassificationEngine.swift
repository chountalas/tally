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

struct MerchantClassificationRequest: Sendable {
    let rawMerchant: String
    let memo: String?
    let category: String?
    let amount: Decimal
}

struct MerchantClassificationBatchResult: Sendable {
    let results: [String: MerchantClassificationResult]
    let strategyUsed: MerchantClassificationStrategy
}

struct MerchantClassificationEngine: Sendable {
    private let heuristic = HeuristicMerchantClassifier()
    private let intelligence: any MerchantClassificationIntelligence
    private let selectedProviderKind: AIProviderKind
    private let providerBatchThreshold = 25
    private let providerBatchSize = 20

    init(
        preferences: AIProviderPreferences = AIProviderPreferences(),
        intelligence: (any MerchantClassificationIntelligence)? = nil
    ) {
        self.selectedProviderKind = preferences.selectedKind
        self.intelligence = intelligence ?? SubscriptionIntelligenceService(
            usage: .backgroundAutomation,
            preferences: preferences
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
            return MerchantClassificationBatchResult(results: [:], strategyUsed: strategy)
        }

        switch strategy {
        case .heuristicOnly:
            return MerchantClassificationBatchResult(
                results: heuristicResults(for: requests),
                strategyUsed: .heuristicOnly
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
        #if os(macOS)
        if selectedProviderKind == .gemmaLocal {
            return .heuristicOnly
        }
        #endif

        return strategy(forUniqueMerchantCount: count)
    }

    func availabilitySummary(for strategy: MerchantClassificationStrategy, uniqueMerchantCount: Int) -> String {
        if strategy == .heuristicOnly {
            let merchantLabel = uniqueMerchantCount == 1 ? "merchant" : "merchants"
            return """
            Used heuristic classification for \(uniqueMerchantCount) unique \(merchantLabel)
            to keep the import responsive.
            """
        }

        if strategy == .providerBatch {
            let merchantLabel = uniqueMerchantCount == 1 ? "merchant" : "merchants"
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
        for request in requests {
            results[request.rawMerchant] = await classify(
                rawMerchant: request.rawMerchant,
                memo: request.memo,
                category: request.category,
                amount: request.amount,
                strategy: .individual
            )
        }
        return MerchantClassificationBatchResult(
            results: results,
            strategyUsed: .individual
        )
    }

    private func providerBatchResult(
        for requests: [MerchantClassificationRequest]
    ) async -> MerchantClassificationBatchResult {
        var results: [String: MerchantClassificationResult] = [:]
        let heuristics = heuristicResults(for: requests)
        var usedProviderBatch = false

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
                        results[request.rawMerchant] = heuristics[request.rawMerchant]
                    }
                }
            } else {
                for request in batch {
                    results[request.rawMerchant] = heuristics[request.rawMerchant]
                }
            }
        }

        return MerchantClassificationBatchResult(
            results: results,
            strategyUsed: usedProviderBatch ? .providerBatch : .heuristicOnly
        )
    }

    private func intelligenceAvailabilitySummary() -> String {
        let selectedProvider = selectedProviderKind
        let status = AIProviderRegistry.statusSnapshot(for: selectedProvider)
        guard status.isReady else {
            return """
            \(selectedProvider.title) is unavailable: \(status.detail). Falling back to
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
