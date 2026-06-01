import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

private struct KnownBrandProfile {
    let name: String
    let category: String
    let kind: MerchantKind
    let affinity: Double
    let confidence: Double
}

private struct MerchantKindRule {
    let kind: MerchantKind
    let tokens: [String]
}

private let knownBrandProfiles: [String: KnownBrandProfile] = [
    "1password": KnownBrandProfile(
        name: "1Password",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.95
    ),
    "netflix": KnownBrandProfile(
        name: "Netflix",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.99,
        confidence: 0.98
    ),
    "spotify": KnownBrandProfile(
        name: "Spotify",
        category: "Music",
        kind: .subscriptionService,
        affinity: 0.97,
        confidence: 0.98
    ),
    "adobe": KnownBrandProfile(
        name: "Adobe",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.96,
        confidence: 0.97
    ),
    "adobe creative cloud": KnownBrandProfile(
        name: "Adobe",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.97,
        confidence: 0.98
    ),
    "dropbox": KnownBrandProfile(
        name: "Dropbox",
        category: "Storage",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.95
    ),
    "disney+": KnownBrandProfile(
        name: "Disney+",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.97,
        confidence: 0.97
    ),
    "hbo": KnownBrandProfile(
        name: "Max",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.96,
        confidence: 0.95
    ),
    "hulu": KnownBrandProfile(
        name: "Hulu",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.97,
        confidence: 0.97
    ),
    "max": KnownBrandProfile(
        name: "Max",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.96,
        confidence: 0.95
    ),
    "paramount+": KnownBrandProfile(
        name: "Paramount+",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.96,
        confidence: 0.95
    ),
    "peacock": KnownBrandProfile(
        name: "Peacock",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.94
    ),
    "apple tv+": KnownBrandProfile(
        name: "Apple TV+",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.97,
        confidence: 0.96
    ),
    "apple music": KnownBrandProfile(
        name: "Apple Music",
        category: "Music",
        kind: .subscriptionService,
        affinity: 0.97,
        confidence: 0.96
    ),
    "icloud": KnownBrandProfile(
        name: "iCloud",
        category: "Storage",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.95
    ),
    "apple one": KnownBrandProfile(
        name: "Apple One",
        category: "Subscription",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.93
    ),
    "youtube premium": KnownBrandProfile(
        name: "YouTube Premium",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.94
    ),
    "youtube music": KnownBrandProfile(
        name: "YouTube Music",
        category: "Music",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.94
    ),
    "tidal": KnownBrandProfile(
        name: "Tidal",
        category: "Music",
        kind: .mediaStreaming,
        affinity: 0.94,
        confidence: 0.93
    ),
    "audible": KnownBrandProfile(
        name: "Audible",
        category: "Audiobooks",
        kind: .subscriptionService,
        affinity: 0.96,
        confidence: 0.96
    ),
    "amazon prime": KnownBrandProfile(
        name: "Amazon Prime",
        category: "Membership",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.94
    ),
    "crunchyroll": KnownBrandProfile(
        name: "Crunchyroll",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.93
    ),
    "notion": KnownBrandProfile(
        name: "Notion",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.96
    ),
    "github": KnownBrandProfile(
        name: "GitHub",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.95
    ),
    "figma": KnownBrandProfile(
        name: "Figma",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.95
    ),
    "linear": KnownBrandProfile(
        name: "Linear",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.94
    ),
    "slack": KnownBrandProfile(
        name: "Slack",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.95
    ),
    "zoom": KnownBrandProfile(
        name: "Zoom",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.92,
        confidence: 0.94
    ),
    "bitwarden": KnownBrandProfile(
        name: "Bitwarden",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.93
    ),
    "cursor": KnownBrandProfile(
        name: "Cursor",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "canva": KnownBrandProfile(
        name: "Canva",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.94
    ),
    "grammarly": KnownBrandProfile(
        name: "Grammarly",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "microsoft 365": KnownBrandProfile(
        name: "Microsoft 365",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.96,
        confidence: 0.96
    ),
    "office 365": KnownBrandProfile(
        name: "Microsoft 365",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.96,
        confidence: 0.96
    ),
    "google one": KnownBrandProfile(
        name: "Google One",
        category: "Storage",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.95
    ),
    "midjourney": KnownBrandProfile(
        name: "Midjourney",
        category: "AI",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "perplexity": KnownBrandProfile(
        name: "Perplexity",
        category: "AI",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.93
    ),
    "superhuman": KnownBrandProfile(
        name: "Superhuman",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.96
    ),
    "raycast": KnownBrandProfile(
        name: "Raycast",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.95
    ),
    "patreon": KnownBrandProfile(
        name: "Patreon",
        category: "Subscription",
        kind: .subscriptionService,
        affinity: 0.96,
        confidence: 0.95
    ),
    "substack": KnownBrandProfile(
        name: "Substack",
        category: "Subscription",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.94
    ),
    "nyt": KnownBrandProfile(
        name: "New York Times",
        category: "News",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "new york times": KnownBrandProfile(
        name: "New York Times",
        category: "News",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "wsj": KnownBrandProfile(
        name: "Wall Street Journal",
        category: "News",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "the athletic": KnownBrandProfile(
        name: "The Athletic",
        category: "News",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "peloton": KnownBrandProfile(
        name: "Peloton",
        category: "Fitness",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.95
    ),
    "strava": KnownBrandProfile(
        name: "Strava",
        category: "Fitness",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "headspace": KnownBrandProfile(
        name: "Headspace",
        category: "Wellness",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "calm": KnownBrandProfile(
        name: "Calm",
        category: "Wellness",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "xbox": KnownBrandProfile(
        name: "Xbox Game Pass",
        category: "Gaming",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.94
    ),
    "playstation": KnownBrandProfile(
        name: "PlayStation Plus",
        category: "Gaming",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "nintendo": KnownBrandProfile(
        name: "Nintendo Switch Online",
        category: "Gaming",
        kind: .subscriptionService,
        affinity: 0.93,
        confidence: 0.92
    ),
    "steam": KnownBrandProfile(
        name: "Steam",
        category: "Gaming",
        kind: .marketplace,
        affinity: 0.15,
        confidence: 0.88
    ),
    "nordvpn": KnownBrandProfile(
        name: "NordVPN",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.95
    ),
    "expressvpn": KnownBrandProfile(
        name: "ExpressVPN",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "costco": KnownBrandProfile(
        name: "Costco",
        category: "Membership",
        kind: .membershipRetailer,
        affinity: 0.32,
        confidence: 0.88
    ),
    "amazon": KnownBrandProfile(
        name: "Amazon",
        category: "Marketplace",
        kind: .marketplace,
        affinity: 0.1,
        confidence: 0.9
    ),
    "amazon web services": KnownBrandProfile(
        name: "AWS",
        category: "Cloud Infrastructure",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.97
    ),
    "aws": KnownBrandProfile(
        name: "AWS",
        category: "Cloud Infrastructure",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.97
    ),
    "whole foods": KnownBrandProfile(
        name: "Whole Foods",
        category: "Groceries",
        kind: .groceryRetailer,
        affinity: 0.08,
        confidence: 0.9
    ),
    "vercel": KnownBrandProfile(
        name: "Vercel",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "railway": KnownBrandProfile(
        name: "Railway",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "render.com": KnownBrandProfile(
        name: "Render",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "fly.io": KnownBrandProfile(
        name: "Fly.io",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "tailscale": KnownBrandProfile(
        name: "Tailscale",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "mullvad": KnownBrandProfile(
        name: "Mullvad VPN",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "proton": KnownBrandProfile(
        name: "Proton",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "duolingo": KnownBrandProfile(
        name: "Duolingo",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.95
    ),
    "noom": KnownBrandProfile(
        name: "Noom",
        category: "Wellness",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "masterclass": KnownBrandProfile(
        name: "MasterClass",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.95
    ),
    "brilliant.org": KnownBrandProfile(
        name: "Brilliant",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.93
    ),
    "espn+": KnownBrandProfile(
        name: "ESPN+",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.96,
        confidence: 0.95
    ),
    "espn plus": KnownBrandProfile(
        name: "ESPN+",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.96,
        confidence: 0.95
    ),
    "siriusxm": KnownBrandProfile(
        name: "SiriusXM",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.94
    ),
    "sirius": KnownBrandProfile(
        name: "SiriusXM",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.94
    ),
    "pandora": KnownBrandProfile(
        name: "Pandora",
        category: "Music",
        kind: .mediaStreaming,
        affinity: 0.94,
        confidence: 0.93
    ),
    "deezer": KnownBrandProfile(
        name: "Deezer",
        category: "Music",
        kind: .mediaStreaming,
        affinity: 0.94,
        confidence: 0.93
    ),
    "twitch": KnownBrandProfile(
        name: "Twitch",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.85,
        confidence: 0.90
    ),
    "skillshare": KnownBrandProfile(
        name: "Skillshare",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.95,
        confidence: 0.94
    ),
    "coursera": KnownBrandProfile(
        name: "Coursera",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.93,
        confidence: 0.93
    ),
    "linkedin premium": KnownBrandProfile(
        name: "LinkedIn Premium",
        category: "Software",
        kind: .subscriptionService,
        affinity: 0.94,
        confidence: 0.94
    ),
    "linkedin learning": KnownBrandProfile(
        name: "LinkedIn Learning",
        category: "Education",
        kind: .subscriptionService,
        affinity: 0.93,
        confidence: 0.93
    ),
    "evernote": KnownBrandProfile(
        name: "Evernote",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.94
    ),
    "todoist": KnownBrandProfile(
        name: "Todoist",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "dashlane": KnownBrandProfile(
        name: "Dashlane",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "lastpass": KnownBrandProfile(
        name: "LastPass",
        category: "Security",
        kind: .softwareOrSaaS,
        affinity: 0.94,
        confidence: 0.94
    ),
    "obsidian": KnownBrandProfile(
        name: "Obsidian",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "day one": KnownBrandProfile(
        name: "Day One",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.93,
        confidence: 0.93
    ),
    "nebula": KnownBrandProfile(
        name: "Nebula",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.93
    ),
    "curiositystream": KnownBrandProfile(
        name: "CuriosityStream",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.93
    ),
    "curiosity stream": KnownBrandProfile(
        name: "CuriosityStream",
        category: "Streaming",
        kind: .mediaStreaming,
        affinity: 0.95,
        confidence: 0.93
    ),
    "github copilot": KnownBrandProfile(
        name: "GitHub Copilot",
        category: "AI",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "microsoft copilot": KnownBrandProfile(
        name: "Microsoft Copilot",
        category: "AI",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "copilot pro": KnownBrandProfile(
        name: "Copilot Pro",
        category: "AI",
        kind: .softwareOrSaaS,
        affinity: 0.95,
        confidence: 0.94
    ),
    "apple fitness": KnownBrandProfile(
        name: "Apple Fitness+",
        category: "Fitness",
        kind: .subscriptionService,
        affinity: 0.96,
        confidence: 0.95
    ),
    "anthropic": KnownBrandProfile(
        name: "Anthropic",
        category: "AI",
        kind: .subscriptionService,
        affinity: 0.98,
        confidence: 0.96
    ),
    "microsoft": KnownBrandProfile(
        name: "Microsoft",
        category: "Software",
        kind: .softwareOrSaaS,
        affinity: 0.92,
        confidence: 0.93
    )
]

private let merchantKindRules: [MerchantKindRule] = [
    MerchantKindRule(
        kind: .mediaStreaming,
        tokens: ["stream", "music", "video", "netflix", "hulu", "youtube", "spotify"]
    ),
    MerchantKindRule(
        kind: .softwareOrSaaS,
        tokens: [
            "software", "app", "saas", "adobe", "dropbox",
            "icloud", "cloud", "storage"
        ]
    ),
    MerchantKindRule(
        kind: .marketplace,
        tokens: [
            "marketplace", "order", "shipment", "seller",
            "amazon", "etsy", "ebay"
        ]
    ),
    MerchantKindRule(
        kind: .groceryRetailer,
        tokens: ["grocery", "grocer", "market", "costco", "whole foods", "supermarket"]
    ),
    MerchantKindRule(
        kind: .restaurant,
        tokens: ["restaurant", "dining", "cafe", "coffee", "bar", "doordash", "ubereats"]
    ),
    MerchantKindRule(
        kind: .medicalOrWellnessProvider,
        tokens: [
            "chiropr", "doctor", "clinic", "medical", "wellness",
            "therapy", "massage", "copay", "pharmacy", "dental"
        ]
    ),
    MerchantKindRule(
        kind: .transportOrTravel,
        tokens: [
            "uber", "lyft", "airline", "hotel", "travel",
            "transit", "transport", "flight", "rental"
        ]
    ),
    MerchantKindRule(
        kind: .utilityOrBiller,
        tokens: [
            "utility", "electric", "water", "internet", "phone",
            "wireless", "gas bill", "insurance"
        ]
    ),
    MerchantKindRule(
        kind: .generalRetail,
        tokens: ["retail", "shopping", "store", "target", "walmart"]
    )
]

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

        if let brand = knownBrandProfiles
            .sorted(by: { $0.key.count > $1.key.count })
            .first(where: { combined.localizedStandardContains($0.key) })?.value {
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

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, *)
extension SystemLanguageModel.Availability.UnavailableReason {
    var description: String {
        switch self {
        case .deviceNotEligible:
            return "device not eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .modelNotReady:
            return "model assets are not ready"
        @unknown default:
            return "unknown availability reason"
        }
    }
}
#endif
