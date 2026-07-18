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
        let activeSubscriptionIDs = Set(activeSubscriptions.map(\.id))
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

        // Add the complete replacement set before removing stale reminders. If
        // delivery fails, existing reminders remain intact and the error reaches
        // the caller instead of leaving the user with an empty schedule.
        for request in requests {
            try await notificationCenter.add(request)
        }

        let desiredIdentifiers = Set(requests.map(\.identifier))
        let staleIdentifiers = await pendingTrackerNotificationIdentifiers()
            .filter { desiredIdentifiers.contains($0) == false }
        notificationCenter.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)

        let scheduledSubscriptionIDs = Set(scheduledSubscriptions.map(\.id))
        for subscription in subscriptions {
            subscription.lastNotificationScheduledAt = scheduledSubscriptionIDs.contains(subscription.id) ? .now : nil
        }
        try context.save()
        return requests.count
    }

    func clearScheduledNotifications(for subscriptions: [Subscription], context: ModelContext) throws {
        let identifiers = subscriptions.map(notificationIdentifier(for:))

        for subscription in subscriptions {
            subscription.lastNotificationScheduledAt = nil
        }

        // Persist the local source of truth before removing the external side
        // effect. A failed save must not report a successful cleanup.
        try context.save()
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
