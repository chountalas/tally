import Foundation

enum SubscriptionClusteringMode {
    case primary
    case fallback

    var minimumClusterSize: Int { 2 }

    var absoluteAmountTolerance: Double {
        switch self {
        case .primary: 2.5
        case .fallback: 5
        }
    }

    var percentageAmountTolerance: Double {
        switch self {
        case .primary: 0.12
        case .fallback: 0.2
        }
    }
}

extension SubscriptionDetectionService {
    func candidateClusters(
        for merchant: String,
        transactions: [NormalizedTransaction],
        mode: SubscriptionClusteringMode = .primary
    ) -> [SubscriptionCandidateCluster] {
        let descriptorBuckets = Dictionary(grouping: transactions) { transaction in
            explicitClusterDescriptor(for: transaction) ?? "__general__"
        }

        var candidates: [SubscriptionCandidateCluster] = []

        for descriptorKey in descriptorBuckets.keys.sorted() {
            guard let bucket = descriptorBuckets[descriptorKey] else {
                continue
            }

            let descriptor = descriptorKey == "__general__" ? nil : descriptorKey
            let amountGroups = mergeSequentialPriceSteps(splitByAmountSimilarity(bucket, mode: mode))
                .filter { $0.count >= mode.minimumClusterSize }
                .sorted { lhs, rhs in
                    lhs.count == rhs.count
                        ? averageAbsoluteAmount(for: lhs) < averageAbsoluteAmount(for: rhs)
                        : lhs.count > rhs.count
                }

            let displayNames = amountGroups.enumerated().map { index, group in
                clusterDisplayName(
                    merchant: merchant,
                    descriptor: descriptor,
                    transactions: group,
                    clusterIndex: index,
                    totalClusters: amountGroups.count
                )
            }

            for (index, group) in amountGroups.enumerated() {
                let displayName = displayNames[index]
                let canonicalName = amountGroups.count == 1 ? merchant : displayName
                candidates.append(
                    SubscriptionCandidateCluster(
                        canonicalName: canonicalName,
                        displayName: displayName,
                        transactions: group
                    )
                )
            }
        }

        if mode == .fallback, candidates.isEmpty {
            let amountGroups = mergeSequentialPriceSteps(splitByAmountSimilarity(transactions, mode: mode))
                .filter { $0.count >= mode.minimumClusterSize }

            for (index, group) in amountGroups.enumerated() {
                let displayName = clusterDisplayName(
                    merchant: merchant,
                    descriptor: nil,
                    transactions: group,
                    clusterIndex: index,
                    totalClusters: amountGroups.count
                )
                let canonicalName = amountGroups.count == 1 ? merchant : displayName
                candidates.append(
                    SubscriptionCandidateCluster(
                        canonicalName: canonicalName,
                        displayName: displayName,
                        transactions: group
                    )
                )
            }
        }

        return candidates
    }

    func fallbackRecoveryGroups(
        from transactions: [NormalizedTransaction]
    ) -> [(merchant: String, transactions: [NormalizedTransaction])] {
        let groups = Dictionary(grouping: transactions, by: recoveryGroupingKey(for:))

        return groups
            .values
            .filter { $0.count >= 2 }
            .filter { group in
                let isPureFinancialMovement = group.allSatisfy(isFinancialMovement)
                let hasSubscriptionWording = group.contains(where: hasStrongSubscriptionWording)
                return isPureFinancialMovement == false || hasSubscriptionWording
            }
            .map { group in
                (
                    merchant: fallbackDisplayName(for: group),
                    transactions: group.sorted { $0.transactionDate < $1.transactionDate }
                )
            }
            .sorted { lhs, rhs in
                lhs.merchant.localizedStandardCompare(rhs.merchant) == .orderedAscending
            }
    }

    func explicitClusterDescriptor(for transaction: NormalizedTransaction) -> String? {
        let combined = [
            transaction.memo,
            transaction.category,
            transaction.merchantRaw,
            transaction.merchantNormalized
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let descriptors: [(match: String, label: String)] = [
            ("amazon prime", "Prime"),
            ("prime membership", "Prime"),
            ("member annual", "Membership"),
            ("membership", "Membership"),
            ("auto pay", "Autopay"),
            ("autopay", "Autopay"),
            ("icloud+", "iCloud"),
            ("icloud", "iCloud"),
            ("apple one", "Apple One"),
            ("kindle unlimited", "Kindle Unlimited"),
            ("youtube premium", "YouTube Premium"),
            ("premium", "Premium"),
            ("family plan", "Family"),
            ("bundle", "Bundle"),
            ("game pass", "Game Pass"),
            ("xbox live", "Xbox Live"),
            ("playstation plus", "PlayStation Plus"),
            ("apple music", "Apple Music"),
            ("apple tv", "Apple TV+"),
            ("apple arcade", "Apple Arcade"),
            ("apple fitness", "Apple Fitness+"),
            ("disney+", "Disney+"),
            ("paramount+", "Paramount+"),
            ("google one", "Google One"),
            ("microsoft 365", "Microsoft 365"),
            ("office 365", "Microsoft 365"),
            ("creative cloud", "Creative Cloud"),
            ("basic plan", "Basic"),
            ("standard plan", "Standard"),
            ("pro plan", "Pro")
        ]

        return descriptors.first(where: { combined.localizedStandardContains($0.match) })?.label
    }

    func splitByAmountSimilarity(
        _ transactions: [NormalizedTransaction],
        mode: SubscriptionClusteringMode = .primary
    ) -> [[NormalizedTransaction]] {
        let sorted = transactions.sorted { absoluteAmount(for: $0) < absoluteAmount(for: $1) }
        var groups: [AmountCluster] = []
        let toleranceProfile = amountToleranceProfile(for: transactions, mode: mode)

        for transaction in sorted {
            let amount = absoluteAmount(for: transaction)

            if let index = groups.firstIndex(where: { cluster in
                abs(cluster.averageAmount - amount) <= max(
                    toleranceProfile.absolute,
                    cluster.averageAmount * toleranceProfile.percentage
                )
            }) {
                groups[index].transactions.append(transaction)
                groups[index].averageAmount = averageAbsoluteAmount(for: groups[index].transactions)
            } else {
                groups.append(
                    AmountCluster(
                        transactions: [transaction],
                        averageAmount: amount
                    )
                )
            }
        }

        return groups.map(\.transactions)
    }

    /// A price change makes one subscription look like two amount clusters that
    /// never overlap in time. Re-join sequential clusters whose combined charge
    /// history still reads as one consistent cadence, so a $9.99 → $14.99 bump
    /// stays a single subscription instead of fragmenting below the minimum
    /// cluster size.
    func mergeSequentialPriceSteps(
        _ groups: [[NormalizedTransaction]]
    ) -> [[NormalizedTransaction]] {
        guard groups.count > 1 else {
            return groups
        }

        let ordered = groups
            .map { $0.sorted { $0.transactionDate < $1.transactionDate } }
            .sorted { ($0.first?.transactionDate ?? .distantPast) < ($1.first?.transactionDate ?? .distantPast) }

        var merged: [[NormalizedTransaction]] = []
        var current = ordered[0]

        for next in ordered.dropFirst() {
            if looksLikePriceStepContinuation(from: current, to: next) {
                current = (current + next).sorted { $0.transactionDate < $1.transactionDate }
            } else {
                merged.append(current)
                current = next
            }
        }

        merged.append(current)
        return merged
    }

    func looksLikePriceStepContinuation(
        from earlier: [NormalizedTransaction],
        to later: [NormalizedTransaction]
    ) -> Bool {
        guard let earlierLast = earlier.last?.transactionDate,
              let laterFirst = later.first?.transactionDate,
              laterFirst > earlierLast else {
            return false
        }

        let earlierAverage = averageAbsoluteAmount(for: earlier)
        let laterAverage = averageAbsoluteAmount(for: later)
        guard earlierAverage > 0, laterAverage > 0 else {
            return false
        }

        let step = abs(laterAverage - earlierAverage) / max(earlierAverage, laterAverage)
        guard step <= 0.6 else {
            return false
        }

        let combined = (earlier + later).sorted { $0.transactionDate < $1.transactionDate }
        let intervals = zip(combined, combined.dropFirst()).map { lhs, rhs in
            Calendar.current.dateComponents([.day], from: lhs.transactionDate, to: rhs.transactionDate).day ?? 0
        }
        let cadence = inferCadence(from: intervals, occurrenceCount: combined.count)
        guard cadence != .unknown else {
            return false
        }

        return recurrenceConsistency(for: intervals, cadence: cadence) >= 0.55
    }

    func amountToleranceProfile(
        for transactions: [NormalizedTransaction],
        mode: SubscriptionClusteringMode
    ) -> (absolute: Double, percentage: Double) {
        let averageAffinity = transactions
            .map(\.merchantSubscriptionAffinity)
            .reduce(0, +) / Double(max(transactions.count, 1))
        let dominantKind = dominantMerchantKind(for: transactions)
        let hasUsageSignals = transactions.contains { transaction in
            let combined = [
                transaction.memo,
                transaction.category,
                transaction.merchantRaw,
                transaction.merchantNormalized
            ]
                .compactMap { $0?.lowercased() }
                .joined(separator: " ")

            return [
                "usage",
                "metered",
                "compute",
                "storage",
                "hosting",
                "infrastructure",
                "seat",
                "workspace"
            ].contains { combined.localizedStandardContains($0) }
        }

        let allowsVariableBilling =
            dominantKind == .softwareOrSaaS ||
            (averageAffinity >= 0.88 && dominantKind == .subscriptionService)

        guard allowsVariableBilling || hasUsageSignals else {
            return (mode.absoluteAmountTolerance, mode.percentageAmountTolerance)
        }

        return (
            max(mode.absoluteAmountTolerance, 10),
            max(mode.percentageAmountTolerance, mode == .primary ? 0.24 : 0.28)
        )
    }

    func clusterDisplayName(
        merchant: String,
        descriptor: String?,
        transactions: [NormalizedTransaction],
        clusterIndex: Int,
        totalClusters: Int
    ) -> String {
        let baseName: String
        if let descriptor, merchant.localizedStandardContains(descriptor) == false {
            baseName = "\(merchant) \(descriptor)"
        } else {
            baseName = merchant
        }

        guard totalClusters > 1 else {
            return baseName
        }

        if descriptor != nil, clusterIndex == 0 {
            return baseName
        }

        let averageAmount = Decimal(averageAbsoluteAmount(for: transactions))
        let currencyCode = transactions.last?.currency ?? "USD"
        return "\(baseName) \(averageAmount.currencyString(code: currencyCode))"
    }

    func absoluteAmount(for transaction: NormalizedTransaction) -> Double {
        abs((transaction.transactionAmount as NSDecimalNumber).doubleValue)
    }

    func averageAbsoluteAmount(for transactions: [NormalizedTransaction]) -> Double {
        guard transactions.isEmpty == false else {
            return 0
        }

        return transactions.map(absoluteAmount(for:)).reduce(0, +) / Double(transactions.count)
    }

    func recoveryGroupingKey(for transaction: NormalizedTransaction) -> String {
        if transaction.classificationConfidence >= 0.75 {
            return transaction.merchantNormalized.lowercased()
        }

        let sources = [
            transaction.merchantNormalized,
            transaction.merchantRaw,
            transaction.memo,
            explicitClusterDescriptor(for: transaction)
        ]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")

        let stopWords: Set<String> = [
            "subscription",
            "subscriptions",
            "membership",
            "member",
            "monthly",
            "annual",
            "plan",
            "charge",
            "payment",
            "inc",
            "llc",
            "corp",
            "co",
            "com"
        ]
        let tokens = sources
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 }
            .filter { !stopWords.contains($0) }

        let key = Array(tokens.prefix(2)).joined(separator: " ")
        return key.isEmpty ? transaction.merchantNormalized.lowercased() : key
    }

    func fallbackDisplayName(for transactions: [NormalizedTransaction]) -> String {
        let candidates = transactions.compactMap {
            $0.merchantNormalized.nilIfBlank ?? $0.merchantRaw.nilIfBlank
        }
        let grouped = Dictionary(grouping: candidates, by: { $0 })
        return grouped.max { lhs, rhs in lhs.value.count < rhs.value.count }?.key ?? "Recovered recurring charges"
    }
}

struct SubscriptionCandidateCluster {
    let canonicalName: String
    let displayName: String
    let transactions: [NormalizedTransaction]
}

private struct AmountCluster {
    var transactions: [NormalizedTransaction]
    var averageAmount: Double
}
