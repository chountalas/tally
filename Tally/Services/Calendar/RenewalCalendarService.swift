import EventKit
import Foundation
import SwiftData

@MainActor
final class RenewalCalendarService {
    private let eventStore = EKEventStore()

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func clearSyncedEvents(for subscriptions: [Subscription], context: ModelContext) throws {
        guard authorizationStatus() == .fullAccess else {
            throw RenewalCalendarError.accessDenied
        }

        for subscription in subscriptions {
            if let identifier = subscription.calendarEventIdentifier,
               let event = eventStore.event(withIdentifier: identifier) {
                try eventStore.remove(event, span: .thisEvent)
            }

            subscription.calendarEventIdentifier = nil
            subscription.lastCalendarSyncAt = nil
        }

        try context.save()
    }
}

enum RenewalCalendarError: LocalizedError {
    case accessDenied

    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Calendar access has not been granted."
        }
    }
}
