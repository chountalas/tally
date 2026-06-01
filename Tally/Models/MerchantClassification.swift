import Foundation
import SwiftData

@Model
final class MerchantClassification {
    var rawMerchant: String = ""
    var canonicalName: String = ""
    var serviceCategory: String = ""
    var merchantKindRawValue: String = MerchantKind.unknown.rawValue
    var subscriptionAffinity: Double = 0
    var confidence: Double = 0
    var isUserCorrected: Bool = false
    var classifierVersion: Int = 0
    var lastUpdatedAt: Date = Date.now

    init(
        rawMerchant: String,
        result: MerchantClassificationResult,
        isUserCorrected: Bool = false,
        classifierVersion: Int = 0,
        lastUpdatedAt: Date = Date.now
    ) {
        self.rawMerchant = rawMerchant
        canonicalName = result.canonicalName
        serviceCategory = result.serviceCategory
        merchantKindRawValue = result.merchantKind.rawValue
        subscriptionAffinity = result.subscriptionAffinity
        confidence = result.confidence
        self.isUserCorrected = isUserCorrected
        self.classifierVersion = classifierVersion
        self.lastUpdatedAt = lastUpdatedAt
    }

    var merchantKind: MerchantKind {
        get { MerchantKind(rawValue: merchantKindRawValue) ?? .unknown }
        set { merchantKindRawValue = newValue.rawValue }
    }

    var result: MerchantClassificationResult {
        MerchantClassificationResult(
            canonicalName: canonicalName,
            serviceCategory: serviceCategory,
            merchantKind: merchantKind,
            subscriptionAffinity: subscriptionAffinity,
            confidence: confidence
        )
    }
}
