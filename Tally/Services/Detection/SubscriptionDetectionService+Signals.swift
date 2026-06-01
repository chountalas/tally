import Foundation

extension SubscriptionDetectionService {
    var automaticRecurringClusterEvaluationEnabled: Bool {
        intelligence.generator != nil
    }

    var automaticSingleChargeEvaluationEnabled: Bool {
        intelligence.generator != nil
    }

    var recentPurchaseLookbackDays: Int {
        75
    }

    func keywordSupportScore(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        let coverage = Double(transactions.filter(hasExplicitSubscriptionKeywords).count) / Double(transactions.count)
        return min(1, max(coverage, descriptorStrength(for: transactions)))
    }

    func averageSubscriptionAffinity(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        let affinities = transactions.map { transaction in
            max(transaction.merchantSubscriptionAffinity, transaction.merchantKind.defaultSubscriptionAffinity)
        }

        return affinities.reduce(0, +) / Double(affinities.count)
    }

    func dominantMerchantKind(for transactions: [NormalizedTransaction]) -> MerchantKind {
        let grouped = Dictionary(grouping: transactions, by: \.merchantKind)
        return grouped.max { lhs, rhs in lhs.value.count < rhs.value.count }?.key ?? .unknown
    }

    func memoDiversityScore(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        let normalizedMemos = Set(
            transactions.compactMap { $0.memo?.lowercased() }
                .map { memo in
                    memo
                        .replacingOccurrences(of: #"\d+"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"inv[a-z\-]*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"ref[a-z\-]*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"conf[a-z\-]*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"order[a-z\-]*"#, with: "", options: .regularExpression)
                        .replacingOccurrences(
                            of: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|january|february|march|april|june|july|august|september|october|november|december)\b"#,
                            with: "",
                            options: .regularExpression
                        )
                        .replacingOccurrences(of: #"[a-f0-9\-]{8,}"#, with: "", options: .regularExpression)
                        .replacingOccurrences(of: #"[\s\-_*#]+"#, with: " ", options: .regularExpression)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { $0.isEmpty == false }
        )

        guard normalizedMemos.isEmpty == false else {
            return 0
        }

        return Double(normalizedMemos.count) / Double(transactions.count)
    }

    func descriptorStrength(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        let descriptorMatches = transactions.filter {
            explicitClusterDescriptor(for: $0) != nil
        }.count
        return Double(descriptorMatches) / Double(transactions.count)
    }

    func categoryPenalty(
        for transactions: [NormalizedTransaction],
        dominantMerchantKind: MerchantKind
    ) -> Double {
        let keywordScore = keywordSupportScore(for: transactions)

        if dominantMerchantKind.isUsuallyNonSubscription {
            return keywordScore >= 0.5 ? 0.18 : 0.35
        }

        let excludedCount = transactions.filter(isExcludedCategory).count
        guard excludedCount > 0 else {
            return 0
        }

        let basePenalty = min(0.35, Double(excludedCount) / Double(transactions.count) * 0.35)
        return keywordScore >= 0.5 ? basePenalty * 0.5 : basePenalty
    }

    func memoDiversityPenalty(memoDiversity: Double, descriptorStrength: Double) -> Double {
        guard memoDiversity > 0.65 else {
            return 0
        }

        return min(0.15, memoDiversity * max(0.1, 1 - descriptorStrength) * 0.2)
    }

    func amountVariationPenalty(priceVariation: Double) -> Double {
        guard priceVariation > 0.3 else {
            return 0
        }

        return min(0.15, priceVariation * 0.2)
    }

    func appointmentPenalty(for transactions: [NormalizedTransaction]) -> Double {
        let count = transactions.filter(hasAppointmentOrVisitSignals).count
        guard count > 0 else {
            return 0
        }

        let hasStrongSubscriptionWording = transactions.contains { transaction in
            let combined = [
                transaction.memo,
                transaction.category,
                transaction.merchantRaw,
                transaction.merchantNormalized
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            return ["membership", "monthly", "subscription", "plan", "enrolled", "autopay"]
                .contains { combined.localizedStandardContains($0) }
        }
        if hasStrongSubscriptionWording {
            return 0
        }

        return min(0.2, Double(count) / Double(transactions.count) * 0.25)
    }

    func marketplacePenalty(for transactions: [NormalizedTransaction]) -> Double {
        let count = transactions.filter(hasMarketplaceOrderSignals).count
        guard count > 0 else {
            return 0
        }

        let hasExplicitDescriptor = transactions.contains {
            explicitClusterDescriptor(for: $0) != nil
        }
        if hasExplicitDescriptor {
            return 0
        }

        return min(0.2, Double(count) / Double(transactions.count) * 0.25)
    }

    func shouldHardReject(
        transactions: [NormalizedTransaction],
        snapshot: SubscriptionScoringSnapshot
    ) -> Bool {
        let hasFinancialMovementOverride = transactions.contains(where: hasStrongSubscriptionWording)

        if snapshot.financialMovementCount >= max(1, snapshot.transactionCount - 1),
           hasFinancialMovementOverride == false {
            return true
        }

        if snapshot.recurringBillOrNonSubscriptionCount >= max(1, snapshot.transactionCount - 1),
           snapshot.hasExplicitSubscriptionWording == false {
            return true
        }

        if snapshot.commerceNoiseCount >= max(1, snapshot.transactionCount - 1),
           snapshot.hasExplicitSubscriptionWording == false {
            return true
        }

        if snapshot.dominantMerchantKind.isUsuallyNonSubscription && snapshot.keywordSupport == 0 {
            return true
        }

        if snapshot.excludedCategoryCount >= max(2, snapshot.transactionCount - 1),
           snapshot.keywordSupport == 0 {
            return true
        }

        if snapshot.memoDiversity > 0.8,
           snapshot.descriptorStrength < 0.2,
           snapshot.keywordSupport < 0.5,
           snapshot.merchantAffinity < 0.6 {
            return true
        }

        if snapshot.priceVariation > 0.65,
           snapshot.keywordSupport == 0,
           snapshot.merchantAffinity < 0.6 {
            return true
        }

        return false
    }

    func shouldRunSecondPassAI(
        baseScore: Double,
        snapshot: SubscriptionScoringSnapshot
    ) -> Bool {
        if (0.4...0.85).contains(baseScore) {
            return true
        }

        if baseScore > 0.85 {
            return false
        }

        if snapshot.dominantMerchantKind == .unknown, baseScore >= 0.25 {
            return true
        }

        if snapshot.dominantMerchantKind == .membershipRetailer {
            return snapshot.keywordSupport < 0.5
        }

        if snapshot.dominantMerchantKind == .marketplace {
            return snapshot.keywordSupport < 0.75 || snapshot.negativePenalty > 0.1
        }

        return false
    }

    func reasonSummary(for snapshot: SubscriptionScoringSnapshot) -> String {
        if snapshot.dominantMerchantKind.isUsuallyNonSubscription && snapshot.keywordSupport == 0 {
            let merchantKind = snapshot.dominantMerchantKind.title.lowercased()
            return "Recurring \(snapshot.cadence.rawValue) pattern but merchant looks like \(merchantKind)."
        }
        if snapshot.classificationConfidence < 0.65 {
            return "Recurring pattern detected, but merchant classification is uncertain."
        }
        if snapshot.memoDiversity > 0.65 && snapshot.descriptorStrength < 0.3 {
            return "Recurring pattern detected, but transaction details vary too much to auto-confirm."
        }
        if snapshot.negativePenalty > 0.25 {
            return "Recurring pattern detected with conflicting merchant signals."
        }
        return "Recurring \(snapshot.cadence.rawValue) pattern with stable charge timing."
    }

    func recentPurchaseBaseScore(for transaction: NormalizedTransaction) -> Double {
        let affinity = max(
            transaction.merchantSubscriptionAffinity,
            transaction.merchantKind.defaultSubscriptionAffinity
        )
        let keywordScore = hasExplicitSubscriptionKeywords(transaction) ? 1.0 : 0.0
        let descriptorScore = explicitClusterDescriptor(for: transaction) == nil ? 0.0 : 1.0
        let kindScore: Double = switch transaction.merchantKind {
        case .subscriptionService, .softwareOrSaaS, .mediaStreaming:
            1
        case .membershipRetailer:
            0.75
        case .utilityOrBiller:
            hasExplicitSubscriptionKeywords(transaction) ? 0.55 : 0.08
        case .unknown:
            0.45
        case .marketplace, .groceryRetailer, .restaurant, .medicalOrWellnessProvider, .transportOrTravel, .generalRetail:
            0.08
        }

        return min(
            0.99,
            max(
                0,
                (affinity * 0.42) +
                (transaction.classificationConfidence * 0.20) +
                (keywordScore * 0.18) +
                (descriptorScore * 0.10) +
                (kindScore * 0.10)
            )
        )
    }

    func shouldEvaluateSingleCharge(_ transaction: NormalizedTransaction) -> Bool {
        guard transaction.transactionAmount < 0 else {
            return false
        }
        guard transactionLooksLikeRefund(transaction) == false else {
            return false
        }

        let cutoff = Calendar.current.date(byAdding: .day, value: -recentPurchaseLookbackDays, to: .now) ?? .distantPast
        guard transaction.transactionDate >= cutoff else {
            return false
        }

        let hasKeywords = hasExplicitSubscriptionKeywords(transaction)
        let hasDescriptor = explicitClusterDescriptor(for: transaction) != nil
        let affinity = max(
            transaction.merchantSubscriptionAffinity,
            transaction.merchantKind.defaultSubscriptionAffinity
        )

        if transaction.merchantKind.isUsuallyNonSubscription,
           hasKeywords == false,
           hasDescriptor == false {
            return false
        }

        if isExcludedCategory(transaction),
           hasKeywords == false,
           hasDescriptor == false {
            return false
        }

        if isFinancialMovement(transaction),
           hasStrongSubscriptionWording(transaction) == false {
            return false
        }

        if isRecurringBillOrNonSubscriptionSpend(transaction),
           hasExplicitSubscriptionKeywords(transaction) == false {
            return false
        }

        if hasCommerceNoiseSignals(transaction),
           hasExplicitSubscriptionKeywords(transaction) == false {
            return false
        }

        if hasMarketplaceOrderSignals(transaction),
           hasKeywords == false,
           hasDescriptor == false {
            return false
        }

        if affinity >= 0.92, transaction.classificationConfidence >= 0.84 {
            return true
        }

        if hasKeywords && affinity >= 0.72 {
            return true
        }

        return hasDescriptor && affinity >= 0.78
    }

    func shouldRunSingleChargeAI(baseScore: Double, transaction: NormalizedTransaction) -> Bool {
        guard automaticSingleChargeEvaluationEnabled else {
            return false
        }

        if (0.45...0.85).contains(baseScore) {
            return true
        }

        if transaction.merchantKind == .unknown {
            return baseScore >= 0.2
        }

        return false
    }

    func inferredSingleChargeCadence(for transaction: NormalizedTransaction) -> SubscriptionCadence {
        let combined = [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if ["annual", "yearly", "per year", "12 month", "12-month"].contains(where: combined.localizedStandardContains) {
            return .annual
        }
        if ["quarterly", "quarter", "qtr"].contains(where: combined.localizedStandardContains) {
            return .quarterly
        }
        if ["semiannual", "semi-annual", "biannual", "6 month", "6-month"].contains(where: combined.localizedStandardContains) {
            return .semiannual
        }
        if ["biweekly", "bi-weekly", "every two weeks", "every 2 weeks", "fortnightly"].contains(where: combined.localizedStandardContains) {
            return .biweekly
        }
        if ["weekly", "per week"].contains(where: combined.localizedStandardContains) {
            return .weekly
        }
        if ["monthly", "trial", "renew", "renewal", "subscription", "membership", "plan", "premium", "plus", "pro"].contains(where: combined.localizedStandardContains) {
            return .monthly
        }

        switch transaction.merchantKind {
        case .subscriptionService, .softwareOrSaaS, .mediaStreaming, .membershipRetailer, .unknown:
            return .monthly
        case .utilityOrBiller:
            return hasExplicitSubscriptionKeywords(transaction) ? .monthly : .unknown
        case .marketplace, .groceryRetailer, .restaurant, .medicalOrWellnessProvider, .transportOrTravel, .generalRetail:
            return .unknown
        }
    }

    func recentPurchaseDisplayName(for transaction: NormalizedTransaction) -> String {
        let merchant = transaction.merchantNormalized.nilIfBlank ?? transaction.merchantRaw
        if let descriptor = explicitClusterDescriptor(for: transaction),
           merchant.localizedStandardContains(descriptor) == false {
            return "\(merchant) \(descriptor)"
        }
        return merchant
    }

    func recentPurchaseReason(
        for transaction: NormalizedTransaction,
        cadence: SubscriptionCadence
    ) -> String {
        if hasExplicitSubscriptionKeywords(transaction) {
            return "Recent \(cadence.rawValue) charge includes explicit subscription wording."
        }
        if let descriptor = explicitClusterDescriptor(for: transaction) {
            return "Recent charge matches the \(descriptor) subscription pattern."
        }
        return "Recent charge strongly matches a subscription merchant and needs confirmation."
    }

    func transactionLooksLikeRefund(_ transaction: NormalizedTransaction) -> Bool {
        let memo = transaction.memo?.lowercased() ?? ""
        return memo.localizedStandardContains("refund") || memo.localizedStandardContains("reversal")
    }

    func financialMovementPenalty(for transactions: [NormalizedTransaction]) -> Double {
        let count = transactions.filter(isFinancialMovement).count
        guard count > 0 else {
            return 0
        }

        let hasSubscriptionOverride = transactions.contains(where: hasStrongSubscriptionWording)
        if hasSubscriptionOverride {
            return min(0.12, Double(count) / Double(transactions.count) * 0.16)
        }

        return min(0.45, Double(count) / Double(transactions.count) * 0.5)
    }

    func isFinancialMovement(_ transaction: NormalizedTransaction) -> Bool {
        let combined = [
            transaction.category,
            transaction.memo,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "transfer",
            "external transfer",
            "standard transfer",
            "wire transfer",
            "bank account",
            "money out",
            "auto payment",
            "electronic withdrawal",
            "credit card payment",
            "card payment",
            "automated transaction buy",
            "securities buy",
            "investment buy",
            "withdrawal",
            "deposit",
            "loan payment",
            "student loan",
            "rent",
            "mortgage",
            "taxes",
            "financial fee",
            "wire fee",
            "atm fee",
            "parking"
        ].contains { combined.localizedStandardContains($0) }
    }

    func isRecurringBillOrNonSubscriptionSpend(_ transaction: NormalizedTransaction) -> Bool {
        let signal = textSignal(from: [
            transaction.category,
            transaction.memo,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ])

        if isFinancialMovement(transaction) {
            return true
        }

        return [
            "tv & internet",
            "internet",
            "utilities",
            "utility",
            "water",
            "auto insurance",
            "insurance",
            "groceries",
            "grocery",
            "clothing",
            "home improvement",
            "moving",
            "paying into business",
            "family wedding tracker",
            "house supplies",
            "personal care",
            "supplements"
        ].contains { containsSignal($0, in: signal) }
    }

    func hasCommerceNoiseSignals(_ transaction: NormalizedTransaction) -> Bool {
        let signal = textSignal(from: [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ])

        return [
            "amazon mktpl",
            "marketplace",
            "uber trip",
            "warehouse trip",
            "costco whse",
            "home depot",
            "u haul",
            "vuori",
            "gourmet",
            "marketplace order",
            "online order",
            "pickup order",
            "shipment",
            "delivery"
        ].contains { containsSignal($0, in: signal) }
    }

    func hasKnownSubscriptionServiceSignal(_ transaction: NormalizedTransaction) -> Bool {
        if hasCommerceNoiseSignals(transaction) || isRecurringBillOrNonSubscriptionSpend(transaction) {
            return false
        }

        let signal = textSignal(from: [
            transaction.memo,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ])
        let normalizedCategory = transaction.category?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if let normalizedCategory,
           [
            "business subscriptions",
            "ai subscriptions",
            "subscriptions",
            "subscription",
            "software",
            "ai",
            "security",
            "news",
            "audiobooks",
            "streaming",
            "home security"
           ].contains(normalizedCategory) {
            return true
        }

        if [
            "subscription",
            "subscr",
            "membership",
            "renewal",
            "plan",
            "premium",
            "plus",
            "pro",
            "workspace",
            "cloud",
            "hosting",
            "domain",
            "license",
            "streaming",
            "ai subscription",
            "home security"
        ].contains(where: { containsSignal($0, in: signal) }) {
            return true
        }

        switch transaction.merchantKind {
        case .subscriptionService, .softwareOrSaaS, .mediaStreaming:
            return true
        case .membershipRetailer:
            return hasStrongSubscriptionWording(transaction)
        case .utilityOrBiller, .marketplace, .groceryRetailer, .restaurant,
             .medicalOrWellnessProvider, .transportOrTravel, .generalRetail, .unknown:
            return false
        }
    }

    func textSignal(from fields: [String?]) -> TextSignal {
        let combined = fields
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        let tokens = Set(
            combined
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { $0.isEmpty == false }
        )
        return TextSignal(combined: combined, tokens: tokens)
    }

    func containsSignal(_ term: String, in signal: TextSignal) -> Bool {
        let normalized = term.lowercased()
        let isSingleToken = normalized.rangeOfCharacter(
            from: CharacterSet.alphanumerics.inverted
        ) == nil
        if isSingleToken {
            return signal.tokens.contains(normalized)
        }
        return signal.combined.localizedStandardContains(normalized)
    }

    func hasStrongSubscriptionWording(_ transaction: NormalizedTransaction) -> Bool {
        let combined = [
            transaction.memo,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "subscription",
            "subscribe",
            "subscr",
            "subs",
            "membership",
            "member",
            "renew",
            "renewal",
            "plan",
            "premium",
            "billing",
            "billed",
            "rebill",
            "icloud",
            "prime",
            "hosting",
            "domain",
            "license",
            "licence",
            "seat",
            "monthly fee",
            "annual fee",
            "access fee",
            "streaming",
            "per month",
            "per year",
            "/mo",
            "/yr"
        ].contains { combined.localizedStandardContains($0) }
    }

    func hasExplicitSubscriptionKeywords(_ transaction: NormalizedTransaction) -> Bool {
        let combined = [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "subscription",
            "subscribe",
            "subscr",
            "subs",
            "membership",
            "member",
            "renew",
            "renewal",
            "plan",
            "premium",
            "plus",
            "monthly",
            "annual",
            "yearly",
            "autopay",
            "auto-pay",
            "auto pay",
            "auto-renew",
            "auto renew",
            "recurring",
            "billing",
            "billed",
            "rebill",
            "icloud",
            "prime",
            "starter",
            "professional",
            "enterprise",
            "team",
            "trial",
            "free trial",
            "hosting",
            "domain",
            "license",
            "licence",
            "seat",
            "service fee",
            "monthly fee",
            "annual fee",
            "access fee",
            "game pass",
            "season pass",
            "day pass",
            "bundle",
            "unlimited",
            "full access",
            "workspace",
            "account fee",
            "platform fee",
            "streaming",
            "per month",
            "per year",
            "/mo",
            "/yr",
            "retainer",
            "saas"
        ].contains { combined.localizedStandardContains($0) }
    }

    func hasAppointmentOrVisitSignals(_ transaction: NormalizedTransaction) -> Bool {
        let combined = [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "appointment",
            "visit",
            "session",
            "copay",
            "therapy",
            "chiropr",
            "massage",
            "wellness"
        ].contains { combined.localizedStandardContains($0) }
    }

    func hasMarketplaceOrderSignals(_ transaction: NormalizedTransaction) -> Bool {
        let combined = [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        return [
            "order",
            "marketplace",
            "purchase",
            "seller",
            "shipment",
            "delivery"
        ].contains { combined.localizedStandardContains($0) }
    }

    func isExcludedCategory(_ transaction: NormalizedTransaction) -> Bool {
        let category = transaction.category?.lowercased() ?? ""

        return [
            "grocer",
            "food",
            "dining",
            "restaurant",
            "retail",
            "shopping",
            "fuel",
            "gas",
            "travel",
            "transport",
            "pharmacy",
            "personal care",
            "home improvement",
            "medical",
            "health"
        ].contains { category.localizedStandardContains($0) }
    }
}
