import Foundation
import SwiftData

enum SubscriptionLibraryState: String, Codable, CaseIterable, Identifiable, Sendable {
    case confirmed
    case suggested
    case ignored
    case manual
    case inactive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .confirmed:
            return "Confirmed"
        case .suggested:
            return "Suggested"
        case .ignored:
            return "Ignored"
        case .manual:
            return "Manual"
        case .inactive:
            return "Inactive"
        }
    }

    var isManagedLibraryVisible: Bool {
        self != .ignored
    }
}

enum SubscriptionCreationPath: String, Codable, CaseIterable, Identifiable, Sendable {
    case imported
    case manual
    case merged
    case refreshed

    var id: String { rawValue }
}

@Model
final class ManualSubscription {
    var id: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        createdAt: Date = Date.now,
        updatedAt: Date = Date.now
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
