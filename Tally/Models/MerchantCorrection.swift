import Foundation
import SwiftData

@Model
final class MerchantCorrection {
    var canonicalName: String = ""
    var isSubscription: Bool = false
    var correctedCadenceRawValue: String?
    var updatedAt: Date = Date.now

    init(
        canonicalName: String,
        isSubscription: Bool,
        correctedCadence: SubscriptionCadence? = nil
    ) {
        self.canonicalName = canonicalName
        self.isSubscription = isSubscription
        correctedCadenceRawValue = correctedCadence?.rawValue
        updatedAt = .now
    }

    var correctedCadence: SubscriptionCadence? {
        get { correctedCadenceRawValue.flatMap(SubscriptionCadence.init(rawValue:)) }
        set { correctedCadenceRawValue = newValue?.rawValue }
    }
}
