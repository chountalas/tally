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
    private let calendarService: RenewalCalendarService
    private let notificationService: RenewalNotificationService

    init(
        calendarService: RenewalCalendarService = RenewalCalendarService(),
        notificationService: RenewalNotificationService = RenewalNotificationService()
    ) {
        self.calendarService = calendarService
        self.notificationService = notificationService
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
            try calendarService.clearSyncedEvents(for: subscriptions, context: context)
        } catch RenewalCalendarError.accessDenied {
            // Local subscription state is about to be deleted, so cleanup failure should not block the reset.
        }

        do {
            try notificationService.clearScheduledNotifications(for: subscriptions, context: context)
        } catch RenewalNotificationError.accessDenied {
            // Local subscription state is about to be deleted, so cleanup failure should not block the reset.
        }

        try context.delete(model: Subscription.self)
        try context.delete(model: NormalizedTransaction.self)
        try context.delete(model: ImportRecord.self)
        try context.delete(model: MerchantClassification.self)
        try context.delete(model: MerchantAlias.self)
        try context.delete(model: SubscriptionReviewRule.self)

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
