import Foundation
import SwiftData
@testable import Tally

enum DetectionFixtureExpectedOutcome: String, Hashable {
    case confirmedPositive
    case reviewPositive
    case negative
}

struct DetectionFixtureTransaction {
    let date: String
    let amount: String
    let rawMerchant: String
    let category: String?
    let memo: String?
}

struct DetectionFixtureCase {
    let id: String
    let description: String
    let labels: [String]
    let expectedOutcome: DetectionFixtureExpectedOutcome
    let expectedCanonicalName: String?
    let expectedAdditionalCanonicalNames: [String]
    let transactions: [DetectionFixtureTransaction]

    var expectedCanonicalNames: [String] {
        [expectedCanonicalName].compactMap { $0 } + expectedAdditionalCanonicalNames
    }
}

struct DetectionFixtureCaseResult {
    let fixture: DetectionFixtureCase
    let actualOutcome: DetectionFixtureExpectedOutcome
    let matchedCanonicalName: String?
    let surfacedCanonicalNames: [String]

    var missingExpectedCanonicalNames: [String] {
        fixture.expectedCanonicalNames.filter { surfacedCanonicalNames.contains($0) == false }
    }

    var unexpectedCanonicalNames: [String] {
        surfacedCanonicalNames.filter { fixture.expectedCanonicalNames.contains($0) == false }
    }

    var matchedExpectedIdentity: Bool {
        guard fixture.expectedOutcome != .negative else {
            return false
        }

        let expectedCanonicalNames = fixture.expectedCanonicalNames
        guard expectedCanonicalNames.isEmpty == false else {
            return actualOutcome != .negative
        }

        return Set(surfacedCanonicalNames) == Set(expectedCanonicalNames)
    }

    var isTruePositive: Bool {
        fixture.expectedOutcome != .negative && actualOutcome != .negative
    }

    var isFalsePositive: Bool {
        fixture.expectedOutcome == .negative && actualOutcome != .negative
    }

    var isFalseNegative: Bool {
        fixture.expectedOutcome != .negative && actualOutcome == .negative
    }

    var reviewOverflow: Bool {
        fixture.expectedOutcome == .confirmedPositive && actualOutcome == .reviewPositive
    }

    var identityMismatch: Bool {
        guard isTruePositive else {
            return false
        }
        guard fixture.expectedCanonicalName != nil else {
            return fixture.expectedAdditionalCanonicalNames.isEmpty == false
        }
        return matchedExpectedIdentity == false
    }
}

struct DetectionFixtureMetrics {
    let totalCases: Int
    let positiveCases: Int
    let surfacedCases: Int
    let truePositives: Int
    let falsePositives: Int
    let falseNegatives: Int
    let reviewOverflowCount: Int
    let identityMismatchCount: Int
    let outcomeCounts: [DetectionFixtureExpectedOutcome: Int]
    let labelCoverage: [String: Int]
    let caseResults: [DetectionFixtureCaseResult]

    var precision: Double {
        guard surfacedCases > 0 else { return 0 }
        return Double(truePositives) / Double(surfacedCases)
    }

    var recall: Double {
        guard positiveCases > 0 else { return 0 }
        return Double(truePositives) / Double(positiveCases)
    }
}

enum SubscriptionDetectionFixtureHarness {
    static let fixtures: [DetectionFixtureCase] = [
        DetectionFixtureCase(
            id: "chatgpt_monthly",
            description: "True recurring SaaS subscription with stable monthly charges.",
            labels: ["monthly", "saas", "stable_amount"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "ChatGPT",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-10", amount: "-20.00", rawMerchant: "OPENAI *CHATGPT", category: "AI Subscriptions/Charges", memo: "ChatGPT Plus monthly subscription"),
                .init(date: "2026-01-10", amount: "-20.00", rawMerchant: "OPENAI *CHATGPT", category: "AI Subscriptions/Charges", memo: "ChatGPT Plus monthly subscription"),
                .init(date: "2026-02-10", amount: "-20.00", rawMerchant: "OPENAI *CHATGPT", category: "AI Subscriptions/Charges", memo: "ChatGPT Plus monthly subscription")
            ]
        ),
        DetectionFixtureCase(
            id: "notion_annual",
            description: "Annual subscription with only two charges a year apart.",
            labels: ["annual", "saas", "sparse_recurring"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Notion",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-02-18", amount: "-96.00", rawMerchant: "NOTION LABS INC", category: "Business Subscriptions", memo: "Notion annual plan"),
                .init(date: "2026-02-18", amount: "-96.00", rawMerchant: "NOTION LABS INC", category: "Business Subscriptions", memo: "Notion annual plan renewal")
            ]
        ),
        DetectionFixtureCase(
            id: "aws_variable_amount",
            description: "Variable-amount monthly SaaS spend should still be recognized.",
            labels: ["monthly", "saas", "variable_amount"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "AWS",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-05", amount: "-102.14", rawMerchant: "AMZN AWS", category: "Cloud Infrastructure", memo: "AWS monthly usage bill"),
                .init(date: "2026-01-05", amount: "-118.63", rawMerchant: "AMZN AWS", category: "Cloud Infrastructure", memo: "AWS monthly usage bill"),
                .init(date: "2026-02-05", amount: "-97.48", rawMerchant: "AMZN AWS", category: "Cloud Infrastructure", memo: "AWS monthly usage bill")
            ]
        ),
        DetectionFixtureCase(
            id: "adobe_trial_to_paid",
            description: "Trial converting to paid should not stay ambiguous after recurring paid charges appear.",
            labels: ["monthly", "saas", "trial_to_paid"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Adobe",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-02", amount: "-54.99", rawMerchant: "ADOBE *CREATIVE CLOUD", category: "Software", memo: "Creative Cloud trial ended"),
                .init(date: "2026-01-02", amount: "-54.99", rawMerchant: "ADOBE *CREATIVE CLOUD", category: "Software", memo: "Creative Cloud All Apps"),
                .init(date: "2026-02-02", amount: "-54.99", rawMerchant: "ADOBE *CREATIVE CLOUD", category: "Software", memo: "Creative Cloud All Apps")
            ]
        ),
        DetectionFixtureCase(
            id: "apple_icloud_masked",
            description: "Apple processor-masked charges should resolve to the real service.",
            labels: ["monthly", "apple_masked", "processor_masked"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "iCloud",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-15", amount: "-9.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 2TB"),
                .init(date: "2026-01-15", amount: "-9.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 2TB"),
                .init(date: "2026-02-15", amount: "-9.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 2TB")
            ]
        ),
        DetectionFixtureCase(
            id: "stripe_linear_masked",
            description: "Stripe-masked SaaS merchant should be unmasked and confirmed.",
            labels: ["monthly", "processor_masked", "stripe_masked"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Linear",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-03", amount: "-14.00", rawMerchant: "STRIPE* LINEAR", category: "Software", memo: "Linear subscription"),
                .init(date: "2026-01-03", amount: "-14.00", rawMerchant: "STRIPE* LINEAR", category: "Software", memo: "Linear subscription"),
                .init(date: "2026-02-03", amount: "-14.00", rawMerchant: "STRIPE* LINEAR", category: "Software", memo: "Linear subscription")
            ]
        ),
        DetectionFixtureCase(
            id: "paypal_canva_masked",
            description: "PayPal-masked design subscription should survive normalization.",
            labels: ["monthly", "processor_masked", "paypal_masked"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Canva",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-21", amount: "-12.99", rawMerchant: "PAYPAL *CANVA", category: "Software", memo: "Canva Pro monthly"),
                .init(date: "2026-01-21", amount: "-12.99", rawMerchant: "PAYPAL *CANVA", category: "Software", memo: "Canva Pro monthly"),
                .init(date: "2026-02-21", amount: "-12.99", rawMerchant: "PAYPAL *CANVA", category: "Software", memo: "Canva Pro monthly")
            ]
        ),
        DetectionFixtureCase(
            id: "netflix_merchant_variants",
            description: "Merchant spelling drift and processor suffixes should still collapse into one streaming subscription.",
            labels: ["monthly", "merchant_variation", "streaming"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Netflix",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-11", amount: "-15.49", rawMerchant: "NETFLIX.COM", category: "Streaming", memo: "Netflix premium"),
                .init(date: "2026-01-11", amount: "-15.49", rawMerchant: "NETFLIX *12345", category: "Streaming", memo: "Netflix premium"),
                .init(date: "2026-02-11", amount: "-15.49", rawMerchant: "Netflix.com", category: "Streaming", memo: "Netflix premium")
            ]
        ),
        DetectionFixtureCase(
            id: "figma_price_increase",
            description: "Price increases over time should keep the subscription confirmed instead of splitting it into separate candidates.",
            labels: ["monthly", "saas", "price_change"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Figma",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-08", amount: "-12.00", rawMerchant: "FIGMA", category: "Software", memo: "Figma professional plan"),
                .init(date: "2026-01-08", amount: "-15.00", rawMerchant: "FIGMA", category: "Software", memo: "Figma professional plan"),
                .init(date: "2026-02-08", amount: "-15.00", rawMerchant: "FIGMA", category: "Software", memo: "Figma professional plan")
            ]
        ),
        DetectionFixtureCase(
            id: "dropbox_refund_reversal",
            description: "Refunds and reversals in the ledger should not erase an otherwise obvious subscription.",
            labels: ["monthly", "refund_reversal", "saas"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Dropbox",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-14", amount: "-11.99", rawMerchant: "DROPBOX", category: "Storage", memo: "Dropbox Plus monthly"),
                .init(date: "2025-12-14", amount: "11.99", rawMerchant: "DROPBOX", category: "Storage", memo: "Refund reversal"),
                .init(date: "2026-01-14", amount: "-11.99", rawMerchant: "DROPBOX", category: "Storage", memo: "Dropbox Plus monthly"),
                .init(date: "2026-02-14", amount: "-11.99", rawMerchant: "DROPBOX", category: "Storage", memo: "Dropbox Plus monthly")
            ]
        ),
        DetectionFixtureCase(
            id: "google_youtube_premium_masked",
            description: "Google-processor charges with strong memo evidence should resolve to the real subscription brand.",
            labels: ["monthly", "processor_masked", "google_masked"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "YouTube Premium",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-19", amount: "-13.99", rawMerchant: "GOOGLE *YTPREMIUM", category: "Streaming", memo: "YouTube Premium monthly"),
                .init(date: "2026-01-19", amount: "-13.99", rawMerchant: "GOOGLE *YTPREMIUM", category: "Streaming", memo: "YouTube Premium monthly"),
                .init(date: "2026-02-19", amount: "-13.99", rawMerchant: "GOOGLE *YTPREMIUM", category: "Streaming", memo: "YouTube Premium monthly")
            ]
        ),
        DetectionFixtureCase(
            id: "apple_multi_service_same_vendor",
            description: "Multiple Apple subscriptions in the same ledger should surface as separate services instead of collapsing into one vendor bucket.",
            labels: ["monthly", "multi_subscription_vendor", "apple_masked"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Apple Music",
            expectedAdditionalCanonicalNames: ["iCloud"],
            transactions: [
                .init(date: "2025-12-05", amount: "-10.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "Apple Music family plan"),
                .init(date: "2026-01-05", amount: "-10.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "Apple Music family plan"),
                .init(date: "2026-02-05", amount: "-10.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "Apple Music family plan"),
                .init(date: "2025-12-16", amount: "-2.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 200GB"),
                .init(date: "2026-01-16", amount: "-2.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 200GB"),
                .init(date: "2026-02-16", amount: "-2.99", rawMerchant: "APPLE.COM/BILL", category: "Digital Goods", memo: "iCloud+ 200GB")
            ]
        ),
        DetectionFixtureCase(
            id: "hulu_end_of_month_leap_year",
            description: "End-of-month renewals across February in a leap year should still count as a stable monthly cadence.",
            labels: ["monthly", "leap_year", "end_of_month"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Hulu",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2024-01-31", amount: "-17.99", rawMerchant: "HULU", category: "Streaming", memo: "Hulu no ads"),
                .init(date: "2024-02-29", amount: "-17.99", rawMerchant: "HULU", category: "Streaming", memo: "Hulu no ads"),
                .init(date: "2024-03-31", amount: "-17.99", rawMerchant: "HULU", category: "Streaming", memo: "Hulu no ads")
            ]
        ),
        DetectionFixtureCase(
            id: "patreon_quarterly_plan",
            description: "Quarterly subscriptions should stay detectable even though monthly and annual are the primary UI cadences.",
            labels: ["quarterly", "creator_membership", "non_monthly_cadence"],
            expectedOutcome: .confirmedPositive,
            expectedCanonicalName: "Patreon",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-09-01", amount: "-30.00", rawMerchant: "PATREON", category: "Subscription", memo: "Quarterly membership"),
                .init(date: "2025-12-01", amount: "-30.00", rawMerchant: "PATREON", category: "Subscription", memo: "Quarterly membership"),
                .init(date: "2026-03-01", amount: "-30.00", rawMerchant: "PATREON", category: "Subscription", memo: "Quarterly membership")
            ]
        ),
        DetectionFixtureCase(
            id: "single_charge_new_subscription",
            description: "One recent high-signal charge should surface as a review candidate, not disappear.",
            labels: ["single_charge", "review_candidate"],
            expectedOutcome: .reviewPositive,
            expectedCanonicalName: "ChatGPT",
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: recentDateString(daysAgo: 21), amount: "-20.00", rawMerchant: "OPENAI *CHATGPT", category: "AI Subscriptions/Charges", memo: "ChatGPT Plus monthly subscription")
            ]
        ),
        DetectionFixtureCase(
            id: "costco_groceries",
            description: "Groceries with a monthly-ish pattern are not a subscription.",
            labels: ["negative", "retail_false_positive"],
            expectedOutcome: .negative,
            expectedCanonicalName: nil,
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-04", amount: "-84.15", rawMerchant: "Costco", category: "Groceries", memo: "Warehouse trip"),
                .init(date: "2026-01-05", amount: "-103.22", rawMerchant: "Costco", category: "Groceries", memo: "Warehouse trip"),
                .init(date: "2026-02-04", amount: "-91.08", rawMerchant: "Costco", category: "Groceries", memo: "Warehouse trip")
            ]
        ),
        DetectionFixtureCase(
            id: "chiropractor_visits",
            description: "Medical visits should stay suppressed even when they recur monthly.",
            labels: ["negative", "medical_false_positive"],
            expectedOutcome: .negative,
            expectedCanonicalName: nil,
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-07", amount: "-45.00", rawMerchant: "Example Wellness Clinic", category: "Health", memo: "Adjustment visit"),
                .init(date: "2026-01-06", amount: "-45.00", rawMerchant: "Example Wellness Clinic", category: "Health", memo: "Adjustment visit"),
                .init(date: "2026-02-06", amount: "-45.00", rawMerchant: "Example Wellness Clinic", category: "Health", memo: "Adjustment visit")
            ]
        ),
        DetectionFixtureCase(
            id: "amazon_orders",
            description: "Marketplace orders with similar timing should not be promoted into the library.",
            labels: ["negative", "marketplace_false_positive"],
            expectedOutcome: .negative,
            expectedCanonicalName: nil,
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-09", amount: "-61.11", rawMerchant: "Amazon", category: "Shopping", memo: "Marketplace order"),
                .init(date: "2026-01-08", amount: "-79.22", rawMerchant: "Amazon", category: "Shopping", memo: "Marketplace order"),
                .init(date: "2026-02-09", amount: "-68.14", rawMerchant: "Amazon", category: "Shopping", memo: "Marketplace order")
            ]
        ),
        DetectionFixtureCase(
            id: "neighborhood_market",
            description: "Noisy retail purchases should stay suppressed.",
            labels: ["negative", "retail_false_positive", "noisy_descriptor"],
            expectedOutcome: .negative,
            expectedCanonicalName: nil,
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: "2025-12-03", amount: "-18.40", rawMerchant: "Neighborhood Market", category: "Shopping", memo: "Order 1042"),
                .init(date: "2026-01-02", amount: "-31.75", rawMerchant: "Neighborhood Market", category: "Shopping", memo: "Delivery 2819"),
                .init(date: "2026-02-05", amount: "-24.10", rawMerchant: "Neighborhood Market", category: "Shopping", memo: "Pickup 9012")
            ]
        ),
        DetectionFixtureCase(
            id: "apple_one_off_purchase",
            description: "A single Apple bill without service evidence should not become a subscription.",
            labels: ["negative", "apple_masked", "one_off_purchase"],
            expectedOutcome: .negative,
            expectedCanonicalName: nil,
            expectedAdditionalCanonicalNames: [],
            transactions: [
                .init(date: recentDateString(daysAgo: 23), amount: "-29.99", rawMerchant: "APPLE.COM/BILL", category: "Apps", memo: "Procreate Dreams")
            ]
        )
    ]

    static func recentDateString(daysAgo: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        return date.ISO8601Format(.iso8601Date(timeZone: .gmt))
    }

    @MainActor
    static func evaluateFixtureSuite() async throws -> DetectionFixtureMetrics {
        var caseResults: [DetectionFixtureCaseResult] = []

        for fixture in fixtures {
            caseResults.append(try await evaluate(fixture))
        }

        let positiveCases = caseResults.filter { $0.fixture.expectedOutcome != .negative }.count
        let surfacedCases = caseResults.filter { $0.actualOutcome != .negative }.count
        let truePositives = caseResults.filter(\.isTruePositive).count
        let falsePositives = caseResults.filter(\.isFalsePositive).count
        let falseNegatives = caseResults.filter(\.isFalseNegative).count
        let reviewOverflowCount = caseResults.filter(\.reviewOverflow).count
        let identityMismatchCount = caseResults.filter(\.identityMismatch).count
        let outcomeCounts = Dictionary(
            grouping: caseResults,
            by: { $0.fixture.expectedOutcome }
        ).mapValues(\.count)
        let labelCoverage = fixtures.reduce(into: [String: Int]()) { partialResult, fixture in
            for label in fixture.labels {
                partialResult[label, default: 0] += 1
            }
        }

        return DetectionFixtureMetrics(
            totalCases: caseResults.count,
            positiveCases: positiveCases,
            surfacedCases: surfacedCases,
            truePositives: truePositives,
            falsePositives: falsePositives,
            falseNegatives: falseNegatives,
            reviewOverflowCount: reviewOverflowCount,
            identityMismatchCount: identityMismatchCount,
            outcomeCounts: outcomeCounts,
            labelCoverage: labelCoverage,
            caseResults: caseResults
        )
    }

    @MainActor
    private static func evaluate(
        _ fixture: DetectionFixtureCase
    ) async throws -> DetectionFixtureCaseResult {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let importRecord = ImportRecord(
            fileName: "\(fixture.id).csv",
            fileFormat: .csv,
            status: .analyzed,
            mappingSignature: fixture.id
        )
        context.insert(importRecord)

        let classifier = HeuristicMerchantClassifier()
        let formatter = ISO8601DateFormatter()

        for transaction in fixture.transactions {
            let amount = Decimal(string: transaction.amount) ?? 0
            let classification = classifier.classify(
                rawMerchant: transaction.rawMerchant,
                memo: transaction.memo,
                category: transaction.category,
                amount: amount
            )

            let normalizedTransaction = NormalizedTransaction(
                transactionDate: formatter.date(from: "\(transaction.date)T00:00:00Z") ?? .now,
                transactionAmount: amount,
                merchantRaw: transaction.rawMerchant,
                merchantNormalized: classification.canonicalName,
                currency: "USD",
                accountName: "Fixture",
                category: classification.serviceCategory.nilIfBlank ?? transaction.category,
                memo: transaction.memo,
                merchantKind: classification.merchantKind,
                merchantSubscriptionAffinity: classification.subscriptionAffinity,
                importRecordID: importRecord.id
            )
            normalizedTransaction.classificationConfidence = classification.confidence
            context.insert(normalizedTransaction)
        }

        _ = try await SubscriptionDetectionService().rebuildSubscriptions(in: context)
        try context.save()

        let subscriptions = try context.fetch(FetchDescriptor<Subscription>())
        let expectedCanonicalName = fixture.expectedCanonicalName

        let expectedCanonicalNames = fixture.expectedCanonicalNames
        let surfacedCanonicalNames = subscriptions.map(\.canonicalName).sorted()
        let matchedSubscription = subscriptions.first { subscription in
            guard expectedCanonicalNames.isEmpty == false else {
                return false
            }

            return expectedCanonicalNames.contains(subscription.canonicalName) ||
                expectedCanonicalNames.contains(subscription.displayName)
        }

        let actualOutcome: DetectionFixtureExpectedOutcome
        if subscriptions.isEmpty {
            actualOutcome = .negative
        } else if subscriptions.allSatisfy({ $0.status == .needsReview }) {
            actualOutcome = .reviewPositive
        } else {
            actualOutcome = .confirmedPositive
        }

        return DetectionFixtureCaseResult(
            fixture: fixture,
            actualOutcome: actualOutcome,
            matchedCanonicalName: matchedSubscription?.canonicalName ?? surfacedCanonicalNames.first,
            surfacedCanonicalNames: surfacedCanonicalNames
        )
    }
}
