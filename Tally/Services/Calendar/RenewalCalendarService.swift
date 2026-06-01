import EventKit
import Foundation
import SwiftData

@MainActor
final class RenewalCalendarService {
    private let eventStore = EKEventStore()

    func authorizationStatus() -> EKAuthorizationStatus {
        EKEventStore.authorizationStatus(for: .event)
    }

    func requestAccess() async throws -> Bool {
        try await eventStore.requestFullAccessToEvents()
    }

    func sync(subscriptions: [Subscription], context: ModelContext) throws -> Int {
        guard authorizationStatus() == .fullAccess else {
            throw RenewalCalendarError.accessDenied
        }

        let staleSubscriptions = subscriptions.filter {
            $0.status != .active || $0.predictedNextChargeDate == nil
        }
        try clearSyncedEvents(for: staleSubscriptions, context: context)

        var syncedCount = 0

        for subscription in subscriptions where subscription.status == .active {
            guard let renewalDate = subscription.predictedNextChargeDate else {
                continue
            }

            let event = subscription.calendarEventIdentifier
                .flatMap { eventStore.event(withIdentifier: $0) }
                ?? EKEvent(eventStore: eventStore)
            event.calendar = eventStore.defaultCalendarForNewEvents
            event.title = "\(subscription.displayName) renewal"
            event.startDate = renewalDate
            event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: renewalDate) ?? renewalDate
            event.notes = """
            Tally renewal reminder
            Price: \(subscription.priceAmount.formatted(.currency(code: subscription.priceCurrency)))
            Cadence: \(subscription.cadence.rawValue)
            Confidence: \(subscription.confidenceScore.formatted(.percent.precision(.fractionLength(0))))
            """

            try eventStore.save(event, span: .thisEvent)
            subscription.calendarEventIdentifier = event.eventIdentifier
            subscription.lastCalendarSyncAt = .now
            syncedCount += 1
        }

        try context.save()
        return syncedCount
    }

    func createCancellationReminder(for subscription: Subscription, cancelBy date: Date, context: ModelContext) throws {
        let status = authorizationStatus()
        guard status == .fullAccess || status == .writeOnly else {
            throw RenewalCalendarError.accessDenied
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = "Cancel \(subscription.displayName)"
        event.notes = "Cancel before renewal to save \(subscription.normalizedMonthlyAmount.currencyString())/month."
        event.startDate = date
        event.endDate = Calendar.current.date(byAdding: .hour, value: 1, to: date) ?? date
        event.calendar = eventStore.defaultCalendarForNewEvents
        event.addAlarm(EKAlarm(relativeOffset: -86400))

        try eventStore.save(event, span: .thisEvent)
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
