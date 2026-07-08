import EventKit
import Foundation
import SwiftData

@MainActor
final class RenewalCalendarService {
    private let eventStore = EKEventStore()
    private let calendarTitle = "Tally"

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func syncRenewals(
        for subscriptions: [Subscription],
        context: ModelContext
    ) async throws -> RenewalCalendarSyncSummary {
        try await ensureFullCalendarAccess()
        removePendingSyncedEvents()

        let tallyCalendar = try tallyCalendar()
        let syncedAt = Date()
        let systemCalendar = Calendar.current
        var summary = RenewalCalendarSyncSummary()

        for subscription in subscriptions {
            guard
                DashboardMetrics.displayStatus(for: subscription, referenceDate: syncedAt) == .active,
                let renewalDate = Self.upcomingCalendarRenewalDate(
                    for: subscription,
                    referenceDate: syncedAt,
                    calendar: systemCalendar
                )
            else {
                if try removeSyncedEvent(for: subscription) {
                    summary.removedCount += 1
                }
                subscription.calendarEventIdentifier = nil
                subscription.lastCalendarSyncAt = syncedAt
                if context.hasChanges {
                    try context.save()
                }
                continue
            }

            let existingEvent = subscription.calendarEventIdentifier.flatMap {
                eventStore.event(withIdentifier: $0)
            }
            let event = existingEvent ?? EKEvent(eventStore: eventStore)
            event.calendar = tallyCalendar
            event.title = "\(subscription.displayName) renewal"
            event.isAllDay = true
            event.startDate = systemCalendar.startOfDay(for: renewalDate)
            event.endDate = systemCalendar.date(
                byAdding: .day,
                value: 1,
                to: event.startDate
            ) ?? event.startDate
            event.notes = "Created by Tally."

            do {
                try eventStore.save(event, span: .thisEvent, commit: true)
                subscription.calendarEventIdentifier = event.eventIdentifier
                subscription.lastCalendarSyncAt = syncedAt
                if context.hasChanges {
                    try context.save()
                }
            } catch {
                if existingEvent == nil, let eventIdentifier = event.eventIdentifier,
                   let createdEvent = eventStore.event(withIdentifier: eventIdentifier) {
                    try? eventStore.remove(createdEvent, span: .thisEvent)
                }
                throw error
            }

            if existingEvent == nil {
                summary.createdCount += 1
            } else {
                summary.updatedCount += 1
            }
        }

        try context.save()
        return summary
    }

    static func upcomingCalendarRenewalDate(
        for subscription: Subscription,
        referenceDate: Date = .now,
        calendar: Calendar = .current
    ) -> Date? {
        guard let renewalDate = DashboardMetrics.currentRenewalDate(
            for: subscription,
            referenceDate: referenceDate
        ) else {
            return nil
        }

        let today = calendar.startOfDay(for: referenceDate)
        var scheduledDate = calendar.startOfDay(for: renewalDate)
        var iterations = 0

        while scheduledDate < today {
            guard iterations < 800,
                  let next = subscription.cadence.advance(scheduledDate, using: calendar)
                    .map(calendar.startOfDay(for:)),
                  next > scheduledDate else {
                return nil
            }

            scheduledDate = next
            iterations += 1
        }

        return scheduledDate
    }

    func clearSyncedEvents(for subscriptions: [Subscription], context: ModelContext) throws {
        guard hasFullCalendarAccess else {
            throw RenewalCalendarError.accessDenied
        }

        removePendingSyncedEvents()

        for subscription in subscriptions {
            _ = try removeSyncedEvent(for: subscription)

            subscription.calendarEventIdentifier = nil
            subscription.lastCalendarSyncAt = nil
        }

        try context.save()
    }

    private var hasFullCalendarAccess: Bool {
        authorizationStatus() == .fullAccess
    }

    private func ensureFullCalendarAccess() async throws {
        switch authorizationStatus() {
        case .fullAccess:
            return
        case .notDetermined:
            let granted = try await requestFullCalendarAccess()
            guard granted else {
                throw RenewalCalendarError.accessDenied
            }
        default:
            throw RenewalCalendarError.accessDenied
        }
    }

    private func requestFullCalendarAccess() async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            eventStore.requestFullAccessToEvents { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: granted)
                }
            }
        }
    }

    private func tallyCalendar() throws -> EKCalendar {
        if let calendar = eventStore.calendars(for: .event).first(
            where: { $0.title == calendarTitle && $0.allowsContentModifications }
        ) {
            return calendar
        }

        guard let source = eventStore.defaultCalendarForNewEvents?.source ?? eventStore.sources.first else {
            throw RenewalCalendarError.missingCalendarSource
        }

        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = calendarTitle
        calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        return calendar
    }

    private func removePendingSyncedEvents() {
        let identifiers = PendingCalendarEventCleanupStore.identifiers()
        guard identifiers.isEmpty == false else { return }

        var remaining: [String] = []
        for identifier in identifiers {
            guard let event = eventStore.event(withIdentifier: identifier) else {
                continue
            }

            do {
                try eventStore.remove(event, span: .thisEvent)
            } catch {
                remaining.append(identifier)
            }
        }

        PendingCalendarEventCleanupStore.replace(with: remaining)
    }

    private func removeSyncedEvent(for subscription: Subscription) throws -> Bool {
        guard
            let identifier = subscription.calendarEventIdentifier,
            let event = eventStore.event(withIdentifier: identifier)
        else {
            return false
        }

        try eventStore.remove(event, span: .thisEvent)
        return true
    }
}

enum PendingCalendarEventCleanupStore {
    private static let key = "PendingCalendarEventCleanupIdentifiers"

    static func record(_ identifiers: [String], userDefaults: UserDefaults = .standard) {
        let validIdentifiers = identifiers
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard validIdentifiers.isEmpty == false else { return }

        let merged = Set(self.identifiers(userDefaults: userDefaults))
            .union(validIdentifiers)
        replace(with: Array(merged), userDefaults: userDefaults)
    }

    static func identifiers(userDefaults: UserDefaults = .standard) -> [String] {
        userDefaults.stringArray(forKey: key) ?? []
    }

    static func replace(with identifiers: [String], userDefaults: UserDefaults = .standard) {
        let uniqueIdentifiers = Array(Set(identifiers)).sorted()
        if uniqueIdentifiers.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(uniqueIdentifiers, forKey: key)
        }
    }
}

struct RenewalCalendarSyncSummary {
    var createdCount = 0
    var updatedCount = 0
    var removedCount = 0

    var message: String {
        let changes = [
            createdCount > 0 ? "\(createdCount) added" : nil,
            updatedCount > 0 ? "\(updatedCount) updated" : nil,
            removedCount > 0 ? "\(removedCount) removed" : nil
        ]
            .compactMap { $0 }
            .joined(separator: ", ")

        return changes.isEmpty
            ? "Calendar is already up to date."
            : "Calendar synced: \(changes)."
    }
}

enum RenewalCalendarError: LocalizedError {
    case accessDenied
    case missingCalendarSource

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access has not been granted. Open System Settings and allow Tally full calendar access."
        case .missingCalendarSource:
            return "No writable calendar account is available."
        }
    }
}
