import SwiftData
import UserNotifications
import XCTest
@testable import Tally

@MainActor
final class RenewalNotificationServiceTests: XCTestCase {
    func testSchedulePersistsMetadataOnlyAfterRequestIsAdded() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let subscription = makeSubscription(name: "New", priorScheduleDate: nil)
        context.insert(subscription)
        try context.save()

        let notificationCenter = RecordingRenewalNotificationCenter()
        notificationCenter.onAdd = { _ in
            XCTAssertNil(subscription.lastNotificationScheduledAt)
        }
        let service = RenewalNotificationService(notificationCenter: notificationCenter)

        let scheduledCount = try await service.schedule(subscriptions: [subscription], context: context)

        XCTAssertEqual(scheduledCount, 1)
        XCTAssertNotNil(subscription.lastNotificationScheduledAt)
        XCTAssertNotNil(notificationCenter.requestsByIdentifier[notificationIdentifier(for: subscription)])
    }

    func testScheduleRestoresPreviousRequestsAndMetadataWhenAddingFails() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let priorScheduleDate = Date(timeIntervalSinceReferenceDate: 123_456)
        let first = makeSubscription(name: "First", priorScheduleDate: priorScheduleDate)
        let second = makeSubscription(name: "Second", priorScheduleDate: priorScheduleDate)
        context.insert(first)
        context.insert(second)
        try context.save()

        let notificationCenter = RecordingRenewalNotificationCenter()
        notificationCenter.requestsByIdentifier = [
            notificationIdentifier(for: first): makeRequest(
                identifier: notificationIdentifier(for: first),
                title: "Previous First"
            ),
            notificationIdentifier(for: second): makeRequest(
                identifier: notificationIdentifier(for: second),
                title: "Previous Second"
            )
        ]
        notificationCenter.failingAddAttempt = 2
        let service = RenewalNotificationService(notificationCenter: notificationCenter)

        do {
            _ = try await service.schedule(subscriptions: [first, second], context: context)
            XCTFail("Scheduling should surface the notification-center failure.")
        } catch RecordingNotificationCenterError.addFailed {
            // Expected.
        }

        XCTAssertEqual(first.lastNotificationScheduledAt, priorScheduleDate)
        XCTAssertEqual(second.lastNotificationScheduledAt, priorScheduleDate)
        XCTAssertEqual(
            notificationCenter.requestsByIdentifier[notificationIdentifier(for: first)]?.content.title,
            "Previous First"
        )
        XCTAssertEqual(
            notificationCenter.requestsByIdentifier[notificationIdentifier(for: second)]?.content.title,
            "Previous Second"
        )
    }

    private func makeSubscription(name: String, priorScheduleDate: Date?) -> Subscription {
        let nextChargeDate = Calendar.current.date(byAdding: .day, value: 30, to: .now) ?? .now
        return Subscription(
            canonicalName: name,
            displayName: name,
            status: .active,
            libraryState: .confirmed,
            cadence: .monthly,
            priceAmount: 9.99,
            priceCurrency: "USD",
            normalizedMonthlyAmount: 9.99,
            lastChargeDate: .now,
            predictedNextChargeDate: nextChargeDate,
            confidenceScore: 1,
            isUserConfirmed: true,
            lastNotificationScheduledAt: priorScheduleDate
        )
    }

    private func notificationIdentifier(for subscription: Subscription) -> String {
        "renewal.\(subscription.id.uuidString)"
    }

    private func makeRequest(identifier: String, title: String) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }
}

@MainActor
private final class RecordingRenewalNotificationCenter: RenewalNotificationCenter {
    var requestsByIdentifier: [String: UNNotificationRequest] = [:]
    var failingAddAttempt: Int?
    var onAdd: ((UNNotificationRequest) -> Void)?
    private var addAttempt = 0

    func authorizationStatus() async -> UNAuthorizationStatus {
        .authorized
    }

    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
        true
    }

    func add(_ request: UNNotificationRequest) async throws {
        addAttempt += 1
        onAdd?(request)
        if addAttempt == failingAddAttempt {
            throw RecordingNotificationCenterError.addFailed
        }
        requestsByIdentifier[request.identifier] = request
    }

    func pendingNotificationRequests() async -> [UNNotificationRequest] {
        Array(requestsByIdentifier.values)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        for identifier in identifiers {
            requestsByIdentifier.removeValue(forKey: identifier)
        }
    }
}

private enum RecordingNotificationCenterError: Error {
    case addFailed
}
