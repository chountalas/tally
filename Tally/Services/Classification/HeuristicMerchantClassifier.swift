import Foundation

struct HeuristicMerchantClassifier {
    func classify(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) -> MerchantClassificationResult {
        let unmasker = PaymentProcessorUnmasker()
        let unmaskResult = unmasker.unmask(rawMerchant: rawMerchant, memo: memo, category: category)
        let effectiveMerchant = unmaskResult.unmaskedMerchant ?? rawMerchant
        let normalized = normalizeMerchant(effectiveMerchant)
        let normalizedCategory = category?.lowercased() ?? ""
        let combined = [
            effectiveMerchant.lowercased(),
            normalized.lowercased(),
            memo?.lowercased() ?? "",
            normalizedCategory
        ].joined(separator: " ")

        if let specialCase = specialCaseClassification(
            combined: combined,
            normalizedCategory: normalizedCategory
        ) {
            return specialCase
        }

        let merchantEvidence = [effectiveMerchant.lowercased(), normalized.lowercased()].joined(separator: " ")
        let ambiguousBrands: Set<String> = ["calm", "cursor", "linear", "max", "notion", "proton", "steam"]
        if let brand = orderedKnownBrandProfiles.first(where: {
            containsBrand($0.key, in: ambiguousBrands.contains($0.key) ? merchantEvidence : combined)
        })?.value {
            return MerchantClassificationResult(
                canonicalName: brand.name,
                serviceCategory: brand.category,
                merchantKind: brand.kind,
                subscriptionAffinity: brand.affinity,
                confidence: brand.confidence
            )
        }

        let normalizedMemo = memo?.lowercased() ?? ""
        let merchantKind = deriveMerchantKind(
            normalized: normalized.lowercased(),
            memo: normalizedMemo,
            category: normalizedCategory
        )
        let serviceCategory = deriveCategory(from: merchantKind, category: category)
        var affinity = merchantAffinity(
            for: merchantKind,
            normalized: normalized.lowercased(),
            memo: normalizedMemo,
            amount: amount
        )
        if unmaskResult.boostSubscriptionAffinity {
            affinity = min(1, affinity + 0.15)
        }
        let canonicalName = normalized.isEmpty
            ? effectiveMerchant.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            : normalized

        return MerchantClassificationResult(
            canonicalName: canonicalName,
            serviceCategory: serviceCategory,
            merchantKind: merchantKind,
            subscriptionAffinity: affinity,
            confidence: confidence(for: merchantKind, combined: combined)
        )
    }

    private func containsBrand(_ brand: String, in text: String) -> Bool {
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(of: brand, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange) {
            let startsInsideWord = range.lowerBound > text.startIndex &&
                text[text.index(before: range.lowerBound)].isLetterOrNumber
            let endsInsideWord = range.upperBound < text.endIndex && text[range.upperBound].isLetterOrNumber
            if startsInsideWord == false, endsInsideWord == false {
                return true
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return false
    }

    private func specialCaseClassification(
        combined: String,
        normalizedCategory: String
    ) -> MerchantClassificationResult? {
        let hasKnownAppleSubscriptionService = containsAny(
            [
                "icloud",
                "apple music",
                "apple tv",
                "apple one",
                "apple arcade",
                "apple fitness",
                "apple news",
                "apple care"
            ],
            in: combined
        )

        if containsAny(["claude.ai", "claude ai", " claude ", "anthropic"], in: combined) {
            return MerchantClassificationResult(
                canonicalName: "Claude",
                serviceCategory: "AI",
                merchantKind: .subscriptionService,
                subscriptionAffinity: 0.98,
                confidence: 0.96
            )
        }

        if containsAny(["chatgpt", "openai"], in: combined) {
            return MerchantClassificationResult(
                canonicalName: "ChatGPT",
                serviceCategory: "AI",
                merchantKind: .subscriptionService,
                subscriptionAffinity: 0.98,
                confidence: 0.96
            )
        }

        if containsAny(["amazon web services", "amzn aws", "aws monthly usage", "aws usage"], in: combined) {
            return MerchantClassificationResult(
                canonicalName: "AWS",
                serviceCategory: "Cloud Infrastructure",
                merchantKind: .softwareOrSaaS,
                subscriptionAffinity: 0.95,
                confidence: 0.97
            )
        }

        if containsAny(["adobe creative cloud", "creative cloud"], in: combined) &&
            combined.localizedStandardContains("adobe") {
            return MerchantClassificationResult(
                canonicalName: "Adobe",
                serviceCategory: "Software",
                merchantKind: .softwareOrSaaS,
                subscriptionAffinity: 0.97,
                confidence: 0.97
            )
        }

        if containsAny(["walmart+", "wmt plus"], in: combined) ||
            (combined.localizedStandardContains("walmart") &&
             containsAny(["member", "membership", "subscription", "credit"], in: combined)) {
            return MerchantClassificationResult(
                canonicalName: "Walmart+",
                serviceCategory: "Membership",
                merchantKind: .membershipRetailer,
                subscriptionAffinity: 0.96,
                confidence: 0.95
            )
        }

        if combined.localizedStandardContains("apple"),
           hasKnownAppleSubscriptionService == false,
           containsAny(["subscription", "membership", "plan", "monthly", "annual", "renew"], in: combined) == false {
            return MerchantClassificationResult(
                canonicalName: "Apple",
                serviceCategory: normalizedCategory.localizedStandardContains("app")
                    ? "Apps"
                    : "Digital Goods",
                merchantKind: .generalRetail,
                subscriptionAffinity: 0.12,
                confidence: 0.9
            )
        }

        if combined.localizedStandardContains("costco"),
           ["membership", "member", "renew", "annual"].contains(
               where: { combined.localizedStandardContains($0) }
           ) == false {
            return MerchantClassificationResult(
                canonicalName: "Costco",
                serviceCategory: normalizedCategory.localizedStandardContains("groc")
                    ? "Groceries"
                    : "Retail",
                merchantKind: normalizedCategory.localizedStandardContains("groc")
                    ? .groceryRetailer
                    : .generalRetail,
                subscriptionAffinity: normalizedCategory.localizedStandardContains("groc")
                    ? 0.08
                    : 0.12,
                confidence: 0.9
            )
        }

        return nil
    }

    private func deriveMerchantKind(
        normalized: String,
        memo: String,
        category: String
    ) -> MerchantKind {
        let combined = [normalized, memo, category].joined(separator: " ")

        if containsAny(
            ["subscription", "membership", "member", "autopay", "renew", "plan"],
            in: combined
        ) {
            if containsAny(["prime", "costco"], in: combined) {
                return .membershipRetailer
            }
            return .subscriptionService
        }

        for rule in merchantKindRules where containsAny(rule.tokens, in: combined) {
            return rule.kind
        }

        return .unknown
    }

    private func deriveCategory(from merchantKind: MerchantKind, category: String?) -> String {
        let trimmed = category?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.isEmpty == false {
            return trimmed
        }
        return merchantKind.defaultServiceCategory
    }

    private func merchantAffinity(
        for merchantKind: MerchantKind,
        normalized: String,
        memo: String,
        amount: Decimal
    ) -> Double {
        var affinity = merchantKind.defaultSubscriptionAffinity
        let combined = [normalized, memo].joined(separator: " ")

        if containsAny(
            [
                "subscription", "membership", "member", "renew",
                "autopay", "plan", "premium", "plus", "annual", "monthly"
            ],
            in: combined
        ) {
            affinity += 0.12
        }
        if containsAny(
            ["order", "visit", "appointment", "trip", "marketplace"],
            in: combined
        ) {
            affinity -= 0.18
        }
        if abs((amount as NSDecimalNumber).doubleValue) > 250 {
            affinity -= 0.08
        }

        return min(max(affinity, 0), 1)
    }

    private func confidence(for merchantKind: MerchantKind, combined: String) -> Double {
        var confidence = merchantKind == .unknown ? 0.45 : 0.7
        if containsAny(
            [
                "subscription", "membership", "stream", "software",
                "grocery", "medical", "restaurant", "travel"
            ],
            in: combined
        ) {
            confidence += 0.12
        }
        return min(confidence, 0.92)
    }

    private func containsAny(_ tokens: [String], in combined: String) -> Bool {
        tokens.contains { combined.localizedStandardContains($0) }
    }

    private static let merchantAbbreviations: [String: String] = [
        "MSFT": "Microsoft",
        "AMZN": "Amazon",
        "AWS": "AWS",
        "GOOGL": "Google",
        "GOOG": "Google",
        "INTL": "International",
        "PYMNT": "Payment",
        "PYMT": "Payment",
        "PMT": "Payment",
        "SVC": "Service",
        "SVCS": "Services",
        "SUBSCR": "Subscription",
        "SUBS": "Subscription",
        "MBR": "Member",
        "MBRSHP": "Membership",
        "MNTHLY": "Monthly",
        "YRLY": "Yearly",
        "ANNL": "Annual",
        "RECUR": "Recurring",
        "AUTOPAY": "Autopay",
        "DIG": "Digital",
        "DGTL": "Digital",
        "TECH": "Technology",
        "ENTMT": "Entertainment",
        "ENTERTN": "Entertainment"
    ]

    private static let normalizationStopWords: Set<String> = [
        "COM", "WWW", "POS", "CARD", "DEBIT", "CREDIT", "ACH"
    ]

    func normalizeMerchant(_ rawMerchant: String) -> String {
        let uppercased = rawMerchant.uppercased()
        let words = uppercased
            .replacingOccurrences(of: #"[*#/]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b\d{2,}\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b[A-Z]*\d[A-Z0-9\-]{2,}\b"#, with: " ", options: .regularExpression)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .filter { Self.normalizationStopWords.contains($0) == false }
            .prefix(4)
            .map { token in
                Self.merchantAbbreviations[token] ?? token.capitalized
            }

        return words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension Character {
    var isLetterOrNumber: Bool { isLetter || isNumber }
}
