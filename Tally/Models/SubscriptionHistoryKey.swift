import Foundation

struct SubscriptionHistoryKey {
    let merchant: String
    let firstChargeID: UUID

    var rawValue: String { "\(merchant):history:\(firstChargeID.uuidString)" }

    init(merchant: String, firstChargeID: UUID) {
        self.merchant = merchant
        self.firstChargeID = firstChargeID
    }

    init?(rawValue: String) {
        let parts = rawValue.components(separatedBy: ":history:")
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        merchant = parts[0]
        firstChargeID = id
    }
}

extension Subscription {
    var historyIdentity: SubscriptionHistoryKey? { SubscriptionHistoryKey(rawValue: canonicalName) }
}
