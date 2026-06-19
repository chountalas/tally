import CoreSpotlight
import Foundation
import SwiftData
import UniformTypeIdentifiers

struct SubscriptionSpotlightIndexer {
    @MainActor private static var lastIndexedSignature: String?

    private let index = CSSearchableIndex.default()
    private let subscriptionDomain = "tally.subscription"
    private let renewalDomain = "tally.renewal"

    @MainActor
    func reindexIfNeeded(in context: ModelContext) async {
        let descriptor = FetchDescriptor<Subscription>(
            sortBy: [SortDescriptor(\.displayName)]
        )
        let subscriptions = (try? context.fetch(descriptor)) ?? []
        let referenceDate = Date()
        let signature = signature(for: subscriptions, referenceDate: referenceDate)

        guard signature != Self.lastIndexedSignature else {
            return
        }

        await reindex(subscriptions: subscriptions, referenceDate: referenceDate)
        Self.lastIndexedSignature = signature
    }

    @MainActor
    func reindex(subscriptions: [Subscription], referenceDate: Date = .now) async {
        do {
            try await deleteDomainItems()
            try await indexItems(searchableItems(for: subscriptions, referenceDate: referenceDate))
        } catch {
            // Spotlight indexing is best-effort and should not interrupt app flows.
        }
    }

    @MainActor
    func searchableItems(
        for subscriptions: [Subscription],
        referenceDate: Date = .now
    ) -> [CSSearchableItem] {
        var items: [CSSearchableItem] = subscriptions.map {
            makeSubscriptionItem(for: $0, referenceDate: referenceDate)
        }
        items.append(
            contentsOf: DashboardMetrics.currentActiveSubscriptions(
                from: subscriptions,
                referenceDate: referenceDate
            )
                .compactMap { makeRenewalItem(for: $0, referenceDate: referenceDate) }
        )
        return items
    }

    private func makeSubscriptionItem(
        for subscription: Subscription,
        referenceDate: Date
    ) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        let displayStatus = DashboardMetrics.displayStatus(
            for: subscription,
            referenceDate: referenceDate
        )
        attributes.title = subscription.displayName
        attributes.contentDescription = [
            subscription.serviceCategory ?? "Uncategorized",
            subscription.priceAmount.currencyString(code: subscription.priceCurrency),
            displayStatus.title
        ].joined(separator: " • ")
        attributes.keywords = [
            subscription.displayName,
            subscription.canonicalName,
            subscription.serviceCategory,
            displayStatus.title,
            "subscription"
        ].compactMap { $0 }

        return CSSearchableItem(
            uniqueIdentifier: "subscription.\(subscription.id.uuidString)",
            domainIdentifier: subscriptionDomain,
            attributeSet: attributes
        )
    }

    private func makeRenewalItem(for subscription: Subscription, referenceDate: Date) -> CSSearchableItem? {
        guard subscription.status == .active,
              let renewalDate = DashboardMetrics.currentRenewalDate(
                for: subscription,
                referenceDate: referenceDate
              ) else {
            return nil
        }

        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = "\(subscription.displayName) renewal"
        let amount = subscription.priceAmount.currencyString(code: subscription.priceCurrency)
        attributes.contentDescription = "Expected \(amount) on \(renewalDate.shortDateString)"
        attributes.keywords = [
            subscription.displayName,
            subscription.serviceCategory,
            "renewal",
            "upcoming"
        ].compactMap { $0 }

        return CSSearchableItem(
            uniqueIdentifier: "renewal.\(subscription.id.uuidString)",
            domainIdentifier: renewalDomain,
            attributeSet: attributes
        )
    }

    @MainActor
    private func deleteDomainItems() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.deleteSearchableItems(withDomainIdentifiers: [subscriptionDomain, renewalDomain]) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    private func indexItems(_ items: [CSSearchableItem]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            index.indexSearchableItems(items) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    @MainActor
    private func signature(for subscriptions: [Subscription], referenceDate: Date) -> String {
        let referenceDay = Calendar.current.startOfDay(for: referenceDate).ISO8601Format()
        let activeRenewalIDs = Set(
            DashboardMetrics.currentActiveSubscriptions(
                from: subscriptions,
                referenceDate: referenceDate
            )
                .compactMap { subscription in
                    DashboardMetrics.currentRenewalDate(
                        for: subscription,
                        referenceDate: referenceDate
                    ) == nil ? nil : subscription.id.uuidString
                }
        )
        return ([referenceDay] + subscriptions.map {
            [
                $0.id.uuidString,
                $0.displayName,
                $0.statusRawValue,
                $0.predictedNextChargeDate?.ISO8601Format() ?? "none",
                $0.priceAmount.description,
                activeRenewalIDs.contains($0.id.uuidString) ? "current-renewal" : "no-current-renewal"
            ].joined(separator: "::")
        })
        .joined(separator: "|")
    }
}
