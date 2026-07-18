import Foundation
import OSLog
import SwiftData

struct SubscriptionLibraryNavigationRequest: Equatable, Sendable {
    let state: SubscriptionLibraryState
    let importRecordID: UUID?
}

enum ManualSubscriptionEditError: LocalizedError {
    case missingSubscription

    var errorDescription: String? {
        switch self {
        case .missingSubscription:
            return "That subscription is no longer available to edit."
        }
    }
}

private enum ReviewUpdateError: LocalizedError {
    case missingSubscription
    case canonicalNameConflict(String)

    var errorDescription: String? {
        switch self {
        case .missingSubscription:
            return "The target subscription could not be found."
        case let .canonicalNameConflict(canonicalName):
            return "A subscription already uses \(canonicalName). Pick a different display name."
        }
    }
}

struct MerchantLearningPreview: Equatable, Sendable {
    enum Mode: Sendable {
        case reinforce
        case rename
        case suppress
    }

    let mode: Mode
    let sourceCanonicalName: String
    let targetCanonicalName: String
    let rawMerchants: [String]
    let affectedTransactionCount: Int
    let affectedImportCount: Int
}

enum ReviewAutomationAction: String, Equatable, Sendable {
    case confirm
    case suppress
    case manual
}

struct ReviewAutomationCandidate: Identifiable, Equatable, Sendable {
    let subscriptionID: UUID
    let displayName: String
    let action: ReviewAutomationAction
    let reason: String
    let confidenceScore: Double
    let linkedTransactionCount: Int
    let monthlyAmount: Decimal
    let currencyCode: String

    var id: UUID { subscriptionID }
}

struct ReviewAutomationPlan: Equatable, Sendable {
    let totalReviewCount: Int
    let confirmCandidates: [ReviewAutomationCandidate]
    let suppressCandidates: [ReviewAutomationCandidate]
    let manualCandidates: [ReviewAutomationCandidate]

    var automatableCandidates: [ReviewAutomationCandidate] {
        confirmCandidates + suppressCandidates
    }

    var automatableCount: Int {
        automatableCandidates.count
    }

    var manualCountAfterAutomation: Int {
        totalReviewCount - automatableCount
    }

    static let empty = ReviewAutomationPlan(
        totalReviewCount: 0,
        confirmCandidates: [],
        suppressCandidates: [],
        manualCandidates: []
    )
}

struct ReviewAutomationResult: Equatable, Sendable {
    let confirmedCount: Int
    let suppressedCount: Int
    let skippedCount: Int

    var appliedCount: Int {
        confirmedCount + suppressedCount
    }
}

private let appActionsLogger = Logger(
    subsystem: "Tally",
    category: "AppActions"
)

extension AppModel {
    struct ManualSubscriptionInput: Sendable {
        let displayName: String
        let priceAmount: Decimal
        let priceCurrency: String
        let cadence: SubscriptionCadence
        let status: SubscriptionStatus
        let lastChargeDate: Date
        let serviceIdentifier: String?
        let paymentMethodName: String?
        let websiteURL: String?
        let reminderDaysBefore: Int?
        let replacementSubscriptionID: UUID?
        let category: String?
        let notes: String?

        init(
            displayName: String,
            priceAmount: Decimal,
            priceCurrency: String = "USD",
            cadence: SubscriptionCadence,
            status: SubscriptionStatus,
            lastChargeDate: Date,
            serviceIdentifier: String? = nil,
            paymentMethodName: String? = nil,
            websiteURL: String? = nil,
            reminderDaysBefore: Int? = nil,
            replacementSubscriptionID: UUID? = nil,
            category: String? = nil,
            notes: String? = nil
        ) {
            self.displayName = displayName
            self.priceAmount = priceAmount
            self.priceCurrency = priceCurrency
            self.cadence = cadence
            self.status = status
            self.lastChargeDate = lastChargeDate
            self.serviceIdentifier = serviceIdentifier
            self.paymentMethodName = paymentMethodName
            self.websiteURL = websiteURL
            self.reminderDaysBefore = reminderDaysBefore
            self.replacementSubscriptionID = replacementSubscriptionID
            self.category = category
            self.notes = notes
        }
    }

    func scheduleSpotlightReindex(
        in context: ModelContext,
        delayNanoseconds: UInt64 = 600_000_000
    ) {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else {
            return
        }
        spotlightReindexTask?.cancel()
        spotlightReindexTask = Task { @MainActor in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard !Task.isCancelled else {
                return
            }
            await spotlightIndexer.reindexIfNeeded(in: context)
        }
    }

    func openTab(_ tab: SidebarTab) {
        tallySelectedSubscriptionID = nil
        selectedTab = tab
        navigationToken = UUID()
    }

    func openRoute(_ route: IntelligenceNavigationRoute) {
        switch route {
        case .subscriptions:
            openTab(.subscriptions)
        case .audit:
            openTab(.audit)
        case .calendar:
            openTab(.calendar)
        case .transactions:
            openTab(.transactions)
        }
    }

    func openSubscription(_ subscriptionID: UUID) {
        selectedTab = .subscriptions
        tallySelectedSubscriptionID = subscriptionID
        pendingSubscriptionNavigationID = nil
        navigationToken = UUID()
    }

    func openSubscriptionLibrary(
        state: SubscriptionLibraryState,
        importRecordID: UUID? = nil
    ) {
        tallySelectedSubscriptionID = nil
        selectedTab = .subscriptions
        pendingSubscriptionLibraryState = state
        pendingSubscriptionLibraryImportRecordID = importRecordID
        navigationToken = UUID()
    }

    func consumePendingSubscriptionLibraryNavigation() -> SubscriptionLibraryNavigationRequest? {
        guard let pendingSubscriptionLibraryState else {
            pendingSubscriptionLibraryImportRecordID = nil
            return nil
        }
        defer {
            self.pendingSubscriptionLibraryState = nil
            pendingSubscriptionLibraryImportRecordID = nil
        }
        return SubscriptionLibraryNavigationRequest(
            state: pendingSubscriptionLibraryState,
            importRecordID: pendingSubscriptionLibraryImportRecordID
        )
    }

    func consumePendingSubscriptionLibraryState() -> SubscriptionLibraryState? {
        defer {
            pendingSubscriptionLibraryState = nil
            pendingSubscriptionLibraryImportRecordID = nil
        }
        return pendingSubscriptionLibraryState
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "tally" else {
            return
        }

        if url.host == "subscription",
           let rawID = url.pathComponents.dropFirst().first,
           let subscriptionID = UUID(uuidString: rawID) {
            openSubscription(subscriptionID)
            return
        }

        if url.host == "tab",
           let rawTab = url.pathComponents.dropFirst().first,
           let tab = SidebarTab(rawValue: rawTab) {
            openTab(tab)
        }
    }

    func clearMessage() {
        infoMessage = nil
        importErrorMessage = nil
        classificationStatusMessage = nil
    }

    func clearStartupMessage() {
        startupMessage = nil
    }

    func clearImportedLibrary(in context: ModelContext) throws -> LibraryResetSummary {
        try clearLibrary(in: context)
    }

    func clearLibrary(
        in context: ModelContext,
        includeTemplates: Bool = false
    ) throws -> LibraryResetSummary {
        importPreparationToken = UUID()
        isPreparingImport = false
        importDraft = nil
        currentImportRecord = nil
        clearMessage()

        let summary = try libraryResetService.clearLibrary(
            in: context,
            includeTemplates: includeTemplates
        )
        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
        return summary
    }

    @discardableResult
    func createManualSubscription(
        _ input: ManualSubscriptionInput,
        in context: ModelContext
    ) throws -> Subscription {
        let trimmedDisplayName = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = trimmedDisplayName.nilIfBlank ?? input.displayName
        let resolvedServiceIdentifier = input.serviceIdentifier?.nilIfBlank
            ?? ServiceLogoDatabase.suggestedIdentifier(
                displayName: trimmedDisplayName,
                canonicalName: canonicalName
            )
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let existing = subscriptions.first {
            $0.canonicalName.localizedCaseInsensitiveCompare(canonicalName) == .orderedSame
                || $0.displayName.localizedCaseInsensitiveCompare(trimmedDisplayName) == .orderedSame
        }

        let nextChargeDate = detector.predictNextCharge(
            from: input.lastChargeDate,
            cadence: input.cadence
        )
        let normalizedMonthlyAmount = detector.normalizeMonthly(
            price: input.priceAmount,
            cadence: input.cadence
        )

        let subscription = existing ?? Subscription(
            canonicalName: canonicalName,
            displayName: trimmedDisplayName,
            status: input.status,
            libraryState: input.status == .former ? .inactive : .manual,
            creationPath: .manual,
            cadence: input.cadence,
            priceAmount: input.priceAmount,
            priceCurrency: input.priceCurrency,
            normalizedMonthlyAmount: normalizedMonthlyAmount,
            lastChargeDate: input.lastChargeDate,
            predictedNextChargeDate: nextChargeDate,
            confidenceScore: 1,
            isUserConfirmed: true,
            serviceCategory: input.category?.nilIfBlank,
            detectionReason: "Created manually",
            notes: input.notes?.nilIfBlank,
            serviceIdentifier: resolvedServiceIdentifier,
            paymentMethodName: input.paymentMethodName?.nilIfBlank,
            websiteURL: input.websiteURL?.nilIfBlank,
            reminderDaysBefore: input.reminderDaysBefore,
            replacementSubscriptionID: input.replacementSubscriptionID
        )

        subscription.displayName = trimmedDisplayName
        subscription.status = input.status
        subscription.libraryState = input.status == .former ? .inactive : .manual
        subscription.creationPath = .manual
        subscription.cadence = input.cadence
        subscription.priceAmount = input.priceAmount
        subscription.priceCurrency = input.priceCurrency
        subscription.normalizedMonthlyAmount = normalizedMonthlyAmount
        subscription.lastChargeDate = input.lastChargeDate
        subscription.predictedNextChargeDate = nextChargeDate
        subscription.confidenceScore = 1
        subscription.isUserConfirmed = true
        subscription.serviceIdentifier = resolvedServiceIdentifier
        subscription.paymentMethodName = input.paymentMethodName?.nilIfBlank
        subscription.websiteURL = input.websiteURL?.nilIfBlank
        subscription.reminderDaysBefore = input.reminderDaysBefore
        subscription.replacementSubscriptionID = input.replacementSubscriptionID
        subscription.serviceCategory = input.category?.nilIfBlank
        subscription.detectionReason = "Created manually"
        subscription.notes = input.notes?.nilIfBlank

        if existing == nil {
            context.insert(subscription)
        }

        let manualEntries = try context.fetch(FetchDescriptor<ManualSubscription>())
        if manualEntries.contains(where: { $0.subscriptionID == subscription.id }) == false {
            context.insert(ManualSubscription(subscriptionID: subscription.id))
        }

        if context.hasChanges {
            try context.save()
        }

        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
        return subscription
    }

    /// Update an existing subscription in place (keyed by id, so a rename edits
    /// the same record rather than forking a new one the way the create upsert
    /// would). Recomputes the normalized monthly amount and next charge so
    /// calendar, insights, and reminders stay aligned.
    @discardableResult
    func updateManualSubscription(
        id: UUID,
        _ input: ManualSubscriptionInput,
        in context: ModelContext
    ) throws -> Subscription {
        guard let subscription = try subscription(withID: id, in: context) else {
            throw ManualSubscriptionEditError.missingSubscription
        }

        let trimmedDisplayName = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalName = trimmedDisplayName.nilIfBlank ?? input.displayName
        let resolvedServiceIdentifier = input.serviceIdentifier?.nilIfBlank
            ?? subscription.serviceIdentifier?.nilIfBlank
            ?? ServiceLogoDatabase.suggestedIdentifier(
                displayName: trimmedDisplayName,
                canonicalName: canonicalName
            )
        let nextChargeDate = detector.predictNextCharge(
            from: input.lastChargeDate,
            cadence: input.cadence
        )
        let normalizedMonthlyAmount = detector.normalizeMonthly(
            price: input.priceAmount,
            cadence: input.cadence
        )

        let isManualRecord = subscription.creationPath == .manual
            || subscription.libraryState == .manual
        let isUserConfirmedEdit = input.status != .needsReview

        // Only manual records own their canonical key. For a detected record the
        // canonical is the detector's merchant key; overwriting it with the display
        // name breaks merchant re-matching on the next import — removeStaleSubscriptions
        // indexes by canonicalName and deletes non-manual records whose canonical is
        // no longer seen, which would drop this edit and recreate the merchant as a
        // fresh suggestion. Rename the display only and leave the detector key stable.
        if isManualRecord {
            subscription.canonicalName = canonicalName
        }
        subscription.displayName = trimmedDisplayName
        subscription.status = input.status
        if !isManualRecord {
            subscription.libraryState = Subscription.libraryState(for: input.status)
        }
        subscription.cadence = input.cadence
        subscription.priceAmount = input.priceAmount
        subscription.priceCurrency = input.priceCurrency
        subscription.normalizedMonthlyAmount = normalizedMonthlyAmount
        subscription.lastChargeDate = input.lastChargeDate
        subscription.predictedNextChargeDate = nextChargeDate
        subscription.isUserConfirmed = isUserConfirmedEdit
        subscription.serviceIdentifier = resolvedServiceIdentifier
        subscription.paymentMethodName = input.paymentMethodName?.nilIfBlank
        subscription.websiteURL = input.websiteURL?.nilIfBlank
        subscription.reminderDaysBefore = input.reminderDaysBefore
        subscription.replacementSubscriptionID = input.replacementSubscriptionID
        subscription.serviceCategory = input.category?.nilIfBlank
        subscription.notes = input.notes?.nilIfBlank

        // A detected record's fields are re-derived from the detection summary on
        // every rebuild (applyDetectedSubscriptionFields uses the summary unless a
        // review-rule override exists), so a direct row edit here would silently
        // revert on the next import. Persist the edit as override fields keyed on the
        // stable detector canonical so the rebuild honors it. Manual records own their
        // row outright and are skipped by the rebuild, so they need no rule.
        if !isManualRecord {
            let rule = try fetchOrCreateReviewRule(
                canonicalName: subscription.canonicalName,
                in: context
            )
            rule.overrideDisplayName = trimmedDisplayName
            rule.overrideStatus = input.status
            rule.overrideCadence = input.cadence
            rule.overridePriceAmount = input.priceAmount
            rule.overridePriceCurrency = input.priceCurrency.nilIfBlank
            rule.overrideLastChargeDate = input.lastChargeDate
            rule.overrideCategory = input.category?.nilIfBlank
            rule.notes = input.notes?.nilIfBlank
            rule.isFalsePositive = false
            rule.isUserConfirmed = isUserConfirmedEdit
            rule.updatedAt = .now
        }

        if context.hasChanges {
            try context.save()
        }

        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
        return subscription
    }

    func cancelSubscription(
        id: UUID,
        in context: ModelContext
    ) throws {
        guard let subscription = try subscription(withID: id, in: context) else {
            throw ManualSubscriptionEditError.missingSubscription
        }

        let isManualRecord = subscription.creationPath == .manual
            || subscription.libraryState == .manual
        let syncedCalendarEventIdentifiers = [subscription.calendarEventIdentifier]
            .compactMap { $0?.nilIfBlank }

        subscription.status = .former
        subscription.isUserConfirmed = true
        subscription.lastNotificationScheduledAt = nil
        subscription.calendarEventIdentifier = nil
        subscription.lastCalendarSyncAt = nil

        if !isManualRecord {
            let rule = try fetchOrCreateReviewRule(
                canonicalName: subscription.canonicalName,
                in: context
            )
            rule.overrideStatus = .former
            rule.isFalsePositive = false
            rule.isUserConfirmed = true
            rule.updatedAt = .now
        }

        if context.hasChanges {
            try context.save()
        }

        RenewalNotificationService().clearScheduledNotifications(forSubscriptionIDs: [id])
        do {
            try clearSyncedCalendarEventsIfNeeded(identifiers: syncedCalendarEventIdentifiers)
        } catch {
            calendarEventCleanupFailureRecorder(syncedCalendarEventIdentifiers)
        }

        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
    }

    func removeSubscription(
        id: UUID,
        in context: ModelContext
    ) throws {
        guard let subscription = try subscription(withID: id, in: context) else {
            throw ManualSubscriptionEditError.missingSubscription
        }

        let isManualRecord = subscription.creationPath == .manual
            || subscription.libraryState == .manual
        let canonicalName = subscription.canonicalName
        let syncedCalendarEventIdentifiers = [subscription.calendarEventIdentifier]
            .compactMap { $0?.nilIfBlank }

        if !isManualRecord {
            let rule = try fetchOrCreateReviewRule(
                canonicalName: canonicalName,
                in: context
            )
            rule.overrideStatus = .former
            rule.isFalsePositive = true
            rule.isUserConfirmed = true
            rule.updatedAt = .now
            _ = try detector.recordUserCorrection(
                canonicalName: canonicalName,
                isSubscription: false,
                cadence: nil,
                in: context
            )
        }

        let linkedDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { transaction in
                transaction.subscriptionID == id
            }
        )
        for transaction in try context.fetch(linkedDescriptor) {
            transaction.subscriptionID = nil
        }

        context.delete(subscription)

        if context.hasChanges {
            try context.save()
        }

        RenewalNotificationService().clearScheduledNotifications(forSubscriptionIDs: [id])
        do {
            try clearSyncedCalendarEventsIfNeeded(identifiers: syncedCalendarEventIdentifiers)
        } catch {
            calendarEventCleanupFailureRecorder(syncedCalendarEventIdentifiers)
        }

        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
    }

    /// Review action: keep an AI-suggested subscription. Beyond moving it to
    /// `.confirmed` (active, out of the review queue), this teaches the detector
    /// the merchant is a real subscription via `applyMerchantLearning`, so the same
    /// decision is reapplied to future imports — matching the bulk
    /// (`applyAutomatedReviewDecision`) and copilot (`applyReviewUpdate`) paths.
    func confirmSuggestedSubscription(_ id: UUID, in context: ModelContext) {
        Task {
            do {
                guard let subscription = try subscription(withID: id, in: context) else { return }
                _ = try await applyMerchantLearning(
                    subscriptionID: id,
                    displayName: subscription.displayName,
                    status: reviewConfirmedStatus(for: subscription),
                    cadence: subscription.cadence == .unknown ? nil : subscription.cadence,
                    priceAmount: subscription.priceAmount,
                    priceCurrency: subscription.priceCurrency,
                    lastChargeDate: subscription.lastChargeDate,
                    category: subscription.serviceCategory,
                    notes: subscription.notes,
                    isUserConfirmed: true,
                    isFalsePositive: false,
                    applyAliasToFutureImports: false,
                    in: context
                )
                // Merchant-learning replay persists and refreshes the library and may
                // invalidate the original reference via the rebuild, so re-fetch and
                // pin the kept state if the subscription survived.
                if let kept = try self.subscription(withID: id, in: context) {
                    kept.libraryState = .confirmed
                    kept.isUserConfirmed = true
                    // Pin the inferred status last, after the merchant-learning
                    // rebuild, so a stale kept subscription stays archived (.former)
                    // instead of being reactivated to .active by the replay.
                    kept.status = reviewConfirmedStatus(for: kept)
                    try context.save()
                    advanceLibraryRevision()
                    scheduleSpotlightReindex(in: context)
                }
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    /// Review action: dismiss an AI-suggested subscription. Beyond hiding it via
    /// `.ignored`, this teaches the detector the merchant is a false positive via
    /// `applyMerchantLearning(isFalsePositive: true)`, so the same merchant is not
    /// re-detected as a subscription on the next import.
    func ignoreSuggestedSubscription(_ id: UUID, in context: ModelContext) {
        Task {
            do {
                guard let subscription = try subscription(withID: id, in: context) else { return }
                _ = try await applyMerchantLearning(
                    subscriptionID: id,
                    displayName: subscription.displayName,
                    status: .former,
                    cadence: .unknown,
                    priceAmount: nil,
                    priceCurrency: nil,
                    lastChargeDate: subscription.lastChargeDate,
                    category: nil,
                    notes: subscription.notes,
                    isUserConfirmed: true,
                    isFalsePositive: true,
                    applyAliasToFutureImports: false,
                    in: context
                )
                // Suppression replay teaches the false positive and deletes the
                // subscription as stale (already persisting + refreshing). Re-fetch:
                // only pin .ignored if it survived the rebuild — never mutate a
                // deleted object.
                if let surviving = try self.subscription(withID: id, in: context) {
                    surviving.libraryState = .ignored
                    try context.save()
                    advanceLibraryRevision()
                    scheduleSpotlightReindex(in: context)
                }
            } catch {
                importErrorMessage = error.localizedDescription
            }
        }
    }

    /// Review action: hide a suggestion that does not belong in this library
    /// without teaching Tally that the merchant is never a subscription.
    func hideSuggestedSubscription(_ id: UUID, in context: ModelContext) {
        do {
            guard let subscription = try subscription(withID: id, in: context) else { return }
            subscription.libraryState = .ignored
            var affectedImportRecordIDs = Set<UUID>()
            let linkedDescriptor = FetchDescriptor<NormalizedTransaction>(
                predicate: #Predicate { transaction in
                    transaction.subscriptionID == id
                }
            )
            let linkedTransactions = try context.fetch(linkedDescriptor)
            for transactions in hiddenSuggestionSuppressionGroups(from: linkedTransactions) {
                try persistHiddenSuggestionSuppression(
                    for: subscription,
                    transactions: transactions,
                    in: context
                )
            }
            for transaction in linkedTransactions {
                if let importRecordID = transaction.importRecordID {
                    affectedImportRecordIDs.insert(importRecordID)
                }
                transaction.subscriptionID = nil
            }
            try refreshNeedsReviewImportCounts(for: affectedImportRecordIDs, in: context)
            try context.save()
            advanceLibraryRevision()
            scheduleSpotlightReindex(in: context)
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func saveChangesAndRefreshSubscriptions(
        in context: ModelContext
    ) async throws -> SubscriptionDetectionReport {
        let startedAt = Date()
        if context.hasChanges {
            try context.save()
        }
        let report = try await detector.rebuildSubscriptions(in: context)
        try refreshImportSummaries(from: report, in: context)
        try context.save()
        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
        appActionsLogger.notice(
            """
            save_changes_and_refresh_subscriptions cluster_count=\(report.clusters.count, privacy: .public) \
            elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
            """
        )
        return report
    }

    func refreshImportSummaries(
        from report: SubscriptionDetectionReport,
        in context: ModelContext
    ) throws {
        let importRecords = try context.fetch(FetchDescriptor<ImportRecord>())
        for importRecord in importRecords {
            importRecord.apply(report.summary(for: importRecord.id))
        }
    }

    func persistHiddenSuggestionSuppression(
        for subscription: Subscription,
        transactions: [NormalizedTransaction],
        in context: ModelContext
    ) throws {
        guard transactions.isEmpty == false else {
            return
        }

        let canonicalName = subscription.canonicalName
        let rawMerchants = Set(transactions.map(\.merchantRaw).filter { $0.isEmpty == false })
        let accounts = Set(transactions.compactMap { $0.accountName?.nilIfBlank })
        let currencies = Set(transactions.compactMap { $0.currency?.nilIfBlank?.uppercased() })
        let sourceRawValues = Set(transactions.map(\.source.rawValue))
        let importRecordIDs = Set(transactions.compactMap(\.importRecordID))
        let amounts = transactions.map {
            abs(($0.transactionAmount as NSDecimalNumber).doubleValue)
        }
        let sortedAmounts = amounts.sorted()
        let hiddenScopeKey = hiddenSuggestionScopeKey(
            canonicalName: canonicalName,
            rawMerchants: rawMerchants,
            accounts: accounts,
            currencies: currencies,
            sourceRawValues: sourceRawValues,
            importRecordIDs: Set(importRecordIDs.map(\.uuidString)),
            amounts: sortedAmounts
        )
        let sourceRawValue = SubscriptionMatchRuleSource.hiddenSuggestion.rawValue
        let descriptor = FetchDescriptor<SubscriptionMatchRule>(
            predicate: #Predicate { rule in
                rule.canonicalName == canonicalName &&
                    rule.isNegativeRule == true &&
                    rule.createdFromRawValue == sourceRawValue
            }
        )
        let existingRule = try context.fetch(descriptor).first {
            $0.hiddenScopeKey == hiddenScopeKey
        }
        let rule = existingRule ?? SubscriptionMatchRule(
            canonicalName: canonicalName,
            isNegativeRule: true,
            createdFrom: .hiddenSuggestion,
            hiddenScopeKey: hiddenScopeKey
        )
        if existingRule == nil {
            context.insert(rule)
        }

        let sources = Set(transactions.map(\.source))

        rule.subscriptionID = nil
        rule.hiddenScopeKey = hiddenScopeKey
        rule.hiddenImportScope = importRecordIDs.isEmpty ? .allImports : .importRecords(importRecordIDs)
        rule.allowedRawMerchantsJSON = SubscriptionEvidenceJSON.encodeStrings(Array(rawMerchants).sorted())
        rule.requiredTokensJSON = SubscriptionEvidenceJSON.encodeStrings(
            subscription.canonicalName
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 }
                .prefix(3)
                .map { $0 }
        )
        rule.excludedTokensJSON = "[]"
        if let minAmount = sortedAmounts.first, let maxAmount = sortedAmounts.last {
            let tolerance = max(0.05, maxAmount * 0.02)
            rule.amountMinimum = Decimal(max(0, minAmount - tolerance))
            rule.amountMaximum = Decimal(maxAmount + tolerance)
            rule.amountMedian = Decimal(sortedAmounts[sortedAmounts.count / 2])
            rule.amountTolerancePercent = 0.02
        } else {
            rule.amountMinimum = nil
            rule.amountMaximum = nil
            rule.amountMedian = nil
        }
        rule.currencyCode = currencies.count == 1 ? currencies.first : nil
        rule.accountHint = accounts.count == 1 ? accounts.first : nil
        rule.sourceHint = sources.count == 1 ? sources.first : nil
        rule.scheduleExpectationID = nil
        rule.priority = 1_050
        rule.confidence = 0.96
        rule.isNegativeRule = true
        rule.createdFrom = .hiddenSuggestion
        rule.updatedAt = .now
    }

    func hiddenSuggestionSuppressionGroups(
        from transactions: [NormalizedTransaction]
    ) -> [[NormalizedTransaction]] {
        let grouped = Dictionary(grouping: transactions) { transaction in
            [
                transaction.accountName?.nilIfBlank ?? "missing-account",
                transaction.currency?.nilIfBlank?.uppercased() ?? "missing-currency",
                transaction.source.rawValue,
                transaction.importRecordID?.uuidString ?? "missing-import"
            ].joined(separator: "|")
        }
        return grouped.keys.sorted().compactMap { grouped[$0] }
    }

    func hiddenSuggestionScopeKey(
        canonicalName: String,
        rawMerchants: Set<String>,
        accounts: Set<String>,
        currencies: Set<String>,
        sourceRawValues: Set<String>,
        importRecordIDs: Set<String>,
        amounts: [Double]
    ) -> String {
        func component(_ label: String, _ values: Set<String>) -> String {
            let normalizedValues = values
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                        .replacingOccurrences(of: "|", with: "/")
                        .replacingOccurrences(of: ",", with: "/")
                }
                .filter { $0.isEmpty == false }
                .sorted()
            return "\(label)=\(normalizedValues.joined(separator: ","))"
        }

        let roundedAmounts = Set(amounts.map { String(format: "%.2f", $0) })
        return [
            component("canonical", [canonicalName]),
            component("raw", rawMerchants),
            component("account", accounts),
            component("currency", currencies),
            component("source", sourceRawValues),
            component("import", importRecordIDs),
            component("amount", roundedAmounts)
        ].joined(separator: "|")
    }

    func refreshNeedsReviewImportCounts(
        for importRecordIDs: Set<UUID>,
        in context: ModelContext
    ) throws {
        guard importRecordIDs.isEmpty == false else {
            return
        }

        let suggestedSubscriptionIDs = Set(
            try context.fetch(FetchDescriptor<Subscription>())
                .filter { $0.libraryState == .suggested }
                .map(\.id)
        )

        for importRecordID in importRecordIDs {
            let importDescriptor = FetchDescriptor<ImportRecord>(
                predicate: #Predicate { importRecord in
                    importRecord.id == importRecordID
                }
            )
            guard let importRecord = try context.fetch(importDescriptor).first else {
                continue
            }

            let transactionDescriptor = FetchDescriptor<NormalizedTransaction>(
                predicate: #Predicate { transaction in
                    transaction.importRecordID == importRecordID
                }
            )
            let reviewSubscriptionIDs = Set(
                try context.fetch(transactionDescriptor).compactMap { transaction -> UUID? in
                    guard let subscriptionID = transaction.subscriptionID,
                          suggestedSubscriptionIDs.contains(subscriptionID) else {
                        return nil
                    }
                    return subscriptionID
                }
            )
            importRecord.needsReviewSubscriptionCount = reviewSubscriptionIDs.count
        }
    }

    func saveChangesAndApplyReviewRuleLocally(
        canonicalName: String,
        subscriptionID: UUID?,
        in context: ModelContext
    ) async throws -> Subscription? {
        if context.hasChanges {
            try context.save()
        }

        let updatedSubscription = try applyReviewRuleLocally(
            canonicalName: canonicalName,
            subscriptionID: subscriptionID,
            in: context
        )

        try await replayReviewRuleLearningIfNeeded(
            canonicalName: canonicalName,
            subscriptionID: subscriptionID,
            updatedSubscription: updatedSubscription,
            in: context
        )

        if context.hasChanges {
            try context.save()
        }

        advanceLibraryRevision()
        scheduleSpotlightReindex(in: context)
        return updatedSubscription
    }

    func applyAliasDraft(
        rawMerchant: String,
        canonicalName: String,
        in context: ModelContext
    ) async throws -> String {
        let trimmedRawMerchant = rawMerchant.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCanonicalName = canonicalName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedRawMerchant.isEmpty == false, trimmedCanonicalName.isEmpty == false else {
            return "Missing merchant alias details."
        }

        let result = MerchantClassificationResult(
            canonicalName: trimmedCanonicalName,
            serviceCategory: "Subscription",
            merchantKind: .subscriptionService,
            subscriptionAffinity: 0.95,
            confidence: 1
        )
        try await replayMerchantResolution(
            for: [trimmedRawMerchant],
            preferredResults: [trimmedRawMerchant: result],
            in: context
        )
        return "Learned \(trimmedRawMerchant) → \(trimmedCanonicalName) and refreshed history."
    }

    func applyReviewUpdate(
        subscriptionID: UUID,
        fields: [String: String],
        in context: ModelContext
    ) async throws -> String {
        guard let subscription = try subscription(withID: subscriptionID, in: context) else {
            throw ReviewUpdateError.missingSubscription
        }

        let rule = try fetchOrCreateReviewRule(
            canonicalName: subscription.canonicalName,
            in: context
        )

        if let statusRawValue = fields["status"] {
            rule.overrideStatus = SubscriptionStatus(rawValue: statusRawValue)
        }
        if let displayName = fields["displayName"]?.nilIfBlank {
            rule.overrideDisplayName = displayName
        }
        if let category = fields["category"]?.nilIfBlank {
            rule.overrideCategory = category
        }
        if let notes = fields["notes"]?.nilIfBlank {
            rule.notes = notes
        }
        rule.updatedAt = .now

        _ = try await applyMerchantLearning(
            subscriptionID: subscription.id,
            displayName: rule.overrideDisplayName?.nilIfBlank ?? subscription.displayName,
            status: rule.overrideStatus ?? subscription.status,
            cadence: nil,
            priceAmount: nil,
            priceCurrency: nil,
            lastChargeDate: nil,
            category: rule.overrideCategory?.nilIfBlank ?? subscription.serviceCategory,
            notes: rule.notes?.nilIfBlank ?? subscription.notes?.nilIfBlank,
            isUserConfirmed: rule.isUserConfirmed || subscription.isUserConfirmed,
            isFalsePositive: rule.isFalsePositive,
            applyAliasToFutureImports: false,
            in: context
        )
        return "Applied review updates for \(subscription.displayName)."
    }

    func reviewAutomationPlan(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction]
    ) -> ReviewAutomationPlan {
        let reviewSubscriptions = subscriptions
            .filter { $0.libraryState == .suggested && $0.status == .needsReview }
            .sorted {
                if $0.confidenceScore == $1.confidenceScore {
                    return $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
                }
                return $0.confidenceScore > $1.confidenceScore
            }

        guard reviewSubscriptions.isEmpty == false else {
            return .empty
        }

        var confirmCandidates: [ReviewAutomationCandidate] = []
        var suppressCandidates: [ReviewAutomationCandidate] = []
        var manualCandidates: [ReviewAutomationCandidate] = []
        let transactionsBySubscriptionID = Dictionary(
            grouping: transactions.compactMap { transaction -> (UUID, NormalizedTransaction)? in
                guard let subscriptionID = transaction.subscriptionID else { return nil }
                return (subscriptionID, transaction)
            },
            by: \.0
        ).mapValues { pairs in pairs.map(\.1) }
        let transactionsByMerchant = Dictionary(grouping: transactions, by: \.merchantNormalized)
        let transactionsByRawMerchant = Dictionary(grouping: transactions, by: \.merchantRaw)

        for subscription in reviewSubscriptions {
            let linkedTransactions = transactionsBySubscriptionID[subscription.id]
                ?? transactionsByMerchant[subscription.canonicalName]
                ?? []
            let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
            let dominantKind = detector.dominantMerchantKind(for: linkedTransactions)
            let hasMerchantConflict = hasAutomationMerchantConflict(
                rawMerchants: rawMerchants,
                subscription: subscription,
                transactionsByRawMerchant: transactionsByRawMerchant
            )
            let candidate = automationCandidate(
                for: subscription,
                action: automationAction(
                    for: subscription,
                    linkedTransactions: linkedTransactions,
                    dominantMerchantKind: dominantKind,
                    hasMerchantConflict: hasMerchantConflict
                ),
                linkedTransactionCount: linkedTransactions.count,
                dominantMerchantKind: dominantKind
            )

            switch candidate.action {
            case .confirm:
                confirmCandidates.append(candidate)
            case .suppress:
                suppressCandidates.append(candidate)
            case .manual:
                manualCandidates.append(candidate)
            }
        }

        return ReviewAutomationPlan(
            totalReviewCount: reviewSubscriptions.count,
            confirmCandidates: confirmCandidates,
            suppressCandidates: suppressCandidates,
            manualCandidates: manualCandidates
        )
    }

    func reviewAutomationPlan(
        subscriptions: [Subscription],
        transactions: [NormalizedTransaction],
        scopedImportRecordID: UUID?
    ) -> ReviewAutomationPlan {
        guard let scopedImportRecordID else {
            return reviewAutomationPlan(subscriptions: subscriptions, transactions: transactions)
        }

        let scopedSubscriptionIDs = Set(transactions.compactMap { transaction in
            transaction.importRecordID == scopedImportRecordID ? transaction.subscriptionID : nil
        })
        guard scopedSubscriptionIDs.isEmpty == false else {
            return .empty
        }

        return reviewAutomationPlan(
            subscriptions: subscriptions.filter { scopedSubscriptionIDs.contains($0.id) },
            transactions: transactions.filter { transaction in
                transaction.subscriptionID.map { scopedSubscriptionIDs.contains($0) } ?? false
            }
        )
    }

    @discardableResult
    func applyAutomatedReviewDecisions(
        _ candidates: [ReviewAutomationCandidate],
        in context: ModelContext
    ) async throws -> ReviewAutomationResult {
        guard candidates.isEmpty == false else {
            return ReviewAutomationResult(confirmedCount: 0, suppressedCount: 0, skippedCount: 0)
        }

        let currentSubscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let currentTransactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let freshPlan = reviewAutomationPlan(
            subscriptions: currentSubscriptions,
            transactions: currentTransactions
        )
        let freshConfirmationsByID = Dictionary(
            uniqueKeysWithValues: freshPlan.confirmCandidates.map { ($0.subscriptionID, $0) }
        )
        let freshSuppressionsByID = Dictionary(
            uniqueKeysWithValues: freshPlan.suppressCandidates.map { ($0.subscriptionID, $0) }
        )

        var confirmedCount = 0
        var suppressedCount = 0
        var skippedCount = 0

        for candidate in candidates {
            let isFreshConfirmation = candidate.action == .confirm &&
                freshConfirmationsByID[candidate.subscriptionID]?.action == .confirm
            let isFreshSuppression = candidate.action == .suppress &&
                freshSuppressionsByID[candidate.subscriptionID]?.action == .suppress

            guard isFreshConfirmation || isFreshSuppression else {
                skippedCount += 1
                continue
            }

            guard let subscription = try subscription(withID: candidate.subscriptionID, in: context),
                  subscription.status == .needsReview else {
                skippedCount += 1
                continue
            }

            try await applyAutomatedReviewDecision(
                to: subscription,
                isFalsePositive: isFreshSuppression,
                in: context
            )

            if isFreshSuppression {
                suppressedCount += 1
            } else {
                confirmedCount += 1
            }
        }

        if confirmedCount > 0 || suppressedCount > 0 {
            await SubscriptionIntelligenceService.invalidateCachedEvaluations()
            _ = try await saveChangesAndRefreshSubscriptions(in: context)
        }

        return ReviewAutomationResult(
            confirmedCount: confirmedCount,
            suppressedCount: suppressedCount,
            skippedCount: skippedCount
        )
    }

    func merchantLearningPreview(
        for subscription: Subscription,
        proposedDisplayName: String,
        applyAliasToFutureImports: Bool,
        isFalsePositive: Bool,
        transactions: [NormalizedTransaction]
    ) -> MerchantLearningPreview {
        let linkedTransactions = linkedTransactions(
            for: subscription,
            in: transactions
        )
        let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
        let affectedTransactions = transactions.filter { rawMerchants.contains($0.merchantRaw) }
        return merchantLearningPreview(
            for: subscription,
            proposedDisplayName: proposedDisplayName,
            applyAliasToFutureImports: applyAliasToFutureImports,
            isFalsePositive: isFalsePositive,
            linkedTransactions: linkedTransactions,
            affectedTransactions: affectedTransactions
        )
    }

    func merchantLearningPreview(
        for subscription: Subscription,
        proposedDisplayName: String,
        applyAliasToFutureImports: Bool,
        isFalsePositive: Bool,
        linkedTransactions: [NormalizedTransaction],
        affectedTransactions: [NormalizedTransaction]
    ) -> MerchantLearningPreview {
        let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
        let targetCanonicalName = resolvedTargetCanonicalName(
            currentCanonicalName: subscription.canonicalName,
            proposedDisplayName: proposedDisplayName,
            applyAliasToFutureImports: applyAliasToFutureImports
        )
        let mode: MerchantLearningPreview.Mode
        if isFalsePositive {
            mode = .suppress
        } else if targetCanonicalName != subscription.canonicalName {
            mode = .rename
        } else {
            mode = .reinforce
        }

        return MerchantLearningPreview(
            mode: mode,
            sourceCanonicalName: subscription.canonicalName,
            targetCanonicalName: targetCanonicalName,
            rawMerchants: Array(rawMerchants).sorted(),
            affectedTransactionCount: affectedTransactions.count,
            affectedImportCount: Set(affectedTransactions.compactMap(\.importRecordID)).count
        )
    }

    @discardableResult
    func applyMerchantLearning(
        subscriptionID: UUID,
        displayName: String,
        status: SubscriptionStatus?,
        cadence: SubscriptionCadence?,
        priceAmount: Decimal?,
        priceCurrency: String?,
        lastChargeDate: Date?,
        category: String?,
        notes: String?,
        isUserConfirmed: Bool,
        isFalsePositive: Bool,
        applyAliasToFutureImports: Bool,
        in context: ModelContext
    ) async throws -> MerchantLearningPreview {
        guard let subscription = try subscription(withID: subscriptionID, in: context) else {
            throw ReviewUpdateError.missingSubscription
        }

        let linkedTransactions = try fetchLinkedTransactions(for: subscription, in: context)
        let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
        let affectedTransactions = try fetchTransactions(matchingRawMerchants: rawMerchants, in: context)
        let preview = merchantLearningPreview(
            for: subscription,
            proposedDisplayName: displayName,
            applyAliasToFutureImports: applyAliasToFutureImports,
            isFalsePositive: isFalsePositive,
            linkedTransactions: linkedTransactions,
            affectedTransactions: affectedTransactions
        )

        try validateCanonicalNameAvailability(
            preview: preview,
            subscriptionID: subscriptionID,
            in: context
        )

        let trimmedCategory = category?.nilIfBlank
        let resolvedCategory = trimmedCategory
            ?? subscription.serviceCategory?.nilIfBlank
            ?? defaultMerchantCategory(isFalsePositive: isFalsePositive)
        let resolvedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
            ?? subscription.displayName
        let resolvedLastChargeDate = lastChargeDate
            ?? subscription.lastChargeDate
            ?? linkedTransactions.max(by: { $0.transactionDate < $1.transactionDate })?.transactionDate
        let resolvedPriceCurrency = priceCurrency?.nilIfBlank
            ?? (priceAmount == nil ? nil : subscription.priceCurrency.nilIfBlank)

        let rule = try fetchOrCreateReviewRule(
            canonicalName: subscription.canonicalName,
            in: context
        )
        rule.canonicalName = preview.targetCanonicalName
        rule.overrideDisplayName = resolvedDisplayName == preview.targetCanonicalName ? nil : resolvedDisplayName
        rule.overrideStatus = status
        rule.overrideCadence = cadence
        rule.overridePriceAmount = priceAmount
        rule.overridePriceCurrency = isFalsePositive ? nil : resolvedPriceCurrency
        rule.overrideLastChargeDate = resolvedLastChargeDate
        rule.overrideCategory = resolvedCategory
        rule.notes = notes?.nilIfBlank
        rule.isUserConfirmed = isUserConfirmed
        rule.isFalsePositive = isFalsePositive
        rule.updatedAt = .now
        _ = try detector.recordUserCorrection(
            canonicalName: preview.targetCanonicalName,
            isSubscription: !isFalsePositive,
            cadence: isFalsePositive ? nil : cadence,
            in: context
        )

        subscription.canonicalName = preview.targetCanonicalName
        await SubscriptionIntelligenceService.invalidateCachedEvaluations()

        let classification = MerchantClassificationResult(
            canonicalName: preview.targetCanonicalName,
            serviceCategory: resolvedCategory,
            merchantKind: learnedMerchantKind(
                for: linkedTransactions,
                isFalsePositive: isFalsePositive
            ),
            subscriptionAffinity: isFalsePositive ? 0.02 : 0.98,
            confidence: 1
        )

        try await replayMerchantResolution(
            for: rawMerchants,
            preferredResults: Dictionary(
                uniqueKeysWithValues: rawMerchants.map { rawMerchant in
                    (rawMerchant, classification)
                }
            ),
            in: context
        )

        return preview
    }

    func subscription(withID id: UUID, in context: ModelContext) throws -> Subscription? {
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { item in
                item.id == id
            }
        )

        return try context.fetch(descriptor).first
    }

    func subscription(
        canonicalName: String,
        in context: ModelContext
    ) throws -> Subscription? {
        let descriptor = FetchDescriptor<Subscription>(
            predicate: #Predicate { item in
                item.canonicalName == canonicalName
            }
        )

        return try context.fetch(descriptor).first
    }

    func fetchOrCreateReviewRule(
        canonicalName: String,
        in context: ModelContext
    ) throws -> SubscriptionReviewRule {
        let descriptor = FetchDescriptor<SubscriptionReviewRule>(
            predicate: #Predicate { item in
                item.canonicalName == canonicalName
            }
        )

        if let existing = try context.fetch(descriptor).first {
            return existing
        }

        let created = SubscriptionReviewRule(canonicalName: canonicalName)
        context.insert(created)
        return created
    }

    func applyReviewRuleLocally(
        canonicalName: String,
        subscriptionID: UUID?,
        in context: ModelContext
    ) throws -> Subscription? {
        let descriptor = FetchDescriptor<SubscriptionReviewRule>(
            predicate: #Predicate { item in
                item.canonicalName == canonicalName
            }
        )
        guard let rule = try context.fetch(descriptor).first else {
            if let subscriptionID,
               let subscription = try subscription(withID: subscriptionID, in: context) {
                return subscription
            }
            return try subscription(canonicalName: canonicalName, in: context)
        }

        if rule.isUserConfirmed || rule.isFalsePositive {
            _ = try detector.recordUserCorrection(
                canonicalName: canonicalName,
                isSubscription: !rule.isFalsePositive,
                cadence: rule.isFalsePositive ? nil : rule.overrideCadence,
                in: context
            )
        }

        guard rule.isFalsePositive == false else {
            return nil
        }

        let existingSubscription: Subscription?
        if let subscriptionID,
           let subscription = try subscription(withID: subscriptionID, in: context) {
            existingSubscription = subscription
        } else {
            existingSubscription = try subscription(canonicalName: canonicalName, in: context)
        }

        if let manualSubscription = detector.manualSubscription(from: rule, existing: existingSubscription) {
            if existingSubscription == nil {
                context.insert(manualSubscription)
            }
            return manualSubscription
        }

        guard let subscription = existingSubscription else {
            return nil
        }

        let resolvedCadence = rule.overrideCadence ?? subscription.cadence
        let resolvedPrice = rule.overridePriceAmount ?? subscription.priceAmount
        let resolvedPriceCurrency = rule.overridePriceCurrency?.nilIfBlank ?? subscription.priceCurrency
        let resolvedLastChargeDate = rule.overrideLastChargeDate ?? subscription.lastChargeDate

        subscription.displayName = rule.overrideDisplayName?.nilIfBlank ?? canonicalName
        subscription.status = rule.overrideStatus ?? subscription.status
        subscription.cadence = resolvedCadence
        subscription.priceAmount = resolvedPrice
        subscription.priceCurrency = resolvedPriceCurrency
        subscription.lastChargeDate = resolvedLastChargeDate
        subscription.normalizedMonthlyAmount = detector.normalizeMonthly(
            price: resolvedPrice,
            cadence: resolvedCadence
        )
        subscription.predictedNextChargeDate = detector.predictNextCharge(
            from: resolvedLastChargeDate,
            cadence: resolvedCadence
        )
        subscription.serviceCategory = rule.overrideCategory?.nilIfBlank ?? subscription.serviceCategory
        subscription.notes = rule.notes?.nilIfBlank
        subscription.isUserConfirmed = rule.isUserConfirmed
        return subscription
    }

    func reviewConfirmedStatus(for subscription: Subscription) -> SubscriptionStatus {
        reviewConfirmedStatus(
            lastChargeDate: subscription.lastChargeDate,
            cadence: subscription.cadence,
            fallbackNextChargeDate: subscription.predictedNextChargeDate
        )
    }

    func reviewConfirmedStatus(
        lastChargeDate: Date?,
        cadence: SubscriptionCadence,
        fallbackNextChargeDate: Date? = nil
    ) -> SubscriptionStatus {
        let nextCharge = detector.predictNextCharge(from: lastChargeDate, cadence: cadence)
            ?? fallbackNextChargeDate
        guard let nextCharge else {
            return .active
        }

        let calendar = Calendar.current
        let staleCutoff = calendar.date(
            byAdding: .day,
            value: -cadence.renewalGraceWindowDays,
            to: calendar.startOfDay(for: .now)
        ) ?? .distantPast
        if nextCharge >= staleCutoff {
            return .active
        }

        guard cadence.allowsSecondMissTolerance,
              let followingChargeDate = cadence.advance(nextCharge, using: calendar) else {
            return .former
        }
        return followingChargeDate >= staleCutoff ? .active : .former
    }
}

private extension AppModel {
    func validateCanonicalNameAvailability(
        preview: MerchantLearningPreview,
        subscriptionID: UUID,
        in context: ModelContext
    ) throws {
        guard preview.mode == .rename else {
            return
        }

        let targetCanonicalName = preview.targetCanonicalName.localizedLowercase
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        if subscriptions.contains(where: {
            $0.id != subscriptionID && $0.canonicalName.localizedLowercase == targetCanonicalName
        }) {
            throw ReviewUpdateError.canonicalNameConflict(preview.targetCanonicalName)
        }

        let rules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
        if rules.contains(where: {
            $0.canonicalName.localizedLowercase == targetCanonicalName
        }) {
            throw ReviewUpdateError.canonicalNameConflict(preview.targetCanonicalName)
        }
    }

    func fetchLinkedTransactions(
        for subscription: Subscription,
        in context: ModelContext
    ) throws -> [NormalizedTransaction] {
        let subscriptionID = subscription.id
        let linkedDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { transaction in
                transaction.subscriptionID == subscriptionID
            },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        let linked = try context.fetch(linkedDescriptor)
        if linked.isEmpty == false {
            return linked
        }

        let canonicalName = subscription.canonicalName
        let canonicalDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { transaction in
                transaction.merchantNormalized == canonicalName
            },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        return try context.fetch(canonicalDescriptor)
    }

    func fetchTransactions(
        matchingRawMerchants rawMerchants: Set<String>,
        in context: ModelContext
    ) throws -> [NormalizedTransaction] {
        let rawMerchantNames = rawMerchants
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard rawMerchantNames.isEmpty == false else {
            return []
        }

        if rawMerchantNames.count > 25 {
            let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
            let rawMerchantSet = Set(rawMerchantNames)
            return transactions.filter { rawMerchantSet.contains($0.merchantRaw) }
        }

        var transactions: [NormalizedTransaction] = []
        for rawMerchant in rawMerchantNames {
            let descriptor = FetchDescriptor<NormalizedTransaction>(
                predicate: #Predicate { transaction in
                    transaction.merchantRaw == rawMerchant
                },
                sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
            )
            transactions.append(contentsOf: try context.fetch(descriptor))
        }
        return transactions
    }

    func fetchTransactions(
        subscriptionID: UUID,
        canonicalName: String,
        in context: ModelContext
    ) throws -> [NormalizedTransaction] {
        let linkedDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { transaction in
                transaction.subscriptionID == subscriptionID
            },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        let linked = try context.fetch(linkedDescriptor)
        let canonical = try fetchTransactions(canonicalName: canonicalName, in: context)
        guard linked.isEmpty == false else {
            return canonical
        }

        var seenIDs = Set(linked.map(\.id))
        var merged = linked
        for transaction in canonical where seenIDs.insert(transaction.id).inserted {
            merged.append(transaction)
        }
        return merged.sorted { $0.transactionDate > $1.transactionDate }
    }

    func fetchTransactions(
        canonicalName: String,
        in context: ModelContext
    ) throws -> [NormalizedTransaction] {
        let descriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { transaction in
                transaction.merchantNormalized == canonicalName
            },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    func replayReviewRuleLearningIfNeeded(
        canonicalName: String,
        subscriptionID: UUID?,
        updatedSubscription: Subscription?,
        in context: ModelContext
    ) async throws {
        let descriptor = FetchDescriptor<SubscriptionReviewRule>(
            predicate: #Predicate { item in
                item.canonicalName == canonicalName
            }
        )
        guard let rule = try context.fetch(descriptor).first else {
            return
        }
        guard rule.isUserConfirmed || rule.isFalsePositive else {
            return
        }

        await SubscriptionIntelligenceService.invalidateCachedEvaluations()

        let relevantTransactions: [NormalizedTransaction]
        if let updatedSubscription {
            relevantTransactions = try fetchLinkedTransactions(for: updatedSubscription, in: context)
        } else if let subscriptionID {
            relevantTransactions = try fetchTransactions(subscriptionID: subscriptionID, canonicalName: canonicalName, in: context)
        } else {
            relevantTransactions = try fetchTransactions(canonicalName: canonicalName, in: context)
        }

        let rawMerchants = Set(relevantTransactions.map(\.merchantRaw))
        guard rawMerchants.isEmpty == false else {
            return
        }

        let resolvedCategory = rule.overrideCategory?.nilIfBlank
            ?? updatedSubscription?.serviceCategory?.nilIfBlank
            ?? defaultMerchantCategory(isFalsePositive: rule.isFalsePositive)
        let classification = MerchantClassificationResult(
            canonicalName: canonicalName,
            serviceCategory: resolvedCategory,
            merchantKind: learnedMerchantKind(
                for: relevantTransactions,
                isFalsePositive: rule.isFalsePositive
            ),
            subscriptionAffinity: rule.isFalsePositive ? 0.02 : 0.98,
            confidence: 1
        )

        try await replayMerchantResolution(
            for: rawMerchants,
            preferredResults: Dictionary(
                uniqueKeysWithValues: rawMerchants.map { rawMerchant in
                    (rawMerchant, classification)
                }
            ),
            forceRefresh: true,
            in: context
        )
    }

    func replayMerchantResolution(
        for rawMerchants: Set<String>,
        preferredResults: [String: MerchantClassificationResult]?,
        forceRefresh: Bool = false,
        in context: ModelContext
    ) async throws {
        let startedAt = Date()
        guard rawMerchants.isEmpty == false else {
            _ = try await saveChangesAndRefreshSubscriptions(in: context)
            appActionsLogger.notice("replay_merchant_resolution skipped_empty_raw_merchants")
            return
        }

        let affectedTransactions = try fetchTransactions(matchingRawMerchants: rawMerchants, in: context)
        guard affectedTransactions.isEmpty == false else {
            _ = try await saveChangesAndRefreshSubscriptions(in: context)
            appActionsLogger.notice(
                """
                replay_merchant_resolution no_affected_transactions raw_merchant_count=\(rawMerchants.count, privacy: .public)
                """
            )
            return
        }

        let results: [String: MerchantClassificationResult]
        if let preferredResults {
            results = preferredResults
            for (rawMerchant, classification) in preferredResults {
                try upsertAlias(rawMerchant: rawMerchant, canonicalName: classification.canonicalName, in: context)
                try upsertClassification(rawMerchant: rawMerchant, result: classification, in: context)
            }
        } else {
            let seeds = affectedTransactions.map(\.classificationSeed)
            let loadResult = try await loadClassifications(
                for: seeds,
                context: context,
                forceRefresh: forceRefresh
            )
            results = loadResult.results
        }

        for transaction in affectedTransactions {
            guard let classification = results[transaction.merchantRaw] else {
                continue
            }
            transaction.merchantNormalized = classification.canonicalName
            transaction.merchantKind = classification.merchantKind
            transaction.merchantSubscriptionAffinity = classification.subscriptionAffinity
            transaction.classificationConfidence = classification.confidence
            if classification.confidence >= 0.95 ||
                transaction.category?.nilIfBlank == nil ||
                transaction.category == "Uncategorized" {
                transaction.category = classification.serviceCategory.nilIfBlank ?? transaction.category
            }
        }

        _ = try await saveChangesAndRefreshSubscriptions(in: context)
        appActionsLogger.notice(
            """
            replay_merchant_resolution raw_merchant_count=\(rawMerchants.count, privacy: .public) \
            affected_transactions=\(affectedTransactions.count, privacy: .public) \
            preferred_results=\(preferredResults?.count ?? 0, privacy: .public) \
            force_refresh=\(forceRefresh, privacy: .public) \
            elapsed_ms=\(startedAt.distance(to: .now) * 1000, format: .fixed(precision: 2), privacy: .public)
            """
        )
    }

    func upsertAlias(
        rawMerchant: String,
        canonicalName: String,
        in context: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<MerchantAlias>(
            predicate: #Predicate { alias in
                alias.rawMerchant == rawMerchant
            }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.canonicalName = canonicalName
        } else {
            context.insert(
                MerchantAlias(
                    rawMerchant: rawMerchant,
                    canonicalName: canonicalName
                )
            )
        }
    }

    func upsertClassification(
        rawMerchant: String,
        result: MerchantClassificationResult,
        in context: ModelContext
    ) throws {
        let descriptor = FetchDescriptor<MerchantClassification>(
            predicate: #Predicate { classification in
                classification.rawMerchant == rawMerchant
            }
        )

        if let existing = try context.fetch(descriptor).first {
            existing.canonicalName = result.canonicalName
            existing.serviceCategory = result.serviceCategory
            existing.merchantKind = result.merchantKind
            existing.subscriptionAffinity = result.subscriptionAffinity
            existing.confidence = result.confidence
            existing.isUserCorrected = true
            existing.lastUpdatedAt = .now
        } else {
            context.insert(
                MerchantClassification(
                    rawMerchant: rawMerchant,
                    result: result,
                    isUserCorrected: true
                )
            )
        }
    }

    func linkedTransactions(
        for subscription: Subscription,
        in transactions: [NormalizedTransaction]
    ) -> [NormalizedTransaction] {
        let linked = transactions.filter { $0.subscriptionID == subscription.id }
        if linked.isEmpty == false {
            return linked
        }

        return transactions.filter { $0.merchantNormalized == subscription.canonicalName }
    }

    func automationAction(
        for subscription: Subscription,
        linkedTransactions: [NormalizedTransaction],
        dominantMerchantKind: MerchantKind,
        hasMerchantConflict: Bool
    ) -> ReviewAutomationAction {
        guard hasMerchantConflict == false,
              linkedTransactions.isEmpty == false else {
            return .manual
        }

        let linkedCount = linkedTransactions.count
        let hasResolvedCadence = subscription.cadence != .unknown
        let hasUsablePrice = subscription.priceAmount > 0
        let hasRenewalAnchor = subscription.lastChargeDate != nil
            || subscription.predictedNextChargeDate != nil
        let looksLikeSubscription = dominantMerchantKind.isUsuallyNonSubscription == false
            || subscription.serviceCategory?.localizedCaseInsensitiveContains("subscription") == true
            || subscription.serviceCategory?.localizedCaseInsensitiveContains("software") == true
            || subscription.serviceCategory?.localizedCaseInsensitiveContains("streaming") == true
        let looksLikeFinancialMovement = linkedTransactions.isEmpty == false &&
            linkedTransactions.allSatisfy(detector.isFinancialMovement) &&
            linkedTransactions.contains(where: detector.hasStrongSubscriptionWording) == false

        if looksLikeFinancialMovement {
            return .suppress
        }

        let looksLikeBillOrCommerceStream = linkedTransactions.isEmpty == false &&
            linkedTransactions.allSatisfy { transaction in
                detector.isRecurringBillOrNonSubscriptionSpend(transaction) ||
                detector.hasCommerceNoiseSignals(transaction)
            } &&
            linkedTransactions.contains(where: detector.hasExplicitSubscriptionKeywords) == false

        if looksLikeBillOrCommerceStream {
            return .suppress
        }

        let looksLikeKnownSubscriptionService = linkedTransactions.isEmpty == false &&
            linkedTransactions.filter(detector.hasKnownSubscriptionServiceSignal).count >= max(1, linkedCount - 1)

        if subscription.confidenceScore >= 0.62,
           linkedCount >= 2,
           hasResolvedCadence,
           hasUsablePrice,
           hasRenewalAnchor,
           looksLikeKnownSubscriptionService {
            return .confirm
        }

        if subscription.confidenceScore >= 0.82,
           linkedCount >= 2,
           hasResolvedCadence,
           hasUsablePrice,
           hasRenewalAnchor,
           looksLikeSubscription {
            return .confirm
        }

        if subscription.confidenceScore <= 0.32,
           linkedCount <= 2,
           dominantMerchantKind.isUsuallyNonSubscription {
            return .suppress
        }

        return .manual
    }

    func hasAutomationMerchantConflict(
        rawMerchants: Set<String>,
        subscription: Subscription,
        transactionsByRawMerchant: [String: [NormalizedTransaction]]
    ) -> Bool {
        rawMerchants.contains { rawMerchant in
            transactionsByRawMerchant[rawMerchant, default: []].contains { transaction in
                if let transactionSubscriptionID = transaction.subscriptionID,
                   transactionSubscriptionID != subscription.id {
                    return true
                }
                return false
            }
        }
    }

    func automationCandidate(
        for subscription: Subscription,
        action: ReviewAutomationAction,
        linkedTransactionCount: Int,
        dominantMerchantKind: MerchantKind
    ) -> ReviewAutomationCandidate {
        let reason: String
        switch action {
        case .confirm:
            reason = "High confidence, repeated charge pattern, known cadence."
        case .suppress:
            reason = "Low confidence and merchant looks like \(dominantMerchantKind.title.lowercased())."
        case .manual:
            reason = manualAutomationReason(
                for: subscription,
                linkedTransactionCount: linkedTransactionCount,
                dominantMerchantKind: dominantMerchantKind
            )
        }

        return ReviewAutomationCandidate(
            subscriptionID: subscription.id,
            displayName: subscription.displayName,
            action: action,
            reason: reason,
            confidenceScore: subscription.confidenceScore,
            linkedTransactionCount: linkedTransactionCount,
            monthlyAmount: subscription.normalizedMonthlyAmount,
            currencyCode: subscription.priceCurrency
        )
    }

    func manualAutomationReason(
        for subscription: Subscription,
        linkedTransactionCount: Int,
        dominantMerchantKind: MerchantKind
    ) -> String {
        if linkedTransactionCount == 0 {
            return "No linked charges to teach from yet."
        }
        if subscription.cadence == .unknown {
            return "Cadence is still unknown."
        }
        if subscription.priceAmount <= 0 {
            return "Price needs correction."
        }
        if subscription.confidenceScore < 0.82 && subscription.confidenceScore > 0.32 {
            return "Confidence is borderline."
        }
        if dominantMerchantKind.isUsuallyNonSubscription {
            return "Merchant type needs a human check."
        }
        return "Needs a human check before applying a lasting rule."
    }

    func applyAutomatedReviewDecision(
        to subscription: Subscription,
        isFalsePositive: Bool,
        in context: ModelContext
    ) async throws {
        let originalCanonicalName = subscription.canonicalName
        let linkedTransactions = try fetchLinkedTransactions(for: subscription, in: context)
        let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
        let learnedCanonicalName = try learnedCanonicalName(
            for: subscription,
            isFalsePositive: isFalsePositive,
            in: context
        )
        let resolvedCategory = subscription.serviceCategory?.nilIfBlank
            ?? defaultMerchantCategory(isFalsePositive: isFalsePositive)
        let resolvedCadence = isFalsePositive ? SubscriptionCadence.unknown : subscription.cadence
        let resolvedLastChargeDate = subscription.lastChargeDate
            ?? linkedTransactions.max(by: { $0.transactionDate < $1.transactionDate })?.transactionDate
        let resolvedStatus = isFalsePositive
            ? SubscriptionStatus.former
            : reviewConfirmedStatus(lastChargeDate: resolvedLastChargeDate, cadence: resolvedCadence)
        let rule = try fetchOrCreateReviewRule(canonicalName: learnedCanonicalName, in: context)

        rule.overrideDisplayName = nil
        rule.overrideStatus = resolvedStatus
        rule.overrideCadence = resolvedCadence == .unknown ? nil : resolvedCadence
        rule.overridePriceAmount = isFalsePositive ? nil : subscription.priceAmount
        rule.overridePriceCurrency = isFalsePositive ? nil : subscription.priceCurrency.nilIfBlank
        rule.overrideLastChargeDate = resolvedLastChargeDate
        rule.overrideCategory = resolvedCategory
        rule.notes = subscription.notes?.nilIfBlank
        rule.isUserConfirmed = true
        rule.isFalsePositive = isFalsePositive
        rule.updatedAt = .now

        _ = try detector.recordUserCorrection(
            canonicalName: learnedCanonicalName,
            isSubscription: !isFalsePositive,
            cadence: isFalsePositive ? nil : resolvedCadence,
            in: context
        )

        if originalCanonicalName != learnedCanonicalName {
            try removeReviewLearning(canonicalName: originalCanonicalName, in: context)
        }

        subscription.canonicalName = learnedCanonicalName
        if originalCanonicalName != learnedCanonicalName {
            subscription.displayName = learnedCanonicalName
        }
        subscription.status = resolvedStatus
        subscription.cadence = resolvedCadence
        subscription.lastChargeDate = resolvedLastChargeDate
        subscription.predictedNextChargeDate = detector.predictNextCharge(
            from: resolvedLastChargeDate,
            cadence: resolvedCadence
        )
        subscription.normalizedMonthlyAmount = detector.normalizeMonthly(
            price: subscription.priceAmount,
            cadence: resolvedCadence
        )
        subscription.isUserConfirmed = true
        subscription.serviceCategory = resolvedCategory
        subscription.detectionReason = isFalsePositive
            ? "Suppressed by review automation"
            : "Confirmed by review automation"

        let classification = MerchantClassificationResult(
            canonicalName: learnedCanonicalName,
            serviceCategory: resolvedCategory,
            merchantKind: learnedMerchantKind(
                for: linkedTransactions,
                isFalsePositive: isFalsePositive
            ),
            subscriptionAffinity: isFalsePositive ? 0.02 : 0.98,
            confidence: 1
        )

        for rawMerchant in rawMerchants {
            try upsertAlias(rawMerchant: rawMerchant, canonicalName: learnedCanonicalName, in: context)
            try upsertClassification(rawMerchant: rawMerchant, result: classification, in: context)
        }

        for transaction in try fetchTransactions(matchingRawMerchants: rawMerchants, in: context) {
            transaction.merchantNormalized = learnedCanonicalName
            transaction.merchantKind = classification.merchantKind
            transaction.merchantSubscriptionAffinity = classification.subscriptionAffinity
            transaction.classificationConfidence = classification.confidence
            if transaction.category?.nilIfBlank == nil || transaction.category == "Uncategorized" {
                transaction.category = resolvedCategory
            }
        }
    }

    func learnedCanonicalName(
        for subscription: Subscription,
        isFalsePositive: Bool,
        in context: ModelContext
    ) throws -> String {
        let fallback = stableSubscriptionName(from: subscription.canonicalName)
        guard isFalsePositive == false else {
            return fallback
        }

        if let existing = try self.subscription(canonicalName: fallback, in: context),
           existing.id != subscription.id {
            return subscription.canonicalName
        }
        return fallback
    }

    private static let trailingAmountRegex = try? NSRegularExpression(
        pattern: #"(\s+\$?\d+(?:[.,]\d{2})?)+$"#
    )

    func stableSubscriptionName(from name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = Self.trailingAmountRegex else { return trimmed }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let stripped = regex.stringByReplacingMatches(
            in: trimmed,
            range: range,
            withTemplate: ""
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank ?? trimmed
    }

    func removeReviewLearning(
        canonicalName: String,
        in context: ModelContext
    ) throws {
        let rules = try context.fetch(
            FetchDescriptor<SubscriptionReviewRule>(
                predicate: #Predicate { rule in
                    rule.canonicalName == canonicalName
                }
            )
        )
        for rule in rules {
            context.delete(rule)
        }

        let corrections = try context.fetch(
            FetchDescriptor<MerchantCorrection>(
                predicate: #Predicate { correction in
                    correction.canonicalName == canonicalName
                }
            )
        )
        for correction in corrections {
            context.delete(correction)
        }
    }

    func resolvedTargetCanonicalName(
        currentCanonicalName: String,
        proposedDisplayName: String,
        applyAliasToFutureImports: Bool
    ) -> String {
        let trimmedDisplayName = proposedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard applyAliasToFutureImports, trimmedDisplayName.isEmpty == false else {
            return currentCanonicalName
        }
        return trimmedDisplayName
    }

    func learnedMerchantKind(
        for transactions: [NormalizedTransaction],
        isFalsePositive: Bool
    ) -> MerchantKind {
        let dominantKind = detector.dominantMerchantKind(for: transactions)
        if isFalsePositive {
            return dominantKind.isUsuallyNonSubscription ? dominantKind : .generalRetail
        }

        if dominantKind == .unknown || dominantKind.isUsuallyNonSubscription {
            return .subscriptionService
        }
        return dominantKind
    }

    func defaultMerchantCategory(isFalsePositive: Bool) -> String {
        isFalsePositive ? "Uncategorized" : "Subscription"
    }

}
