import Foundation
import SwiftData

@Model
final class SubscriptionReviewRule {
    var canonicalName: String = ""
    var overrideDisplayName: String?
    var overrideStatusRawValue: String?
    var overrideCadenceRawValue: String?
    var overridePriceAmount: Decimal?
    var overridePriceCurrency: String?
    var overrideLastChargeDate: Date?
    var overrideCategory: String?
    var notes: String?
    var isFalsePositive: Bool = false
    var isUserConfirmed: Bool = false
    var updatedAt: Date = Date.now

    init(
        canonicalName: String,
        overrideDisplayName: String? = nil,
        overrideStatus: SubscriptionStatus? = nil,
        overrideCadence: SubscriptionCadence? = nil,
        overridePriceAmount: Decimal? = nil,
        overridePriceCurrency: String? = nil,
        overrideLastChargeDate: Date? = nil,
        overrideCategory: String? = nil,
        notes: String? = nil,
        isFalsePositive: Bool = false,
        isUserConfirmed: Bool = false,
        updatedAt: Date = Date.now
    ) {
        self.canonicalName = canonicalName
        self.overrideDisplayName = overrideDisplayName
        overrideStatusRawValue = overrideStatus?.rawValue
        overrideCadenceRawValue = overrideCadence?.rawValue
        self.overridePriceAmount = overridePriceAmount
        self.overridePriceCurrency = overridePriceCurrency
        self.overrideLastChargeDate = overrideLastChargeDate
        self.overrideCategory = overrideCategory
        self.notes = notes
        self.isFalsePositive = isFalsePositive
        self.isUserConfirmed = isUserConfirmed
        self.updatedAt = updatedAt
    }

    var overrideStatus: SubscriptionStatus? {
        get { overrideStatusRawValue.flatMap(SubscriptionStatus.init(rawValue:)) }
        set { overrideStatusRawValue = newValue?.rawValue }
    }

    var overrideCadence: SubscriptionCadence? {
        get { overrideCadenceRawValue.flatMap(SubscriptionCadence.init(rawValue:)) }
        set { overrideCadenceRawValue = newValue?.rawValue }
    }
}
