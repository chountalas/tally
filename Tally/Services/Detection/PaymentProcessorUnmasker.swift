import Foundation

struct PaymentProcessorUnmasker {
    struct UnmaskResult: Equatable {
        let unmaskedMerchant: String?
        let isPaymentProcessor: Bool
        let subscriptionHint: String?
        let boostSubscriptionAffinity: Bool
    }

    private static let appleServiceKeywords: [(keyword: String, merchant: String, hint: String?)] = [
        ("icloud", "iCloud", "iCloud+"),
        ("apple music", "Apple Music", nil),
        ("apple tv", "Apple TV+", nil),
        ("apple one", "Apple One", nil),
        ("apple arcade", "Apple Arcade", nil),
        ("apple news", "Apple News+", nil),
        ("apple fitness", "Apple Fitness+", nil),
        ("apple care", "AppleCare", nil)
    ]

    private static let genericRecurringKeywords = [
        "subscription", "membership", "member", "plan", "premium",
        "plus", "monthly", "annual", "yearly", "renew", "renewal",
        "billing", "autopay", "auto pay", "trial"
    ]

    private static let tokenDisplayOverrides: [String: String] = [
        "AWS": "AWS",
        "AI": "AI",
        "API": "API",
        "TV": "TV",
        "ID": "ID",
        "YT": "YT"
    ]

    private static let phraseDisplayOverrides: [String: String] = [
        "YOUTUBE PREMIUM": "YouTube Premium",
        "YOUTUBE MUSIC": "YouTube Music",
        "ICLOUD": "iCloud",
        "GITHUB": "GitHub"
    ]

    func unmask(rawMerchant: String, memo: String?, category: String?) -> UnmaskResult {
        let merchant = rawMerchant.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [rawMerchant, memo, category]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        if merchant.contains("APPLE.COM/BILL") || merchant.contains("APPLE.COM BILL") {
            return unmaskAppleBill(combined: combined)
        }

        if let stripped = stripPrefix("STRIPE*", from: merchant) ??
            stripPrefix("STRIPE *", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: true
            )
        }

        if let stripped = stripPrefix("PAYPAL *", from: merchant) ??
            stripPrefix("PAYPAL*", from: merchant) ??
            stripPrefix("PP*", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: false
            )
        }

        if let stripped = stripPrefix("GOOGLE *", from: merchant) ??
            stripPrefix("GOOGLE*", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: false
            )
        }

        if let stripped = stripPrefix("SQ *", from: merchant) ??
            stripPrefix("SQC*", from: merchant) ??
            stripPrefix("SQUAREUP*", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: false
            )
        }

        if let stripped = stripPrefix("SP *", from: merchant) ??
            stripPrefix("SHOPIFY*", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: true
            )
        }

        if let stripped = stripPrefix("GUMROAD*", from: merchant) ??
            stripPrefix("PADDLE*", from: merchant) ??
            stripPrefix("PADDLE.NET*", from: merchant) ??
            stripPrefix("FS *", from: merchant) ??
            stripPrefix("FASTSPRING*", from: merchant) {
            return UnmaskResult(
                unmaskedMerchant: cleanedMerchantName(from: stripped),
                isPaymentProcessor: true,
                subscriptionHint: nil,
                boostSubscriptionAffinity: true
            )
        }

        return UnmaskResult(
            unmaskedMerchant: nil,
            isPaymentProcessor: false,
            subscriptionHint: nil,
            boostSubscriptionAffinity: false
        )
    }

    private func unmaskAppleBill(combined: String) -> UnmaskResult {
        for entry in Self.appleServiceKeywords where combined.localizedStandardContains(entry.keyword) {
            return UnmaskResult(
                unmaskedMerchant: entry.merchant,
                isPaymentProcessor: true,
                subscriptionHint: entry.hint,
                boostSubscriptionAffinity: true
            )
        }

        let hasGenericRecurringSignal = Self.genericRecurringKeywords.contains {
            combined.localizedStandardContains($0)
        }

        return UnmaskResult(
            unmaskedMerchant: "Apple",
            isPaymentProcessor: true,
            subscriptionHint: nil,
            boostSubscriptionAffinity: hasGenericRecurringSignal
        )
    }

    private func stripPrefix(_ prefix: String, from merchant: String) -> String? {
        guard merchant.hasPrefix(prefix) else { return nil }
        let stripped = String(merchant.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    private func cleanedMerchantName(from value: String) -> String {
        let normalized = value
            .replacingOccurrences(of: #"[\s_\-*/]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let uppercased = normalized.uppercased()
        if let override = Self.phraseDisplayOverrides[uppercased] {
            return override
        }

        return normalized
            .components(separatedBy: " ")
            .filter { $0.isEmpty == false }
            .map { token in
                let upper = token.uppercased()
                if let override = Self.tokenDisplayOverrides[upper] {
                    return override
                }
                return token.lowercased().capitalized(with: .current)
            }
            .joined(separator: " ")
    }
}
