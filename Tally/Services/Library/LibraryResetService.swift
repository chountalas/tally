import Foundation
import SwiftData

struct LibraryResetSummary {
    let importCount: Int
    let transactionCount: Int
    let subscriptionCount: Int
    let classificationCount: Int
    let aliasCount: Int
    let reviewRuleCount: Int
    let templateCount: Int

    var importedDataMessage: String {
        let clearedItems = [
            summaryLabel(for: importCount, singular: "import"),
            summaryLabel(for: transactionCount, singular: "transaction"),
            summaryLabel(for: subscriptionCount, singular: "subscription")
        ].joined(separator: ", ")

        return
            "Cleared \(clearedItems). Aliases, classifications, and review " +
            "rules were also reset so you can import a fresh CSV."
    }

    var fullLibraryMessage: String {
        let deletedItems = [
            summaryLabel(for: importCount, singular: "import"),
            summaryLabel(for: transactionCount, singular: "transaction"),
            summaryLabel(for: subscriptionCount, singular: "subscription"),
            summaryLabel(for: classificationCount, singular: "classification"),
            summaryLabel(for: aliasCount, singular: "alias", plural: "aliases"),
            summaryLabel(for: reviewRuleCount, singular: "review rule")
        ].joined(separator: ", ")

        var message = "Deleted \(deletedItems)."

        if templateCount > 0 {
            message += " Also removed \(summaryLabel(for: templateCount, singular: "column template"))."
        }

        return message
    }

    private func summaryLabel(for count: Int, singular: String, plural: String? = nil) -> String {
        if count == 1 {
            return "1 \(singular)"
        }

        return "\(count) \(plural ?? "\(singular)s")"
    }
}

@MainActor
final class LibraryResetService {
    private let notificationService: RenewalNotificationService
    private let calendarEventCleaner: ([Subscription], ModelContext) throws -> Void
    private let pendingCalendarEventRecorder: ([String]) -> Void

    init(
        calendarService: RenewalCalendarService = RenewalCalendarService(),
        notificationService: RenewalNotificationService = RenewalNotificationService(),
        calendarEventCleaner: (([Subscription], ModelContext) throws -> Void)? = nil,
        pendingCalendarEventRecorder: @escaping ([String]) -> Void = { identifiers in
            PendingCalendarEventCleanupStore.record(identifiers)
        }
    ) {
        self.notificationService = notificationService
        self.calendarEventCleaner = calendarEventCleaner ?? { subscriptions, context in
            try calendarService.clearSyncedEvents(for: subscriptions, context: context)
        }
        self.pendingCalendarEventRecorder = pendingCalendarEventRecorder
    }

    func clearLibrary(in context: ModelContext, includeTemplates: Bool = false) throws -> LibraryResetSummary {
        let imports = try context.fetch(FetchDescriptor<ImportRecord>())
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let classifications = try context.fetch(FetchDescriptor<MerchantClassification>())
        let aliases = try context.fetch(FetchDescriptor<MerchantAlias>())
        let reviewRules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>())
        let templates = includeTemplates ? try context.fetch(FetchDescriptor<ColumnMappingTemplate>()) : []

        do {
            try calendarEventCleaner(subscriptions, context)
        } catch RenewalCalendarError.accessDenied {
            // Local subscription state is about to be deleted, so cleanup failure should not block the reset.
            pendingCalendarEventRecorder(subscriptions.compactMap(\.calendarEventIdentifier))
        }

        do {
            try notificationService.clearScheduledNotifications(for: subscriptions, context: context)
        } catch RenewalNotificationError.accessDenied {
            // Local subscription state is about to be deleted, so cleanup failure should not block the reset.
        }

        // Delete every library model so a reset is a true clean slate. Anything
        // left behind (suppressions, dedup identities, detection evidence) would
        // silently carry over — e.g. a merchant the user suppressed before the
        // reset would stay suppressed. `ColumnMappingTemplate` is the one
        // exception, gated by `includeTemplates`, so a plain "clear imported
        // data" keeps the user's saved column mappings.
        try context.delete(model: Subscription.self)
        try context.delete(model: NormalizedTransaction.self)
        try context.delete(model: ImportRecord.self)
        try context.delete(model: MerchantClassification.self)
        try context.delete(model: MerchantCorrection.self)
        try context.delete(model: MerchantAlias.self)
        try context.delete(model: SubscriptionReviewRule.self)
        try context.delete(model: ManualSubscription.self)
        try context.delete(model: SourceTransactionIdentity.self)
        try context.delete(model: MerchantIdentity.self)
        try context.delete(model: MerchantIdentityMember.self)
        try context.delete(model: ServiceProfile.self)
        try context.delete(model: SubscriptionScheduleExpectation.self)
        try context.delete(model: SubscriptionMatchRule.self)
        try context.delete(model: SubscriptionOccurrence.self)
        try context.delete(model: SubscriptionDetectionEvidence.self)
        try context.delete(model: DetectionRun.self)

        if includeTemplates {
            try context.delete(model: ColumnMappingTemplate.self)
        }

        try context.save()

        return LibraryResetSummary(
            importCount: imports.count,
            transactionCount: transactions.count,
            subscriptionCount: subscriptions.count,
            classificationCount: classifications.count,
            aliasCount: aliases.count,
            reviewRuleCount: reviewRules.count,
            templateCount: templates.count
        )
    }
}
