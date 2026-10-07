import Foundation

struct SubscriptionSummary {
    let canonicalName: String
    let displayName: String
    let cadence: SubscriptionCadence
    let status: SubscriptionStatus
    let priceAmount: Decimal
    let currency: String
    let lastChargeDate: Date?
    let confidence: Double
    let category: String?
    let reason: String?
    let detectionSource: SubscriptionDetectionSource
}

struct SubscriptionScoringInput {
    let intervals: [Int]
    let cadence: SubscriptionCadence
}

struct SubscriptionScoringSnapshot {
    let cadence: SubscriptionCadence
    let transactionCount: Int
    let averagePrice: Double
    let minPrice: Double
    let maxPrice: Double
    let priceVariation: Double
    let intervalConsistency: Double
    let amountStability: Double
    let keywordSupport: Double
    let dominantMerchantKind: MerchantKind
    let merchantAffinity: Double
    let classificationConfidence: Double
    let memoDiversity: Double
    let descriptorStrength: Double
    let negativePenalty: Double
    let excludedCategoryCount: Int
    let financialMovementCount: Int
    let recurringBillOrNonSubscriptionCount: Int
    let commerceNoiseCount: Int
    let knownSubscriptionSignalCount: Int
    let hasExplicitSubscriptionWording: Bool
    let hasStrongSubscriptionWording: Bool

    var lowNegativeSignalScore: Double {
        max(0, 1 - negativePenalty)
    }
}

struct SubscriptionCandidateEvidence {
    let strongCadence: Bool
    let strongMerchant: Bool
    let strongClassification: Bool
    let supportsVariableBilling: Bool
    let supportsSparseAutoConfirm: Bool
    let supportsTwoChargeMonthlyAutoConfirm: Bool
    let supportsKnownServiceAutoConfirm: Bool
    let obviousNegative: Bool
    let lowNegativeSignalScore: Double
    let amountStability: Double

    func shouldAutoConfirm(
        confidence: Double,
        occurrenceCount: Int,
        requiredOccurrences: Int
    ) -> Bool {
        guard obviousNegative == false else {
            return false
        }

        if supportsSparseAutoConfirm && confidence >= 0.72 {
            return true
        }

        if supportsTwoChargeMonthlyAutoConfirm && confidence >= 0.62 {
            return true
        }

        if supportsKnownServiceAutoConfirm && confidence >= 0.62 {
            return true
        }

        guard occurrenceCount >= requiredOccurrences else {
            return false
        }

        guard strongCadence, strongMerchant, lowNegativeSignalScore >= 0.7 else {
            return false
        }

        let stableEnough = amountStability >= 0.45 || supportsVariableBilling
        guard stableEnough else {
            return false
        }

        return confidence >= 0.68 && (strongClassification || supportsVariableBilling)
    }
}
