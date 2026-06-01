import Foundation
import SwiftData

enum SubscriptionDetectionClusterStatus {
    case detected
    case needsReview
    case suppressed
}

struct SubscriptionClusterReport {
    let canonicalName: String
    let displayName: String
    let status: SubscriptionDetectionClusterStatus
    let source: SubscriptionDetectionSource
    let hadRecurringSignals: Bool
    let reason: String?
    let importRecordIDs: Set<UUID>
}

struct SubscriptionDetectionImportSummary {
    let detectedCount: Int
    let needsReviewCount: Int
    let suppressedCount: Int
    let recoveredCount: Int
}

struct SubscriptionDetectionReport {
    let clusters: [SubscriptionClusterReport]

    func summary(for importRecordID: UUID) -> SubscriptionDetectionImportSummary {
        let matchingClusters = clusters.filter { $0.importRecordIDs.contains(importRecordID) }

        return SubscriptionDetectionImportSummary(
            detectedCount: matchingClusters.filter { $0.status == .detected }.count,
            needsReviewCount: matchingClusters.filter { $0.status == .needsReview }.count,
            suppressedCount: matchingClusters.filter {
                $0.status == .suppressed && $0.hadRecurringSignals
            }.count,
            recoveredCount: matchingClusters.filter {
                $0.status == .needsReview && $0.source == .fallback
            }.count
        )
    }
}

struct DetectionEnvironment {
    let context: ModelContext
    let detectionRun: DetectionRun
    let existingSubscriptions: [Subscription]
    let existingByCanonical: [String: Subscription]
    let rulesByCanonical: [String: SubscriptionReviewRule]
    let correctionsByCanonical: [String: MerchantCorrection]
    let matchRules: [SubscriptionMatchRule]
}

final class DetectionAccumulator {
    var seenCanonicals = Set<String>()
    var suppressedTransactionIDs = Set<UUID>()
    var clusterReports: [SubscriptionClusterReport] = []
    var ruleMatchCount = 0
    var candidateCount = 0
    var autoConfirmCount = 0
    var autoSuppressCount = 0
    var needsReviewCount = 0
    var llmEvaluationCount = 0
}

struct SubscriptionEvidenceLLMContribution: Sendable {
    let providerKind: AIProviderKind?
    let promptVersion: Int
    let inputFingerprint: String
    let outputJSON: String
    let score: Double
    let factor: SubscriptionEvidenceFactor
}

struct DetectionSingleChargeCandidate {
    let transaction: NormalizedTransaction
    let canonicalName: String
    let displayName: String
    let rule: SubscriptionReviewRule?
    let correction: MerchantCorrection?
}

struct DetectionSuppressionRequest {
    let canonicalName: String
    let displayName: String
    let source: SubscriptionDetectionSource
    let hadRecurringSignals: Bool
    let reason: String
    let importRecordIDs: Set<UUID>
}

struct DetectedSubscriptionUpdateContext {
    let summary: SubscriptionSummary
    let cluster: SubscriptionCandidateCluster
    let rule: SubscriptionReviewRule?
    let correction: MerchantCorrection?
    let resolution: DetectedSubscriptionResolution
}

struct DetectedSubscriptionResolution {
    let cadence: SubscriptionCadence
    let priceAmount: Decimal
    let priceCurrency: String
    let status: SubscriptionStatus
    let category: String?
    let displayName: String
    let lastChargeDate: Date?
    let nextChargeDate: Date?
    let normalizedMonthlyAmount: Decimal

    init(
        summary: SubscriptionSummary,
        rule: SubscriptionReviewRule?,
        cadence: SubscriptionCadence,
        lastChargeDate: Date?,
        nextChargeDate: Date?,
        normalizedMonthlyAmount: Decimal
    ) {
        self.cadence = cadence
        priceAmount = rule?.overridePriceAmount ?? summary.priceAmount
        priceCurrency = rule?.overridePriceCurrency?.nilIfBlank ?? summary.currency
        status = rule?.overrideStatus ?? summary.status
        category = rule?.overrideCategory ?? summary.category
        displayName = rule?.overrideDisplayName?.nilIfBlank ?? summary.displayName
        self.lastChargeDate = lastChargeDate
        self.nextChargeDate = nextChargeDate
        self.normalizedMonthlyAmount = normalizedMonthlyAmount
    }
}

struct TextSignal {
    let combined: String
    let tokens: Set<String>
}
