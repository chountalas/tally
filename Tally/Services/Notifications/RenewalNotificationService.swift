import Foundation
import SwiftData
import UserNotifications

@MainActor
final class RenewalNotificationService {
    private let notificationCenter = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationCenter.notificationSettings().authorizationStatus
    }

    func requestAccess() async throws -> Bool {
        try await notificationCenter.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func schedule(subscriptions: [Subscription], context: ModelContext, leadDays: Int = 7) async throws -> Int {
        let status = await authorizationStatus()
        guard hasNotificationAccess(status) else {
            throw RenewalNotificationError.accessDenied
        }

        let referenceDate = Date()
        let activeSubscriptions = DashboardMetrics.currentActiveSubscriptions(
            from: subscriptions,
            referenceDate: referenceDate
        )
        var scheduledSubscriptions: [Subscription] = []
        var requests: [UNNotificationRequest] = []

        for subscription in activeSubscriptions {
            guard let renewalDate = DashboardMetrics.currentRenewalDate(
                for: subscription,
                referenceDate: referenceDate
            ) else {
                continue
            }

            let reminderLeadDays = max(0, subscription.reminderDaysBefore ?? leadDays)

            guard let triggerDate = Calendar.current.date(
                byAdding: .day,
                value: -reminderLeadDays,
                to: renewalDate
            ),
                  triggerDate > .now else {
                continue
            }

            let content = UNMutableNotificationContent()
            content.title = "\(subscription.displayName) renews soon"
            content.body = """
            Expected charge \
            \(subscription.priceAmount.currencyString(code: subscription.priceCurrency)) \
            on \(renewalDate.formatted(date: .abbreviated, time: .omitted)).
            """
            content.sound = .default

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
            let request = UNNotificationRequest(
                identifier: notificationIdentifier(for: subscription),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )

            requests.append(request)
            scheduledSubscriptions.append(subscription)
        }

        let scheduledSubscriptionIDs = Set(scheduledSubscriptions.map(\.id))
        let previousScheduleDates = Dictionary(
            uniqueKeysWithValues: subscriptions.map { ($0.id, $0.lastNotificationScheduledAt) }
        )
        for subscription in subscriptions {
            subscription.lastNotificationScheduledAt = scheduledSubscriptionIDs.contains(subscription.id) ? .now : nil
        }
        try context.save()

        do {
            for request in requests {
                try await notificationCenter.add(request)
            }
        } catch {
            for subscription in subscriptions {
                subscription.lastNotificationScheduledAt = previousScheduleDates[subscription.id] ?? nil
            }
            try context.save()
            throw error
        }

        let desiredIdentifiers = Set(requests.map(\.identifier))
        let staleIdentifiers = await pendingTrackerNotificationIdentifiers()
            .filter { desiredIdentifiers.contains($0) == false }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)
        return requests.count
    }

    func clearScheduledNotifications(forSubscriptionIDs subscriptionIDs: [UUID]) {
        let identifiers = subscriptionIDs.map { "renewal.\($0.uuidString)" }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func notificationIdentifier(for subscription: Subscription) -> String {
        "renewal.\(subscription.id.uuidString)"
    }

    private func hasNotificationAccess(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional:
            return true
#if os(iOS)
        case .ephemeral:
            return true
#endif
        default:
            return false
        }
    }

    private func pendingTrackerNotificationIdentifiers() async -> [String] {
        await notificationCenter.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix("renewal.") }
    }
}

enum RenewalNotificationError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Notification access has not been granted."
        }
    }
}
