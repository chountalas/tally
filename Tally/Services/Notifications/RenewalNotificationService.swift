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

        let activeSubscriptions = subscriptions.filter { $0.status == .active }
        await clearTrackerNotifications()

        var scheduledCount = 0

        for subscription in subscriptions
        where subscription.status != .active || subscription.predictedNextChargeDate == nil {
            subscription.lastNotificationScheduledAt = nil
        }

        for subscription in activeSubscriptions {
            guard let renewalDate = subscription.predictedNextChargeDate else {
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
            \(subscription.priceAmount.formatted(.currency(code: subscription.priceCurrency))) \
            on \(renewalDate.formatted(date: .abbreviated, time: .omitted)).
            """
            content.sound = .default

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: triggerDate)
            let request = UNNotificationRequest(
                identifier: notificationIdentifier(for: subscription),
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )

            try await notificationCenter.add(request)
            subscription.lastNotificationScheduledAt = .now
            scheduledCount += 1
        }

        try context.save()
        return scheduledCount
    }

    func clearScheduledNotifications(for subscriptions: [Subscription], context: ModelContext) throws {
        let identifiers = subscriptions.map(notificationIdentifier(for:))
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)

        for subscription in subscriptions {
            subscription.lastNotificationScheduledAt = nil
        }

        try context.save()
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

    private func clearTrackerNotifications() async {
        let identifiers = await pendingTrackerNotificationIdentifiers()
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
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
