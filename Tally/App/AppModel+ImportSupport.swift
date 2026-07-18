import Foundation
import OSLog
import SwiftData

struct ClassificationLoadResult: Sendable {
    let results: [String: MerchantClassificationResult]
    let strategy: MerchantClassificationStrategy
    let fallbackReason: MerchantClassificationFallbackReason?
    let uniqueMerchantCount: Int
}

private struct ClassificationCaches {
    let aliasByRawMerchant: [String: MerchantAlias]
    let cachedByRawMerchant: [String: MerchantClassification]
    let cachedByCanonicalMerchant: [String: [MerchantClassification]]
}

private let classificationTelemetryLogger = Logger(
    subsystem: "Tally",
    category: "Classification"
)

private let currentClassificationCacheVersion = 4
private let fallbackClassificationCacheVersion = 0
private let maxClassificationCacheAge: TimeInterval = 180 * 24 * 60 * 60

extension AppModel {
    func loadClassifications(
        for seeds: [NormalizedTransactionSeed],
        context: ModelContext,
        forceRefresh: Bool = false
    ) async throws -> ClassificationLoadResult {
        let startedAt = Date()
        let seedByMerchant = representativeSeeds(from: seeds)
        let uniqueMerchantCount = seedByMerchant.count
        let requestedStrategy = classifier.strategy(forUniqueMerchantCount: uniqueMerchantCount)
        let caches = try fetchClassificationCaches(in: context)

        var results: [String: MerchantClassificationResult] = [:]
        var requestsToClassify: [MerchantClassificationRequest] = []

        for (index, seed) in seedByMerchant.values.enumerated() {
            populateClassification(
                for: seed,
                caches: caches,
                forceRefresh: forceRefresh,
                results: &results,
                requestsToClassify: &requestsToClassify
            )

            if index.isMultiple(of: 100) {
                await Task.yield()
            }
        }

        let batchResult = try await classifier.classifyBatch(
            requestsToClassify,
            strategy: requestedStrategy
        )
        persistClassifications(
            batchResult.results,
            requestsToClassify: requestsToClassify,
            cachedByRawMerchant: caches.cachedByRawMerchant,
            currentCacheableRawMerchants: batchResult.currentCacheableRawMerchants,
            results: &results,
            context: context
        )

        let result = ClassificationLoadResult(
            results: results,
            strategy: batchResult.strategyUsed,
            fallbackReason: batchResult.fallbackReason,
            uniqueMerchantCount: uniqueMerchantCount
        )

        classificationTelemetryLogger.notice(
            """
            classification_load strategy=\(String(describing: batchResult.strategyUsed), privacy: .public) \
            requested_strategy=\(String(describing: requestedStrategy), privacy: .public) \
            unique_merchants=\(uniqueMerchantCount, privacy: .public) \
            reused_results=\(results.count - requestsToClassify.count, privacy: .public) \
            provider_requests=\(requestsToClassify.count, privacy: .public) \
            elapsed_ms=\(telemetryElapsedMilliseconds(since: startedAt), format: .fixed(precision: 2), privacy: .public)
            """
        )

        return result
    }

    func finishImportPreparation(
        _ outcome: PreparedImportOutcome,
        importRecordID: UUID,
        into context: ModelContext
    ) {
        defer { isPreparingImport = false }

        let importRecord: ImportRecord?
        do {
            importRecord = try self.importRecord(withID: importRecordID, in: context)
        } catch {
            currentImportRecord = nil
            importErrorMessage = "Failed to load import record: \(error.localizedDescription)"
            return
        }

        guard let importRecord else {
            currentImportRecord = nil
            if case let .failure(message) = outcome {
                importErrorMessage = message
            }
            return
        }

        switch outcome {
        case let .success(draft):
            let resolvedDraft = draftApplyingStoredTemplate(draft, context: context)
            importDraft = resolvedDraft
            importRecord.status = .needsMapping
            importRecord.mappingSignature = resolvedDraft.suggestedMapping.signature
            importRecord.errorMessage = nil
            try? context.save()

            currentImportRecord = importRecord
            importErrorMessage = nil
        case let .failure(message):
            importRecord.status = .failed
            importRecord.mappingSignature = "unavailable"
            importRecord.errorMessage = message
            try? context.save()

            currentImportRecord = nil
            importErrorMessage = message
        }
    }

    func importRecord(withID id: UUID, in context: ModelContext) throws -> ImportRecord? {
        let descriptor = FetchDescriptor<ImportRecord>(
            predicate: #Predicate { item in
                item.id == id
            }
        )

        return try context.fetch(descriptor).first
    }

    func shouldDiscardImportRecord(_ importRecord: ImportRecord) -> Bool {
        switch importRecord.status {
        case .parsing, .needsMapping:
            return true
        case .queued, .classifying, .analyzed, .failed:
            return false
        }
    }

    func representativePriority(for seed: NormalizedTransactionSeed) -> Int {
        let combined = [
            seed.merchantRaw.lowercased(),
            seed.memo?.lowercased() ?? "",
            seed.category?.lowercased() ?? ""
        ].joined(separator: " ")

        var score = 0

        if [
            "subscription",
            "membership",
            "member",
            "renew",
            "renewal",
            "plan",
            "premium",
            "plus",
            "pro",
            "annual",
            "monthly",
            "prime",
            "icloud"
        ].contains(where: { combined.localizedStandardContains($0) }) {
            score += 4
        }

        if [
            "stream",
            "music",
            "software",
            "storage",
            "membership"
        ].contains(where: { combined.localizedStandardContains($0) }) {
            score += 2
        }

        if [
            "grocer",
            "food",
            "restaurant",
            "retail",
            "shopping",
            "fuel",
            "gas",
            "travel",
            "transport"
        ].contains(where: { combined.localizedStandardContains($0) }) {
            score -= 2
        }

        score += min(seed.memo?.count ?? 0, 40) / 20
        return score
    }

    /// Re-applies a previously saved column mapping when the incoming file's headers
    /// exactly match a stored template, so the user does not have to remap familiar exports.
    /// Falls back to the guessed mapping when only a generic subset matches.
    func draftApplyingStoredTemplate(
        _ draft: TransactionImportDraft,
        context: ModelContext
    ) -> TransactionImportDraft {
        guard var config = matchingTemplateConfig(forHeaders: draft.headers, context: context) else {
            return draft
        }

        let reusedTemplateSign = config.debitSignConvention == draft.suggestedMapping.debitSignConvention
        if !reusedTemplateSign {
            config.debitSignConvention = draft.suggestedMapping.debitSignConvention
        }

        return TransactionImportDraft(
            id: draft.id,
            fileName: draft.fileName,
            headers: draft.headers,
            previewRows: draft.previewRows,
            rawRows: draft.rawRows,
            suggestedMapping: config,
            confidence: reusedTemplateSign ? 1.0 : draft.confidence,
            warnings: draft.warnings
        )
    }

    func matchingTemplateConfig(
        forHeaders headers: [String],
        context: ModelContext
    ) -> ColumnMappingConfig? {
        let templates: [ColumnMappingTemplate]
        do {
            templates = try context.fetch(FetchDescriptor<ColumnMappingTemplate>())
        } catch {
            return nil
        }

        let headerSet = Set(headers)
        return templates
            .sorted { $0.createdAt > $1.createdAt }
            .map(\.config)
            .first { templateColumnsExactlyMatch(in: headerSet, config: $0) }
    }

    private func templateColumnsExactlyMatch(
        in headerSet: Set<String>,
        config: ColumnMappingConfig
    ) -> Bool {
        Set(templateColumns(from: config)) == headerSet
    }

    private func templateColumns(from config: ColumnMappingConfig) -> [String] {
        [
            config.dateColumn,
            config.descriptionColumn,
            config.amountColumn,
            config.merchantColumn,
            config.categoryColumn,
            config.accountColumn,
            config.currencyColumn
        ].compactMap { $0 }
    }

    func importResultMessage(
        importFileName: String,
        upsertSummary: SourceTransactionUpsertSummary
    ) -> String {
        let breakdown = [
            "\(upsertSummary.insertedCount) new",
            "\(upsertSummary.updatedCount) updated",
            "\(upsertSummary.unchangedCount) unchanged"
        ].joined(separator: ", ")
        return "Imported \(upsertSummary.reconciledCount) transactions from \(importFileName) (\(breakdown))."
    }

    func upsertTemplate(from mapping: ColumnMappingConfig, context: ModelContext) throws {
        let descriptor = FetchDescriptor<ColumnMappingTemplate>(
            predicate: #Predicate { item in
                item.signature == mapping.signature
            }
        )

        if try context.fetch(descriptor).isEmpty {
            context.insert(ColumnMappingTemplate(config: mapping))
        }
    }
}

private func telemetryElapsedMilliseconds(since startedAt: Date) -> Double {
    startedAt.distance(to: .now) * 1000
}

private extension AppModel {
    func fetchClassificationCaches(in context: ModelContext) throws -> ClassificationCaches {
        let aliases = try context.fetch(FetchDescriptor<MerchantAlias>())
        let cachedClassifications = try context.fetch(FetchDescriptor<MerchantClassification>())
        let aliasByRawMerchant = aliases.reduce(into: [String: MerchantAlias]()) { result, alias in
            result[alias.rawMerchant] = alias
        }
        let cachedByRawMerchant = cachedClassifications.reduce(
            into: [String: MerchantClassification]()
        ) { result, classification in
            result[classification.rawMerchant] = classification
        }
        let cachedByCanonicalMerchant = cachedClassifications.reduce(
            into: [String: [MerchantClassification]]()
        ) { result, classification in
            result[classification.canonicalName, default: []].append(classification)
        }

        return ClassificationCaches(
            aliasByRawMerchant: aliasByRawMerchant,
            cachedByRawMerchant: cachedByRawMerchant,
            cachedByCanonicalMerchant: cachedByCanonicalMerchant
        )
    }

    func representativeSeeds(
        from seeds: [NormalizedTransactionSeed]
    ) -> [String: NormalizedTransactionSeed] {
        var seedByMerchant: [String: NormalizedTransactionSeed] = [:]
        for seed in seeds {
            if let existing = seedByMerchant[seed.merchantRaw] {
                if representativePriority(for: seed) > representativePriority(for: existing) {
                    seedByMerchant[seed.merchantRaw] = seed
                }
            } else {
                seedByMerchant[seed.merchantRaw] = seed
            }
        }
        return seedByMerchant
    }

    func populateClassification(
        for seed: NormalizedTransactionSeed,
        caches: ClassificationCaches,
        forceRefresh: Bool,
        results: inout [String: MerchantClassificationResult],
        requestsToClassify: inout [MerchantClassificationRequest]
    ) {
        if let alias = caches.aliasByRawMerchant[seed.merchantRaw] {
            let prior = reusableCachedClassification(
                rawMerchant: seed.merchantRaw,
                canonicalName: alias.canonicalName,
                caches: caches,
                forceRefresh: forceRefresh
            )?.result
            results[seed.merchantRaw] = MerchantClassificationResult(
                canonicalName: alias.canonicalName,
                serviceCategory: seed.category ?? prior?.serviceCategory ?? "Uncategorized",
                merchantKind: prior?.merchantKind ?? .unknown,
                subscriptionAffinity: prior?.subscriptionAffinity ?? 0.5,
                confidence: max(prior?.confidence ?? 0.75, 0.75)
            )
            return
        }

        if forceRefresh == false, let cached = caches.cachedByRawMerchant[seed.merchantRaw] {
            if shouldReuseCachedClassification(cached) {
                results[seed.merchantRaw] = cached.result
                return
            }
        }

        requestsToClassify.append(
            MerchantClassificationRequest(
                rawMerchant: seed.merchantRaw,
                memo: seed.memo,
                category: seed.category,
                amount: seed.transactionAmount
            )
        )
    }

    func persistClassifications(
        _ batchResults: [String: MerchantClassificationResult],
        requestsToClassify: [MerchantClassificationRequest],
        cachedByRawMerchant: [String: MerchantClassification],
        currentCacheableRawMerchants: Set<String>,
        results: inout [String: MerchantClassificationResult],
        context: ModelContext
    ) {
        for request in requestsToClassify {
            guard let classification = batchResults[request.rawMerchant] else {
                continue
            }
            results[request.rawMerchant] = classification
            let classifierVersion = currentCacheableRawMerchants.contains(request.rawMerchant)
                ? currentClassificationCacheVersion
                : fallbackClassificationCacheVersion
            if let cached = cachedByRawMerchant[request.rawMerchant] {
                cached.canonicalName = classification.canonicalName
                cached.serviceCategory = classification.serviceCategory
                cached.merchantKind = classification.merchantKind
                cached.subscriptionAffinity = classification.subscriptionAffinity
                cached.confidence = classification.confidence
                cached.classifierVersion = classifierVersion
                cached.lastUpdatedAt = .now
            } else {
                context.insert(
                    MerchantClassification(
                        rawMerchant: request.rawMerchant,
                        result: classification,
                        classifierVersion: classifierVersion
                    )
                )
            }
        }
    }

    func reusableCachedClassification(
        rawMerchant: String,
        canonicalName: String,
        caches: ClassificationCaches,
        forceRefresh: Bool
    ) -> MerchantClassification? {
        guard forceRefresh == false else {
            return nil
        }

        var candidates: [MerchantClassification] = []
        if let cached = caches.cachedByRawMerchant[rawMerchant] {
            candidates.append(cached)
        }
        candidates.append(contentsOf: caches.cachedByCanonicalMerchant[canonicalName] ?? [])

        return candidates.filter(shouldReuseCachedClassification).max(by: { lhs, rhs in
            cachedClassificationPreference(lhs) < cachedClassificationPreference(rhs)
        })
    }

    func cachedClassificationPreference(_ cached: MerchantClassification) -> Int {
        if cached.isUserCorrected {
            return 2
        }

        if cached.classifierVersion == currentClassificationCacheVersion {
            return 1
        }

        return 0
    }

    func shouldReuseCachedClassification(_ cached: MerchantClassification) -> Bool {
        if cached.isUserCorrected {
            return true
        }

        guard cached.classifierVersion == currentClassificationCacheVersion else {
            return false
        }

        if cached.lastUpdatedAt < Date().addingTimeInterval(-maxClassificationCacheAge) {
            return false
        }

        if cached.confidence < 0.65 {
            return false
        }

        return cached.serviceCategory != "Uncategorized"
    }
}
