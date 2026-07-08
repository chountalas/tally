import AppIntents
import Foundation
import SwiftData

struct SubscriptionEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Subscription")
    static let defaultQuery = SubscriptionEntityQuery()

    let id: UUID
    let displayName: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: displayName),
            subtitle: LocalizedStringResource(stringLiteral: detail)
        )
    }
}

struct RenewalEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Renewal")
    static let defaultQuery = RenewalEntityQuery()

    let id: UUID
    let displayName: String
    let renewalDate: Date
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: displayName),
            subtitle: LocalizedStringResource(stringLiteral: detail)
        )
    }
}

struct AuditRecommendationEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Audit Recommendation")
    static let defaultQuery = AuditRecommendationEntityQuery()

    let id: String
    let displayName: String
    let detail: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: displayName),
            subtitle: LocalizedStringResource(stringLiteral: detail)
        )
    }
}

@MainActor
struct SubscriptionEntityQuery: EntityQuery {
    func suggestedEntities() async throws -> [SubscriptionEntity] {
        let referenceDate = Date()
        return try AppIntentSubscriptionStore.subscriptions().map { subscription in
            Self.makeEntity(subscription: subscription, referenceDate: referenceDate)
        }
    }

    func entities(for identifiers: [UUID]) async throws -> [SubscriptionEntity] {
        let referenceDate = Date()
        return try AppIntentSubscriptionStore.subscriptions()
            .filter { identifiers.contains($0.id) }
            .map { subscription in
                Self.makeEntity(subscription: subscription, referenceDate: referenceDate)
            }
    }

    private static func makeEntity(
        subscription: Subscription,
        referenceDate: Date
    ) -> SubscriptionEntity {
        let price = subscription.priceAmount.currencyString(
            code: subscription.priceCurrency
        )
        let displayStatus = DashboardMetrics.displayStatus(
            for: subscription,
            referenceDate: referenceDate
        )
        let detail = price + " • " + displayStatus.title

        return SubscriptionEntity(
            id: subscription.id,
            displayName: subscription.displayName,
            detail: detail
        )
    }
}

@MainActor
struct RenewalEntityQuery: EntityQuery {
    func suggestedEntities() async throws -> [RenewalEntity] {
        let referenceDate = Date()
        return DashboardMetrics.currentActiveSubscriptions(
            from: try AppIntentSubscriptionStore.subscriptions(),
            referenceDate: referenceDate
        )
            .filter { DashboardMetrics.currentRenewalDate(for: $0, referenceDate: referenceDate) != nil }
            .sorted {
                (DashboardMetrics.currentRenewalDate(for: $0, referenceDate: referenceDate) ?? .distantFuture)
                    < (DashboardMetrics.currentRenewalDate(for: $1, referenceDate: referenceDate) ?? .distantFuture)
            }
            .prefix(12)
            .compactMap { subscription in
                Self.makeEntity(subscription: subscription, referenceDate: referenceDate)
            }
    }

    func entities(for identifiers: [UUID]) async throws -> [RenewalEntity] {
        let referenceDate = Date()
        return DashboardMetrics.currentActiveSubscriptions(
            from: try AppIntentSubscriptionStore.subscriptions(),
            referenceDate: referenceDate
        )
            .filter { identifiers.contains($0.id) }
            .compactMap { subscription in
                Self.makeEntity(subscription: subscription, referenceDate: referenceDate)
            }
    }

    private static func makeEntity(subscription: Subscription, referenceDate: Date) -> RenewalEntity? {
        guard let renewalDate = DashboardMetrics.currentRenewalDate(
            for: subscription,
            referenceDate: referenceDate
        ) else {
            return nil
        }

        let price = subscription.priceAmount.currencyString(
            code: subscription.priceCurrency
        )
        let detail = price + " on " + renewalDate.shortDateString

        return RenewalEntity(
            id: subscription.id,
            displayName: subscription.displayName,
            renewalDate: renewalDate,
            detail: detail
        )
    }
}

@MainActor
struct AuditRecommendationEntityQuery: EntityQuery {
    func suggestedEntities() async throws -> [AuditRecommendationEntity] {
        let subscriptions = try AppIntentSubscriptionStore.subscriptions()
        let transactions = try AppIntentSubscriptionStore.transactions()
        let activeSubscriptions = DashboardMetrics.currentActiveSubscriptions(from: subscriptions)

        return activeSubscriptions
            .map { subscription in
                let score = AuditEngine.score(
                    subscription: subscription,
                    allActive: activeSubscriptions,
                    transactions: transactions
                )
                return AuditRecommendationEntity(
                    id: subscription.id.uuidString,
                    displayName: subscription.displayName,
                    detail: "Audit score \(score.cancelWorthiness)/100"
                        + " • "
                        + score.action.title
                )
            }
            .sorted { $0.detail > $1.detail }
    }

    func entities(for identifiers: [String]) async throws -> [AuditRecommendationEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
}

struct OpenSubscriptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Subscription"
    static let description = IntentDescription(
        "Open a specific subscription in Tally."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Subscription")
    var subscription: SubscriptionEntity

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppIntentURL.subscription(subscription.id)))
    }
}

struct ShowUpcomingRenewalsIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Upcoming Renewals"
    static let description = IntentDescription(
        "Open Tally to review upcoming renewals."
    )
    static let openAppWhenRun = true

    @Parameter(title: "Days")
    var days: Int

    init() {
        days = 30
    }

    func perform() async throws -> some IntentResult & ProvidesDialog & OpensIntent {
        return .result(
            opensIntent: OpenURLIntent(AppIntentURL.tab(.calendar)),
            dialog: IntentDialog("Opening renewals due in the next \(days) days.")
        )
    }
}

struct RunSubscriptionAuditIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Subscription Audit"
    static let description = IntentDescription(
        "Open the audit view in Tally."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppIntentURL.tab(.audit)))
    }
}

struct ShowSavingsOpportunitiesIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Savings Opportunities"
    static let description = IntentDescription(
        "Open the dashboard to review savings opportunities."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & OpensIntent {
        .result(opensIntent: OpenURLIntent(AppIntentURL.tab(.dashboard)))
    }
}

struct TallyShortcuts: AppShortcutsProvider {
    @AppShortcutsBuilder
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenSubscriptionIntent(),
            phrases: [
                "Open a subscription in \(.applicationName)",
                "Show subscription details in \(.applicationName)"
            ],
            shortTitle: "Open Subscription",
            systemImageName: "rectangle.stack"
        )
        AppShortcut(
            intent: ShowUpcomingRenewalsIntent(),
            phrases: [
                "Show upcoming renewals in \(.applicationName)",
                "What renews soon in \(.applicationName)"
            ],
            shortTitle: "Upcoming Renewals",
            systemImageName: "calendar"
        )
        AppShortcut(
            intent: RunSubscriptionAuditIntent(),
            phrases: [
                "Run my subscription audit in \(.applicationName)"
            ],
            shortTitle: "Subscription Audit",
            systemImageName: "checklist"
        )
        AppShortcut(
            intent: ShowSavingsOpportunitiesIntent(),
            phrases: [
                "Show savings opportunities in \(.applicationName)"
            ],
            shortTitle: "Savings Opportunities",
            systemImageName: "dollarsign.circle"
        )
    }
}

private enum AppIntentURL {
    static func subscription(_ id: UUID) -> URL {
        URL(string: "tally://subscription/\(id.uuidString)")!
    }

    static func tab(_ tab: SidebarTab) -> URL {
        URL(string: "tally://tab/\(tab.rawValue)")!
    }
}

@MainActor
enum AppIntentSubscriptionStore {
    private static var cachedContainer: ModelContainer?
    private static var makeContainer: () throws -> ModelContainer = {
        try ModelContainerFactory.makePersistentSharedContainer()
    }

    static func subscriptions() throws -> [Subscription] {
        let container = try container()
        return try container.mainContext.fetch(
            FetchDescriptor<Subscription>(sortBy: [SortDescriptor(\.displayName)])
        )
    }

    static func transactions() throws -> [NormalizedTransaction] {
        let container = try container()
        return try container.mainContext.fetch(
            FetchDescriptor<NormalizedTransaction>(
                sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
            )
        )
    }

    private static func container() throws -> ModelContainer {
        if let cachedContainer {
            return cachedContainer
        }

        let container = try makeContainer()
        cachedContainer = container
        return container
    }

    #if DEBUG
    static func configureForTesting(makeContainer: @escaping () throws -> ModelContainer) {
        cachedContainer = nil
        self.makeContainer = makeContainer
    }

    static func resetTestingConfiguration() {
        cachedContainer = nil
        makeContainer = {
            try ModelContainerFactory.makePersistentSharedContainer()
        }
    }
    #endif
}
