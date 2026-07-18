import Foundation

enum SubscriptionIntelligenceUsage: Sendable {
    case interactive
    case backgroundAutomation
}

actor SubscriptionIntelligenceResponseStore {
    private struct CachedResponse {
        let response: IntelligenceResponse
        let expiresAt: Date
    }

    private var cachedResponses: [String: CachedResponse] = [:]
    private var inFlightResponses: [String: Task<IntelligenceResponse, Never>] = [:]

    func cachedResponse(for key: String, now: Date = .now) -> IntelligenceResponse? {
        pruneExpiredEntries(now: now)
        return cachedResponses[key]?.response
    }

    func inFlightResponse(for key: String, now: Date = .now) -> Task<IntelligenceResponse, Never>? {
        pruneExpiredEntries(now: now)
        return inFlightResponses[key]
    }

    func beginResponse(
        _ task: Task<IntelligenceResponse, Never>,
        for key: String,
        now: Date = .now
    ) {
        pruneExpiredEntries(now: now)
        inFlightResponses[key] = task
    }

    func finishResponse(
        for key: String,
        response: IntelligenceResponse,
        ttl: TimeInterval,
        now: Date = .now
    ) {
        pruneExpiredEntries(now: now)
        inFlightResponses[key] = nil
        cachedResponses[key] = CachedResponse(
            response: response,
            expiresAt: now.addingTimeInterval(ttl)
        )
    }

    private func pruneExpiredEntries(now: Date) {
        cachedResponses = cachedResponses.filter { $0.value.expiresAt > now }
    }
}

struct SubscriptionIntelligenceCacheSnapshot {
    let cacheKey: String

    init(
        query: IntelligenceQuery,
        generator: (any SubscriptionIntelligenceGenerating)?,
        tooling: SubscriptionIntelligenceTooling
    ) {
        let subscriptions = tooling.allSubscriptions()
        let transactions = tooling.allTransactions()
        let aliases = tooling.allAliases()
        let classifications = tooling.allClassifications()
        let overview = Self.libraryOverview(from: subscriptions)
        let referenceDay = Calendar.current.startOfDay(for: .now).ISO8601Format()
        let libraryFingerprint = Self.libraryFingerprint(
            subscriptions: subscriptions,
            transactions: transactions,
            aliases: aliases,
            classifications: classifications
        )

        cacheKey = [
            "generator:\(generator.map { String(reflecting: type(of: $0)) } ?? "none")",
            query.kind.rawValue,
            query.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            query.subscriptionID?.uuidString ?? "none",
            query.merchantName?.lowercased() ?? "none",
            query.rawMerchant?.lowercased() ?? "none",
            "\(query.days ?? 0)",
            referenceDay,
            Self.subscriptionFingerprint(
                subscriptionID: query.subscriptionID,
                subscriptions: subscriptions
            ),
            libraryFingerprint,
            overview.monthlyRunRate.description,
            overview.annualizedSpend.description,
            "\(overview.activeCount)",
            "\(overview.needsReviewCount)"
        ].joined(separator: "|")
    }

    private static func libraryOverview(
        from subscriptions: [Subscription]
    ) -> LibraryOverviewSnapshot {
        var monthlyRunRate = Decimal.zero
        let activeSubscriptions = DashboardMetrics.currentActiveSubscriptions(from: subscriptions)
        let activeCount = activeSubscriptions.count
        var needsReviewCount = 0

        for subscription in activeSubscriptions {
            monthlyRunRate += subscription.normalizedMonthlyAmount
        }

        for subscription in subscriptions {
            if subscription.status == .needsReview {
                needsReviewCount += 1
            }
        }

        return LibraryOverviewSnapshot(
            monthlyRunRate: monthlyRunRate,
            annualizedSpend: monthlyRunRate * 12,
            activeCount: activeCount,
            needsReviewCount: needsReviewCount
        )
    }

    private static func subscriptionFingerprint(
        subscriptionID: UUID?,
        subscriptions: [Subscription]
    ) -> String {
        guard let subscriptionID,
              let subscription = subscriptions.first(where: { $0.id == subscriptionID }) else {
            return "none"
        }

        return [
            subscription.id.uuidString,
            subscription.displayName,
            subscription.statusRawValue,
            subscription.cadenceRawValue,
            subscription.priceAmount.description,
            subscription.predictedNextChargeDate?.ISO8601Format() ?? "none",
            subscription.confidenceScore.description,
            subscription.priceChangePercent?.description ?? "none"
        ].joined(separator: "::")
    }

    private static func libraryFingerprint(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        aliases: [MerchantAlias],
        classifications: [MerchantClassification]
    ) -> String {
        var hasher = Hasher()
        hasher.combine(subscriptions.count)
        hasher.combine(transactions.count)
        hasher.combine(aliases.count)
        hasher.combine(classifications.count)

        for subscription in subscriptions {
            hasher.combine(subscription.id)
            hasher.combine(subscription.canonicalName)
            hasher.combine(subscription.displayName)
            hasher.combine(subscription.statusRawValue)
            hasher.combine(subscription.cadenceRawValue)
            hasher.combine(subscription.priceAmount.description)
            hasher.combine(subscription.normalizedMonthlyAmount.description)
            hasher.combine(subscription.lastChargeDate?.timeIntervalSinceReferenceDate)
            hasher.combine(subscription.predictedNextChargeDate?.timeIntervalSinceReferenceDate)
            hasher.combine(subscription.confidenceScore)
            hasher.combine(subscription.serviceCategory ?? "")
            hasher.combine(subscription.priceChangePercent)
            hasher.combine(subscription.notes ?? "")
        }

        for transaction in transactions {
            hasher.combine(transaction.id)
            hasher.combine(transaction.transactionDate.timeIntervalSinceReferenceDate)
            hasher.combine(transaction.transactionAmount.description)
            hasher.combine(transaction.merchantRaw)
            hasher.combine(transaction.merchantNormalized)
            hasher.combine(transaction.category ?? "")
            hasher.combine(transaction.memo ?? "")
            hasher.combine(transaction.classificationConfidence)
            hasher.combine(transaction.merchantKindRawValue)
            hasher.combine(transaction.merchantSubscriptionAffinity)
            hasher.combine(transaction.subscriptionID)
        }

        for alias in aliases {
            hasher.combine(alias.rawMerchant)
            hasher.combine(alias.canonicalName)
            hasher.combine(alias.createdAt.timeIntervalSinceReferenceDate)
        }

        for classification in classifications {
            hasher.combine(classification.rawMerchant)
            hasher.combine(classification.canonicalName)
            hasher.combine(classification.serviceCategory)
            hasher.combine(classification.merchantKindRawValue)
            hasher.combine(classification.subscriptionAffinity)
            hasher.combine(classification.confidence)
            hasher.combine(classification.isUserCorrected)
            hasher.combine(classification.lastUpdatedAt.timeIntervalSinceReferenceDate)
        }

        return String(hasher.finalize())
    }
}

struct SubscriptionIntelligenceService: Sendable {
    private static let responseStore = SubscriptionIntelligenceResponseStore()
    private static let responseCacheTTL: TimeInterval = 120

    let usage: SubscriptionIntelligenceUsage
    let generator: (any SubscriptionIntelligenceGenerating)?
    let heuristicClassifier = LocalMerchantSuggestionHeuristic()

    var evidenceProviderKind: AIProviderKind? {
        generator?.evidenceProviderKind
    }

    init(
        usage: SubscriptionIntelligenceUsage = .interactive,
        preferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        generator: (any SubscriptionIntelligenceGenerating)? =
            nil
    ) {
        self.usage = usage
        self.generator = generator ?? SubscriptionIntelligenceService.makeDefaultGenerator(
            usage: usage,
            preferences: preferences,
            gemmaModelManager: gemmaModelManager
        )
    }

    func route(for query: IntelligenceQuery) -> SubscriptionIntelligenceRoute {
        switch query.kind {
        case .savingsReview:
            return .savingsReview
        case .upcomingRenewals:
            return .upcomingRenewals
        case .priceChangeExplanation:
            return .priceChangeExplanation
        case .merchantFix:
            return .merchantFix
        case .custom:
            let normalized = query.prompt.lowercased()
            if normalized.localizedStandardContains("renew") || normalized.localizedStandardContains("upcoming") {
                return .upcomingRenewals
            }
            if normalized.localizedStandardContains("merchant") ||
                normalized.localizedStandardContains("alias") ||
                normalized.localizedStandardContains("rename") ||
                normalized.localizedStandardContains("fix") {
                return .merchantFix
            }
            if normalized.localizedStandardContains("price") ||
                normalized.localizedStandardContains("change") ||
                normalized.localizedStandardContains("increase") {
                return .priceChangeExplanation
            }
            return .savingsReview
        }
    }

    @MainActor
    func respond(
        to query: IntelligenceQuery,
        using tooling: SubscriptionIntelligenceTooling
    ) async -> IntelligenceResponse {
        let cacheKey = responseCacheKey(for: query, tooling: tooling)

        if let cached = await Self.responseStore.cachedResponse(for: cacheKey) {
            return cached
        }

        if let inFlight = await Self.responseStore.inFlightResponse(for: cacheKey) {
            return await inFlight.value
        }

        let task = Task { @MainActor in
            await computeResponse(to: query, using: tooling)
        }
        await Self.responseStore.beginResponse(task, for: cacheKey)

        let response = await task.value
        await Self.responseStore.finishResponse(
            for: cacheKey,
            response: response,
            ttl: Self.responseCacheTTL
        )
        return response
    }

    @MainActor
    private func computeResponse(
        to query: IntelligenceQuery,
        using tooling: SubscriptionIntelligenceTooling
    ) async -> IntelligenceResponse {
        let route = route(for: query)
        let draft = await draftResponse(for: route, query: query, tooling: tooling)

        guard let generator else {
            return draft
        }

        do {
            let copy = try await generator.generateCopy(
                route: route,
                query: query,
                facts: factsString(for: draft),
                draft: draft
            )

            guard let validated = merge(copy: copy, onto: draft) else {
                return draft
            }

            return validated
        } catch {
            return draft
        }
    }

    @MainActor
    private func responseCacheKey(
        for query: IntelligenceQuery,
        tooling: SubscriptionIntelligenceTooling
    ) -> String {
        SubscriptionIntelligenceCacheSnapshot(
            query: query,
            generator: generator,
            tooling: tooling
        ).cacheKey
    }
}
