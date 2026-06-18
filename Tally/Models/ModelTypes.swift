import Foundation

enum SubscriptionStatus: String, Codable, CaseIterable, Identifiable {
    case active
    case former
    case needsReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active:
            return "Active"
        case .former:
            return "Former"
        case .needsReview:
            return "Needs Review"
        }
    }
}

enum SubscriptionCadence: String, Codable, CaseIterable, Identifiable {
    case monthly
    case annual
    case quarterly
    case semiannual
    case biweekly
    case weekly
    case unknown

    var id: String { rawValue }

    var cycleDays: Int? {
        switch self {
        case .monthly:
            return 30
        case .annual:
            return 365
        case .quarterly:
            return 91
        case .semiannual:
            return 182
        case .biweekly:
            return 14
        case .weekly:
            return 7
        case .unknown:
            return nil
        }
    }

    var monthDivisor: Decimal? {
        switch self {
        case .monthly:
            return 1
        case .annual:
            return 12
        case .quarterly:
            return 3
        case .semiannual:
            return 6
        case .biweekly:
            return Decimal(string: "0.461538") // 12 / 26
        case .weekly:
            return Decimal(string: "0.230769") // 12 / 52
        case .unknown:
            return nil
        }
    }

    func advance(_ date: Date, using calendar: Calendar = .current) -> Date? {
        guard self != .unknown else { return nil }
        return tallyAdvanced(date, by: 1, using: calendar)
    }
}

enum ImportStatus: String, Codable {
    case queued
    case parsing
    case classifying
    case analyzed
    case failed
    case needsMapping

    var title: String {
        switch self {
        case .queued:
            return "Queued"
        case .parsing:
            return "Parsing"
        case .classifying:
            return "Classifying"
        case .analyzed:
            return "Analyzed"
        case .failed:
            return "Failed"
        case .needsMapping:
            return "Needs Mapping"
        }
    }
}

enum DebitSign: String, Codable, CaseIterable, Identifiable, Sendable {
    case negative
    case positive

    var id: String { rawValue }
}

enum TransactionSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case manualImport
    case qfx
    case ofx
    case simpleFIN
    case plaid
    case receipt
    case emailExport

    var id: String { rawValue }

    var title: String {
        switch self {
        case .manualImport:
            return "Manual Import"
        case .qfx:
            return "QFX"
        case .ofx:
            return "OFX"
        case .simpleFIN:
            return "SimpleFIN"
        case .plaid:
            return "Plaid"
        case .receipt:
            return "Receipt"
        case .emailExport:
            return "Email Export"
        }
    }
}

struct ColumnMappingConfig: Codable, Hashable, Sendable {
    var dateColumn: String
    var descriptionColumn: String?
    var amountColumn: String
    var merchantColumn: String?
    var categoryColumn: String?
    var accountColumn: String?
    var currencyColumn: String?
    var debitSignConvention: DebitSign

    var signature: String {
        [
            dateColumn,
            descriptionColumn ?? "",
            amountColumn,
            merchantColumn ?? "",
            categoryColumn ?? "",
            accountColumn ?? "",
            currencyColumn ?? "",
            debitSignConvention.rawValue
        ].joined(separator: "|")
    }
}

enum MerchantKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case subscriptionService = "subscription_service"
    case membershipRetailer = "membership_retailer"
    case marketplace = "marketplace"
    case groceryRetailer = "grocery_retailer"
    case restaurant = "restaurant"
    case medicalOrWellnessProvider = "medical_or_wellness_provider"
    case transportOrTravel = "transport_or_travel"
    case utilityOrBiller = "utility_or_biller"
    case generalRetail = "general_retail"
    case softwareOrSaaS = "software_or_saas"
    case mediaStreaming = "media_streaming"
    case unknown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subscriptionService: return "Subscription Service"
        case .membershipRetailer: return "Membership Retailer"
        case .marketplace: return "Marketplace"
        case .groceryRetailer: return "Grocery Retailer"
        case .restaurant: return "Restaurant"
        case .medicalOrWellnessProvider: return "Medical or Wellness Provider"
        case .transportOrTravel: return "Transport or Travel"
        case .utilityOrBiller: return "Utility or Biller"
        case .generalRetail: return "General Retail"
        case .softwareOrSaaS: return "Software or SaaS"
        case .mediaStreaming: return "Media Streaming"
        case .unknown: return "Unknown"
        }
    }

    var defaultServiceCategory: String {
        switch self {
        case .subscriptionService: return "Subscription"
        case .membershipRetailer: return "Membership"
        case .marketplace: return "Marketplace"
        case .groceryRetailer: return "Groceries"
        case .restaurant: return "Dining"
        case .medicalOrWellnessProvider: return "Health"
        case .transportOrTravel: return "Travel"
        case .utilityOrBiller: return "Utilities"
        case .generalRetail: return "Retail"
        case .softwareOrSaaS: return "Software"
        case .mediaStreaming: return "Streaming"
        case .unknown: return "Uncategorized"
        }
    }

    var defaultSubscriptionAffinity: Double {
        switch self {
        case .subscriptionService, .mediaStreaming: return 0.95
        case .softwareOrSaaS: return 0.88
        case .utilityOrBiller: return 0.6
        case .membershipRetailer: return 0.35
        case .marketplace: return 0.12
        case .groceryRetailer: return 0.08
        case .restaurant: return 0.05
        case .medicalOrWellnessProvider: return 0.1
        case .transportOrTravel: return 0.15
        case .generalRetail: return 0.12
        case .unknown: return 0.4
        }
    }

    var isUsuallyNonSubscription: Bool {
        switch self {
        case .marketplace,
             .groceryRetailer,
             .restaurant,
             .medicalOrWellnessProvider,
             .transportOrTravel,
             .utilityOrBiller,
             .generalRetail:
            return true
        case .subscriptionService,
             .membershipRetailer,
             .softwareOrSaaS,
             .mediaStreaming,
             .unknown:
            return false
        }
    }
}

struct MerchantClassificationResult: Codable, Hashable, Sendable {
    var canonicalName: String
    var serviceCategory: String
    var merchantKind: MerchantKind
    var subscriptionAffinity: Double
    var confidence: Double
}

struct RecurringClusterEvaluationInput: Hashable, Sendable {
    var canonicalName: String
    var displayName: String
    var rawMerchantVariants: [String]
    var sampleMemos: [String]
    var sampleCategories: [String]
    var chargeCount: Int
    var intervals: [Int]
    var firstChargeDate: Date?
    var lastChargeDate: Date?
    var amountMinimum: Double
    var amountMaximum: Double
    var amountVariation: Double
    var detectedCadence: SubscriptionCadence
    var merchantKind: MerchantKind
    var subscriptionAffinity: Double
    var classificationConfidence: Double
    var intervalConsistency: Double
    var amountStability: Double
    var keywordSupport: Double
    var descriptorStrength: Double
    var negativePenalty: Double
}

struct RecurringClusterEvaluationResult: Hashable, Sendable {
    var isSubscription: Bool
    var confidence: Double
    var reasonSummary: String
    var negativeSignals: [String]
}

struct SingleChargeEvaluationInput: Hashable, Sendable {
    var canonicalName: String
    var displayName: String
    var rawMerchant: String
    var memo: String?
    var category: String?
    var amount: Decimal
    var transactionDate: Date
    var merchantKind: MerchantKind
    var subscriptionAffinity: Double
    var classificationConfidence: Double
    var suggestedCadence: SubscriptionCadence
}

struct SingleChargeEvaluationResult: Hashable, Sendable {
    var isLikelySubscription: Bool
    var confidence: Double
    var reasonSummary: String
    var negativeSignals: [String]
}

struct SubscriptionEvidenceEvaluationInput: Codable, Hashable, Sendable {
    var candidateKey: String
    var canonicalName: String
    var displayName: String
    var rawMerchantVariants: [String]
    var memoSamples: [String]
    var categorySamples: [String]
    var serviceProfileName: String?
    var merchantKind: MerchantKind
    var subscriptionAffinity: Double
    var scheduleSummary: String
    var occurrenceSummary: String
    var amountSummary: String
    var negativeSignals: [String]
    var userRuleSummary: String?
}

struct SubscriptionEvidenceEvaluationResult: Codable, Hashable, Sendable {
    var isSubscription: Bool
    var confidence: Double
    var likelyServiceName: String?
    var likelyPlanDescriptor: String?
    var positiveSignals: [String]
    var negativeSignals: [String]
    var reasonSummary: String
}

enum AuditAction: String, Codable, CaseIterable, Identifiable {
    case keep
    case review
    case cancel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keep: return "Keep"
        case .review: return "Review"
        case .cancel: return "Cancel"
        }
    }
}

enum AppearanceOption: String, CaseIterable, Identifiable {
    case light
    case system
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .system:
            return "System"
        case .dark:
            return "Dark"
        }
    }

    var detail: String {
        switch self {
        case .light:
            return "Warm linen surfaces and editorial contrast."
        case .system:
            return "Follow the Mac appearance automatically."
        case .dark:
            return "Warm charcoal surfaces for lower-light work."
        }
    }
}
