import Foundation
import SwiftData

@Model
final class NormalizedTransaction {
    var id: UUID = UUID()
    var transactionDate: Date = Date.now
    var transactionAmount: Decimal = 0
    var sourceRawValue: String = TransactionSource.manualImport.rawValue
    var merchantRaw: String = ""
    var merchantNormalized: String = ""
    var currency: String?
    var accountName: String?
    var category: String?
    var memo: String?
    var classificationConfidence: Double = 0
    var merchantKindRawValue: String = MerchantKind.unknown.rawValue
    var merchantSubscriptionAffinity: Double = 0
    var importRecordID: UUID?
    var subscriptionID: UUID?
    var externalTransactionID: String?
    var externalAccountID: String?
    var sourceReferenceID: String?
    var sourceFingerprint: String?
    var pendingExternalTransactionID: String?
    var sourceMetadataJSON: String?

    init(
        id: UUID = UUID(),
        transactionDate: Date,
        transactionAmount: Decimal,
        source: TransactionSource = .manualImport,
        merchantRaw: String,
        merchantNormalized: String,
        currency: String? = nil,
        accountName: String? = nil,
        category: String? = nil,
        memo: String? = nil,
        merchantKind: MerchantKind = .unknown,
        merchantSubscriptionAffinity: Double = 0,
        importRecordID: UUID? = nil,
        subscriptionID: UUID? = nil,
        externalTransactionID: String? = nil,
        externalAccountID: String? = nil,
        sourceReferenceID: String? = nil,
        sourceFingerprint: String? = nil,
        pendingExternalTransactionID: String? = nil,
        sourceMetadataJSON: String? = nil
    ) {
        self.id = id
        self.transactionDate = transactionDate
        self.transactionAmount = transactionAmount
        sourceRawValue = source.rawValue
        self.merchantRaw = merchantRaw
        self.merchantNormalized = merchantNormalized
        self.currency = currency
        self.accountName = accountName
        self.category = category
        self.memo = memo
        classificationConfidence = 0
        merchantKindRawValue = merchantKind.rawValue
        self.merchantSubscriptionAffinity = merchantSubscriptionAffinity
        self.importRecordID = importRecordID
        self.subscriptionID = subscriptionID
        self.externalTransactionID = externalTransactionID
        self.externalAccountID = externalAccountID
        self.sourceReferenceID = sourceReferenceID
        self.sourceFingerprint = sourceFingerprint
        self.pendingExternalTransactionID = pendingExternalTransactionID
        self.sourceMetadataJSON = sourceMetadataJSON
    }

    var source: TransactionSource {
        get { TransactionSource(rawValue: sourceRawValue) ?? .manualImport }
        set { sourceRawValue = newValue.rawValue }
    }

    var merchantKind: MerchantKind {
        get { MerchantKind(rawValue: merchantKindRawValue) ?? .unknown }
        set { merchantKindRawValue = newValue.rawValue }
    }
}
