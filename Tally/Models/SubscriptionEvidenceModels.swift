import Foundation
import SwiftData

enum SourceTransactionIdentityStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case posted
    case tombstoned

    var id: String { rawValue }
}

enum SubscriptionAnchorPolicy: String, Codable, CaseIterable, Identifiable {
    case exactDayOfMonth
    case endOfMonth
    case nthWeekday
    case sameWeekday
    case sameCalendarDate
    case rollingInterval
    case unknown

    var id: String { rawValue }
}

enum SubscriptionMatchRuleSource: String, Codable, CaseIterable, Identifiable {
    case reviewRule
    case userCorrection
    case confirmedSubscription
    case detectedCandidate
    case hiddenSuggestion
    case serviceProfile

    var id: String { rawValue }
}

enum SubscriptionOccurrenceStatus: String, Codable, CaseIterable, Identifiable {
    case pending
    case matched
    case missed
    case late
    case early
    case priceChanged
    case duplicateInCycle
    case manualConfirmed
    case manualRejected

    var id: String { rawValue }
}

enum SubscriptionEvidenceDecision: String, Codable, CaseIterable, Identifiable {
    case autoConfirmed
    case autoSuppressed
    case needsReview
    case ruleMatched
    case ruleRejected
    case occurrenceMatched
    case occurrenceMissed
    case priceChanged
    case merchantCollision

    var id: String { rawValue }
}

enum DetectionRunTrigger: String, Codable, CaseIterable, Identifiable {
    case importCommit
    case sync
    case correction
    case ruleReplay
    case rebuild

    var id: String { rawValue }
}

struct SubscriptionEvidenceFactor: Codable, Hashable, Sendable {
    var key: String
    var weight: Double
    var score: Double
    var source: String
    var description: String
}

@Model
final class SourceTransactionIdentity {
    var id: UUID = UUID()
    var normalizedTransactionID: UUID?
    var sourceRawValue: String = TransactionSource.manualImport.rawValue
    var externalTransactionID: String?
    var externalAccountID: String?
    var sourceReferenceID: String?
    var sourceFingerprint: String = ""
    var pendingExternalTransactionID: String?
    var statusRawValue: String = SourceTransactionIdentityStatus.posted.rawValue
    var firstSeenAt: Date = Date.now
    var lastSeenAt: Date = Date.now

    init(
        id: UUID = UUID(),
        normalizedTransactionID: UUID? = nil,
        source: TransactionSource = .manualImport,
        externalTransactionID: String? = nil,
        externalAccountID: String? = nil,
        sourceReferenceID: String? = nil,
        sourceFingerprint: String,
        pendingExternalTransactionID: String? = nil,
        status: SourceTransactionIdentityStatus = .posted,
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now
    ) {
        self.id = id
        self.normalizedTransactionID = normalizedTransactionID
        sourceRawValue = source.rawValue
        self.externalTransactionID = externalTransactionID
        self.externalAccountID = externalAccountID
        self.sourceReferenceID = sourceReferenceID
        self.sourceFingerprint = sourceFingerprint
        self.pendingExternalTransactionID = pendingExternalTransactionID
        statusRawValue = status.rawValue
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRawValue) ?? .manualImport }
        set { sourceRawValue = newValue.rawValue }
    }

    var status: SourceTransactionIdentityStatus {
        get { SourceTransactionIdentityStatus(rawValue: statusRawValue) ?? .posted }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class MerchantIdentity {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var displayName: String = ""
    var serviceProfileID: UUID?
    var confidence: Double = 0
    var rankedTokensJSON: String = "[]"
    var negativeTokensJSON: String = "[]"
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        canonicalName: String,
        displayName: String? = nil,
        serviceProfileID: UUID? = nil,
        confidence: Double = 0,
        rankedTokensJSON: String = "[]",
        negativeTokensJSON: String = "[]",
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.displayName = displayName ?? canonicalName
        self.serviceProfileID = serviceProfileID
        self.confidence = confidence
        self.rankedTokensJSON = rankedTokensJSON
        self.negativeTokensJSON = negativeTokensJSON
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class MerchantIdentityMember {
    var id: UUID = UUID()
    var merchantIdentityID: UUID = UUID()
    var rawMerchant: String = ""
    var normalizedMerchant: String = ""
    var memoFingerprint: String?
    var accountName: String?
    var sourceRawValue: String?
    var firstSeenAt: Date = Date.now
    var lastSeenAt: Date = Date.now
    var evidenceCount: Int = 0
    var confidence: Double = 0

    init(
        id: UUID = UUID(),
        merchantIdentityID: UUID,
        rawMerchant: String,
        normalizedMerchant: String,
        memoFingerprint: String? = nil,
        accountName: String? = nil,
        sourceRawValue: String? = nil,
        firstSeenAt: Date = .now,
        lastSeenAt: Date = .now,
        evidenceCount: Int = 0,
        confidence: Double = 0
    ) {
        self.id = id
        self.merchantIdentityID = merchantIdentityID
        self.rawMerchant = rawMerchant
        self.normalizedMerchant = normalizedMerchant
        self.memoFingerprint = memoFingerprint
        self.accountName = accountName
        self.sourceRawValue = sourceRawValue
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.evidenceCount = evidenceCount
        self.confidence = confidence
    }
}

@Model
final class ServiceProfile {
    var id: UUID = UUID()
    var canonicalName: String = ""
    var aliasesJSON: String = "[]"
    var domainsJSON: String = "[]"
    var processorPatternsJSON: String = "[]"
    var categoryHint: String = "Uncategorized"
    var merchantKindRawValue: String = MerchantKind.unknown.rawValue
    var commonCadencesJSON: String = "[]"
    var priceBandsJSON: String = "[]"
    var cancellationURL: String?
    var websiteURL: String?
    var logoIdentifier: String?
    var confidencePrior: Double = 0
    var catalogVersion: Int = 1

    init(
        id: UUID = UUID(),
        canonicalName: String,
        aliasesJSON: String = "[]",
        domainsJSON: String = "[]",
        processorPatternsJSON: String = "[]",
        categoryHint: String = "Uncategorized",
        merchantKind: MerchantKind = .unknown,
        commonCadencesJSON: String = "[]",
        priceBandsJSON: String = "[]",
        cancellationURL: String? = nil,
        websiteURL: String? = nil,
        logoIdentifier: String? = nil,
        confidencePrior: Double = 0,
        catalogVersion: Int = 1
    ) {
        self.id = id
        self.canonicalName = canonicalName
        self.aliasesJSON = aliasesJSON
        self.domainsJSON = domainsJSON
        self.processorPatternsJSON = processorPatternsJSON
        self.categoryHint = categoryHint
        merchantKindRawValue = merchantKind.rawValue
        self.commonCadencesJSON = commonCadencesJSON
        self.priceBandsJSON = priceBandsJSON
        self.cancellationURL = cancellationURL
        self.websiteURL = websiteURL
        self.logoIdentifier = logoIdentifier
        self.confidencePrior = confidencePrior
        self.catalogVersion = catalogVersion
    }

    var merchantKind: MerchantKind {
        get { MerchantKind(rawValue: merchantKindRawValue) ?? .unknown }
        set { merchantKindRawValue = newValue.rawValue }
    }
}

@Model
final class SubscriptionScheduleExpectation {
    var id: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var cadenceRawValue: String = SubscriptionCadence.unknown.rawValue
    var interval: Int = 1
    var anchorPolicyRawValue: String = SubscriptionAnchorPolicy.unknown.rawValue
    var anchorDay: Int?
    var anchorWeekday: Int?
    var anchorOrdinal: Int?
    var dateToleranceBeforeDays: Int = 3
    var dateToleranceAfterDays: Int = 3
    var gracePeriodDays: Int = 5
    var confidence: Double = 0
    var sourceRawValue: String = SubscriptionMatchRuleSource.detectedCandidate.rawValue
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        cadence: SubscriptionCadence,
        interval: Int = 1,
        anchorPolicy: SubscriptionAnchorPolicy = .unknown,
        anchorDay: Int? = nil,
        anchorWeekday: Int? = nil,
        anchorOrdinal: Int? = nil,
        dateToleranceBeforeDays: Int = 3,
        dateToleranceAfterDays: Int = 3,
        gracePeriodDays: Int = 5,
        confidence: Double = 0,
        source: SubscriptionMatchRuleSource = .detectedCandidate,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        cadenceRawValue = cadence.rawValue
        self.interval = max(1, interval)
        anchorPolicyRawValue = anchorPolicy.rawValue
        self.anchorDay = anchorDay
        self.anchorWeekday = anchorWeekday
        self.anchorOrdinal = anchorOrdinal
        self.dateToleranceBeforeDays = dateToleranceBeforeDays
        self.dateToleranceAfterDays = dateToleranceAfterDays
        self.gracePeriodDays = gracePeriodDays
        self.confidence = confidence
        sourceRawValue = source.rawValue
        self.updatedAt = updatedAt
    }

    var cadence: SubscriptionCadence {
        get { SubscriptionCadence(rawValue: cadenceRawValue) ?? .unknown }
        set { cadenceRawValue = newValue.rawValue }
    }

    var anchorPolicy: SubscriptionAnchorPolicy {
        get { SubscriptionAnchorPolicy(rawValue: anchorPolicyRawValue) ?? .unknown }
        set { anchorPolicyRawValue = newValue.rawValue }
    }

    var source: SubscriptionMatchRuleSource {
        get { SubscriptionMatchRuleSource(rawValue: sourceRawValue) ?? .detectedCandidate }
        set { sourceRawValue = newValue.rawValue }
    }
}

@Model
final class SubscriptionMatchRule {
    var id: UUID = UUID()
    var subscriptionID: UUID?
    var canonicalName: String = ""
    var merchantIdentityID: UUID?
    var serviceProfileID: UUID?
    var allowedRawMerchantsJSON: String = "[]"
    var requiredTokensJSON: String = "[]"
    var excludedTokensJSON: String = "[]"
    var amountMinimum: Decimal?
    var amountMaximum: Decimal?
    var amountMedian: Decimal?
    var amountTolerancePercent: Double = 0.12
    var currencyCode: String?
    var accountHint: String?
    var sourceHintRawValue: String?
    var scheduleExpectationID: UUID?
    var priority: Int = 0
    var confidence: Double = 0
    var isNegativeRule: Bool = false
    var createdFromRawValue: String = SubscriptionMatchRuleSource.detectedCandidate.rawValue
    var lastReplayAt: Date?
    var replayMatchCount: Int = 0
    var replayCollisionCount: Int = 0
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        subscriptionID: UUID? = nil,
        canonicalName: String,
        merchantIdentityID: UUID? = nil,
        serviceProfileID: UUID? = nil,
        allowedRawMerchantsJSON: String = "[]",
        requiredTokensJSON: String = "[]",
        excludedTokensJSON: String = "[]",
        amountMinimum: Decimal? = nil,
        amountMaximum: Decimal? = nil,
        amountMedian: Decimal? = nil,
        amountTolerancePercent: Double = 0.12,
        currencyCode: String? = nil,
        accountHint: String? = nil,
        sourceHint: TransactionSource? = nil,
        scheduleExpectationID: UUID? = nil,
        priority: Int = 0,
        confidence: Double = 0,
        isNegativeRule: Bool = false,
        createdFrom: SubscriptionMatchRuleSource = .detectedCandidate,
        lastReplayAt: Date? = nil,
        replayMatchCount: Int = 0,
        replayCollisionCount: Int = 0,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.canonicalName = canonicalName
        self.merchantIdentityID = merchantIdentityID
        self.serviceProfileID = serviceProfileID
        self.allowedRawMerchantsJSON = allowedRawMerchantsJSON
        self.requiredTokensJSON = requiredTokensJSON
        self.excludedTokensJSON = excludedTokensJSON
        self.amountMinimum = amountMinimum
        self.amountMaximum = amountMaximum
        self.amountMedian = amountMedian
        self.amountTolerancePercent = amountTolerancePercent
        self.currencyCode = currencyCode
        self.accountHint = accountHint
        sourceHintRawValue = sourceHint?.rawValue
        self.scheduleExpectationID = scheduleExpectationID
        self.priority = priority
        self.confidence = confidence
        self.isNegativeRule = isNegativeRule
        createdFromRawValue = createdFrom.rawValue
        self.lastReplayAt = lastReplayAt
        self.replayMatchCount = replayMatchCount
        self.replayCollisionCount = replayCollisionCount
        self.updatedAt = updatedAt
    }

    var sourceHint: TransactionSource? {
        get { sourceHintRawValue.flatMap(TransactionSource.init(rawValue:)) }
        set { sourceHintRawValue = newValue?.rawValue }
    }

    var createdFrom: SubscriptionMatchRuleSource {
        get { SubscriptionMatchRuleSource(rawValue: createdFromRawValue) ?? .detectedCandidate }
        set { createdFromRawValue = newValue.rawValue }
    }
}

@Model
final class SubscriptionOccurrence {
    var id: UUID = UUID()
    var subscriptionID: UUID = UUID()
    var scheduleExpectationID: UUID?
    var expectedDate: Date = Date.now
    var windowStartDate: Date = Date.now
    var windowEndDate: Date = Date.now
    var matchedTransactionID: UUID?
    var statusRawValue: String = SubscriptionOccurrenceStatus.pending.rawValue
    var observedDate: Date?
    var observedAmount: Decimal?
    var expectedAmount: Decimal?
    var dateDeltaDays: Int?
    var amountDeltaPercent: Double?
    var matchConfidence: Double = 0
    var evidenceID: UUID?
    var createdByDetectionRunID: UUID?
    var updatedAt: Date = Date.now

    init(
        id: UUID = UUID(),
        subscriptionID: UUID,
        scheduleExpectationID: UUID? = nil,
        expectedDate: Date,
        windowStartDate: Date,
        windowEndDate: Date,
        matchedTransactionID: UUID? = nil,
        status: SubscriptionOccurrenceStatus,
        observedDate: Date? = nil,
        observedAmount: Decimal? = nil,
        expectedAmount: Decimal? = nil,
        dateDeltaDays: Int? = nil,
        amountDeltaPercent: Double? = nil,
        matchConfidence: Double = 0,
        evidenceID: UUID? = nil,
        createdByDetectionRunID: UUID? = nil,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.subscriptionID = subscriptionID
        self.scheduleExpectationID = scheduleExpectationID
        self.expectedDate = expectedDate
        self.windowStartDate = windowStartDate
        self.windowEndDate = windowEndDate
        self.matchedTransactionID = matchedTransactionID
        statusRawValue = status.rawValue
        self.observedDate = observedDate
        self.observedAmount = observedAmount
        self.expectedAmount = expectedAmount
        self.dateDeltaDays = dateDeltaDays
        self.amountDeltaPercent = amountDeltaPercent
        self.matchConfidence = matchConfidence
        self.evidenceID = evidenceID
        self.createdByDetectionRunID = createdByDetectionRunID
        self.updatedAt = updatedAt
    }

    var status: SubscriptionOccurrenceStatus {
        get { SubscriptionOccurrenceStatus(rawValue: statusRawValue) ?? .pending }
        set { statusRawValue = newValue.rawValue }
    }
}

@Model
final class SubscriptionDetectionEvidence {
    var id: UUID = UUID()
    var detectionRunID: UUID?
    var subscriptionID: UUID?
    var candidateKey: String = ""
    var decisionRawValue: String = SubscriptionEvidenceDecision.needsReview.rawValue
    var confidence: Double = 0
    var deterministicScore: Double = 0
    var llmScore: Double?
    var evidenceFactorsJSON: String = "[]"
    var matchedTransactionIDsJSON: String = "[]"
    var rejectedTransactionIDsJSON: String = "[]"
    var ruleIDsJSON: String = "[]"
    var serviceProfileID: UUID?
    var merchantIdentityID: UUID?
    var llmProviderRawValue: String?
    var llmPromptVersion: Int?
    var llmInputFingerprint: String?
    var llmOutputJSON: String?
    var reason: String = ""
    var createdAt: Date = Date.now

    init(
        id: UUID = UUID(),
        detectionRunID: UUID? = nil,
        subscriptionID: UUID? = nil,
        candidateKey: String,
        decision: SubscriptionEvidenceDecision,
        confidence: Double,
        deterministicScore: Double,
        llmScore: Double? = nil,
        evidenceFactorsJSON: String = "[]",
        matchedTransactionIDsJSON: String = "[]",
        rejectedTransactionIDsJSON: String = "[]",
        ruleIDsJSON: String = "[]",
        serviceProfileID: UUID? = nil,
        merchantIdentityID: UUID? = nil,
        llmProviderRawValue: String? = nil,
        llmPromptVersion: Int? = nil,
        llmInputFingerprint: String? = nil,
        llmOutputJSON: String? = nil,
        reason: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.detectionRunID = detectionRunID
        self.subscriptionID = subscriptionID
        self.candidateKey = candidateKey
        decisionRawValue = decision.rawValue
        self.confidence = confidence
        self.deterministicScore = deterministicScore
        self.llmScore = llmScore
        self.evidenceFactorsJSON = evidenceFactorsJSON
        self.matchedTransactionIDsJSON = matchedTransactionIDsJSON
        self.rejectedTransactionIDsJSON = rejectedTransactionIDsJSON
        self.ruleIDsJSON = ruleIDsJSON
        self.serviceProfileID = serviceProfileID
        self.merchantIdentityID = merchantIdentityID
        self.llmProviderRawValue = llmProviderRawValue
        self.llmPromptVersion = llmPromptVersion
        self.llmInputFingerprint = llmInputFingerprint
        self.llmOutputJSON = llmOutputJSON
        self.reason = reason
        self.createdAt = createdAt
    }

    var decision: SubscriptionEvidenceDecision {
        get { SubscriptionEvidenceDecision(rawValue: decisionRawValue) ?? .needsReview }
        set { decisionRawValue = newValue.rawValue }
    }
}

@Model
final class DetectionRun {
    var id: UUID = UUID()
    var triggerRawValue: String = DetectionRunTrigger.rebuild.rawValue
    var startedAt: Date = Date.now
    var finishedAt: Date?
    var transactionCount: Int = 0
    var ruleMatchCount: Int = 0
    var candidateCount: Int = 0
    var autoConfirmCount: Int = 0
    var autoSuppressCount: Int = 0
    var needsReviewCount: Int = 0
    var llmEvaluationCount: Int = 0
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        trigger: DetectionRunTrigger = .rebuild,
        startedAt: Date = .now,
        finishedAt: Date? = nil,
        transactionCount: Int = 0,
        ruleMatchCount: Int = 0,
        candidateCount: Int = 0,
        autoConfirmCount: Int = 0,
        autoSuppressCount: Int = 0,
        needsReviewCount: Int = 0,
        llmEvaluationCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        triggerRawValue = trigger.rawValue
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.transactionCount = transactionCount
        self.ruleMatchCount = ruleMatchCount
        self.candidateCount = candidateCount
        self.autoConfirmCount = autoConfirmCount
        self.autoSuppressCount = autoSuppressCount
        self.needsReviewCount = needsReviewCount
        self.llmEvaluationCount = llmEvaluationCount
        self.errorMessage = errorMessage
    }

    var trigger: DetectionRunTrigger {
        get { DetectionRunTrigger(rawValue: triggerRawValue) ?? .rebuild }
        set { triggerRawValue = newValue.rawValue }
    }
}

enum SubscriptionEvidenceJSON {
    static func encodeStrings(_ values: [String]) -> String {
        encode(values)
    }

    static func encodeUUIDs(_ values: [UUID]) -> String {
        encode(values.map(\.uuidString))
    }

    static func encodeFactors(_ factors: [SubscriptionEvidenceFactor]) -> String {
        encode(factors)
    }

    static func decodeStrings(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8) else {
            return []
        }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func encode<T: Encodable>(_ value: T) -> String {
        guard let data = try? JSONEncoder().encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }
}
