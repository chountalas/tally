import Foundation
import SwiftData

@Model
final class ImportRecord {
    var id: UUID = UUID()
    var fileName: String = ""
    var importedAt: Date = Date.now
    var sourceType: String = ""
    var statusRawValue: String = ImportStatus.queued.rawValue
    var mappingSignature: String = ""
    var importedTransactionCount: Int = 0
    var detectedSubscriptionCount: Int = 0
    var needsReviewSubscriptionCount: Int = 0
    var suppressedRecurringCandidateCount: Int = 0
    var recoveredRecurringCandidateCount: Int = 0
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        fileName: String,
        importedAt: Date = Date.now,
        sourceType: String,
        status: ImportStatus,
        mappingSignature: String,
        importedTransactionCount: Int = 0,
        detectedSubscriptionCount: Int = 0,
        needsReviewSubscriptionCount: Int = 0,
        suppressedRecurringCandidateCount: Int = 0,
        recoveredRecurringCandidateCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.fileName = fileName
        self.importedAt = importedAt
        self.sourceType = sourceType
        self.statusRawValue = status.rawValue
        self.mappingSignature = mappingSignature
        self.importedTransactionCount = importedTransactionCount
        self.detectedSubscriptionCount = detectedSubscriptionCount
        self.needsReviewSubscriptionCount = needsReviewSubscriptionCount
        self.suppressedRecurringCandidateCount = suppressedRecurringCandidateCount
        self.recoveredRecurringCandidateCount = recoveredRecurringCandidateCount
        self.errorMessage = errorMessage
    }

    var status: ImportStatus {
        get { ImportStatus(rawValue: statusRawValue) ?? .queued }
        set { statusRawValue = newValue.rawValue }
    }
}
