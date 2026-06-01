import Foundation

struct AppDataExportSource {
    let imports: [ImportRecord]
    let subscriptions: [Subscription]
    let transactions: [NormalizedTransaction]
    let classifications: [MerchantClassification]
    let aliases: [MerchantAlias]
    let templates: [ColumnMappingTemplate]
    let reviewRules: [SubscriptionReviewRule]
}

struct AppDataExporter {
    func exportData(from source: AppDataExportSource) throws -> Data {
        let payload = AppDataExportPayload(
            exportedAt: .now,
            imports: source.imports.map(AppDataExportPayload.ImportSnapshot.init),
            subscriptions: source.subscriptions.map(AppDataExportPayload.SubscriptionSnapshot.init),
            transactions: source.transactions.map(AppDataExportPayload.TransactionSnapshot.init),
            classifications: source.classifications.map(AppDataExportPayload.ClassificationSnapshot.init),
            aliases: source.aliases.map(AppDataExportPayload.AliasSnapshot.init),
            columnTemplates: source.templates.map(AppDataExportPayload.TemplateSnapshot.init),
            reviewRules: source.reviewRules.map(AppDataExportPayload.ReviewRuleSnapshot.init)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(payload)
    }
}

private struct AppDataExportPayload: Codable {
    let exportedAt: Date
    let imports: [ImportSnapshot]
    let subscriptions: [SubscriptionSnapshot]
    let transactions: [TransactionSnapshot]
    let classifications: [ClassificationSnapshot]
    let aliases: [AliasSnapshot]
    let columnTemplates: [TemplateSnapshot]
    let reviewRules: [ReviewRuleSnapshot]

    struct ImportSnapshot: Codable {
        let id: UUID
        let fileName: String
        let importedAt: Date
        let sourceType: String
        let status: String
        let mappingSignature: String
        let importedTransactionCount: Int
        let detectedSubscriptionCount: Int
        let needsReviewSubscriptionCount: Int
        let suppressedRecurringCandidateCount: Int
        let recoveredRecurringCandidateCount: Int
        let errorMessage: String?

        init(_ record: ImportRecord) {
            id = record.id
            fileName = record.fileName
            importedAt = record.importedAt
            sourceType = record.sourceType
            status = record.status.rawValue
            mappingSignature = record.mappingSignature
            importedTransactionCount = record.importedTransactionCount
            detectedSubscriptionCount = record.detectedSubscriptionCount
            needsReviewSubscriptionCount = record.needsReviewSubscriptionCount
            suppressedRecurringCandidateCount = record.suppressedRecurringCandidateCount
            recoveredRecurringCandidateCount = record.recoveredRecurringCandidateCount
            errorMessage = record.errorMessage
        }
    }

    struct SubscriptionSnapshot: Codable {
        let id: UUID
        let displayName: String
        let canonicalName: String
        let status: String
        let cadence: String
        let priceAmount: Decimal
        let priceCurrency: String
        let normalizedMonthlyAmount: Decimal
        let lastChargeDate: Date?
        let predictedNextChargeDate: Date?
        let confidenceScore: Double
        let serviceCategory: String?
        let detectionReason: String?

        init(_ subscription: Subscription) {
            id = subscription.id
            displayName = subscription.displayName
            canonicalName = subscription.canonicalName
            status = subscription.status.rawValue
            cadence = subscription.cadence.rawValue
            priceAmount = subscription.priceAmount
            priceCurrency = subscription.priceCurrency
            normalizedMonthlyAmount = subscription.normalizedMonthlyAmount
            lastChargeDate = subscription.lastChargeDate
            predictedNextChargeDate = subscription.predictedNextChargeDate
            confidenceScore = subscription.confidenceScore
            serviceCategory = subscription.serviceCategory
            detectionReason = subscription.detectionReason
        }
    }

    struct TransactionSnapshot: Codable {
        let id: UUID
        let transactionDate: Date
        let transactionAmount: Decimal
        let merchantRaw: String
        let merchantNormalized: String
        let currency: String?
        let accountName: String?
        let category: String?
        let memo: String?
        let merchantKind: String
        let merchantSubscriptionAffinity: Double
        let classificationConfidence: Double
        let subscriptionID: UUID?
        let importRecordID: UUID?

        init(_ transaction: NormalizedTransaction) {
            id = transaction.id
            transactionDate = transaction.transactionDate
            transactionAmount = transaction.transactionAmount
            merchantRaw = transaction.merchantRaw
            merchantNormalized = transaction.merchantNormalized
            currency = transaction.currency
            accountName = transaction.accountName
            category = transaction.category
            memo = transaction.memo
            merchantKind = transaction.merchantKind.rawValue
            merchantSubscriptionAffinity = transaction.merchantSubscriptionAffinity
            classificationConfidence = transaction.classificationConfidence
            subscriptionID = transaction.subscriptionID
            importRecordID = transaction.importRecordID
        }
    }

    struct ClassificationSnapshot: Codable {
        let rawMerchant: String
        let canonicalName: String
        let serviceCategory: String
        let merchantKind: String
        let subscriptionAffinity: Double
        let confidence: Double

        init(_ classification: MerchantClassification) {
            rawMerchant = classification.rawMerchant
            canonicalName = classification.canonicalName
            serviceCategory = classification.serviceCategory
            merchantKind = classification.merchantKind.rawValue
            subscriptionAffinity = classification.subscriptionAffinity
            confidence = classification.confidence
        }
    }

    struct TemplateSnapshot: Codable {
        let signature: String
        let dateColumn: String
        let descriptionColumn: String?
        let amountColumn: String
        let merchantColumn: String?
        let categoryColumn: String?
        let accountColumn: String?
        let currencyColumn: String?

        init(_ template: ColumnMappingTemplate) {
            signature = template.signature
            dateColumn = template.dateColumn
            descriptionColumn = template.descriptionColumn
            amountColumn = template.amountColumn
            merchantColumn = template.merchantColumn
            categoryColumn = template.categoryColumn
            accountColumn = template.accountColumn
            currencyColumn = template.currencyColumn
        }
    }

    struct AliasSnapshot: Codable {
        let rawMerchant: String
        let canonicalName: String
        let createdAt: Date

        init(_ alias: MerchantAlias) {
            rawMerchant = alias.rawMerchant
            canonicalName = alias.canonicalName
            createdAt = alias.createdAt
        }
    }

    struct ReviewRuleSnapshot: Codable {
        let canonicalName: String
        let overrideDisplayName: String?
        let overrideStatus: String?
        let overrideCadence: String?
        let overridePriceAmount: Decimal?
        let overridePriceCurrency: String?
        let overrideLastChargeDate: Date?
        let overrideCategory: String?
        let notes: String?
        let isFalsePositive: Bool
        let isUserConfirmed: Bool
        let updatedAt: Date

        init(_ rule: SubscriptionReviewRule) {
            canonicalName = rule.canonicalName
            overrideDisplayName = rule.overrideDisplayName
            overrideStatus = rule.overrideStatus?.rawValue
            overrideCadence = rule.overrideCadence?.rawValue
            overridePriceAmount = rule.overridePriceAmount
            overridePriceCurrency = rule.overridePriceCurrency
            overrideLastChargeDate = rule.overrideLastChargeDate
            overrideCategory = rule.overrideCategory
            notes = rule.notes
            isFalsePositive = rule.isFalsePositive
            isUserConfirmed = rule.isUserConfirmed
            updatedAt = rule.updatedAt
        }
    }
}
