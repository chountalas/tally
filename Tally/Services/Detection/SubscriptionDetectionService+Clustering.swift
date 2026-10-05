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
        historyBuckets(transactions).flatMap { key, bucket in
            makeHistoryClusters(merchant: merchant, key: key, transactions: bucket,
                                histories: RecurringHistoryAnalyzer.histories(in: chargeSnapshots(bucket)), mode: mode)
        }
    }

    func candidateHistories(
        for merchant: String,
        transactions: [NormalizedTransaction],
        mode: SubscriptionClusteringMode = .primary
    ) async -> [SubscriptionCandidateCluster] {
        var clusters: [SubscriptionCandidateCluster] = []
        for (key, bucket) in historyBuckets(transactions) {
            guard !Task.isCancelled else { return [] }
            let histories = await RecurringHistoryAnalyzer.analyze(chargeSnapshots(bucket))
            clusters += makeHistoryClusters(merchant: merchant, key: key, transactions: bucket,
                                            histories: histories, mode: mode)
        }
        return clusters
    }

    private func chargeSnapshots(_ transactions: [NormalizedTransaction]) -> [RecurringCharge] {
        transactions.map { RecurringCharge(id: $0.id, date: $0.transactionDate, amount: abs($0.transactionAmount)) }
    }

    func canAnalyzeHistory(_ transactions: [NormalizedTransaction]) -> Bool {
        !transactions.allSatisfy { $0.merchantKind.isUsuallyNonSubscription || isRecurringBillOrNonSubscriptionSpend($0) } ||
            transactions.contains(where: hasExplicitSubscriptionKeywords)
    }

    private func historyBuckets(_ transactions: [NormalizedTransaction]) -> [(BillingHistoryKey, [NormalizedTransaction])] {
        guard canAnalyzeHistory(transactions) else { return [] }
        let buckets = Dictionary(grouping: transactions) {
            BillingHistoryKey(currency: $0.currency?.uppercased() ?? "USD",
                              account: $0.externalAccountID ?? $0.accountName ?? "",
                              descriptor: explicitClusterDescriptor(for: $0) ?? "",
                              merchantIdentity: $0.classificationConfidence >= 0.9 || hasExplicitSubscriptionKeywords($0)
                                ? $0.merchantNormalized : $0.merchantRaw.lowercased())
        }
        return buckets.sorted { $0.key.sortKey < $1.key.sortKey }.map { ($0.key, $0.value) }
    }

    private func makeHistoryClusters(
        merchant: String, key: BillingHistoryKey, transactions: [NormalizedTransaction],
        histories: [RecurringHistory], mode: SubscriptionClusteringMode
    ) -> [SubscriptionCandidateCluster] {
        let byID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
        let used = Set(histories.flatMap(\.transactionIDs))
        var clusters = histories.map { history in
            let charges = history.transactionIDs.compactMap { byID[$0] }
            let base = key.descriptor.isEmpty || merchant.localizedStandardContains(key.descriptor)
                ? merchant : "\(merchant) \(key.descriptor)"
            return SubscriptionCandidateCluster(canonicalName: merchant,
                                                displayName: base, transactions: charges, billingPattern: history)
        }
        // Ambiguous fragments still reach the existing review policy. They never
        // gain the calendar evidence of a reconstructed history.
        let fragments = splitByAmountSimilarity(transactions.filter { !used.contains($0.id) }, mode: mode)
            .filter { $0.count >= 2 }
        clusters += fragments.map {
            SubscriptionCandidateCluster(canonicalName: merchant, displayName: merchant, transactions: $0)
        }
        return clusters
    }

    func fallbackRecoveryGroups(
        from transactions: [NormalizedTransaction]
    ) -> [(merchant: String, transactions: [NormalizedTransaction])] {
        let eligible = transactions.filter { !$0.merchantKind.isUsuallyNonSubscription || hasExplicitSubscriptionKeywords($0) }
        let groups = Dictionary(grouping: eligible, by: recoveryGroupingKey(for:))

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
            ("icloud+", "iCloud"),
            ("icloud", "iCloud"),
            ("apple one", "Apple One"),
            ("kindle unlimited", "Kindle Unlimited"),
            ("youtube premium", "YouTube Premium"),
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
            ("creative cloud", "Creative Cloud")
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
                let count = Double(groups[index].transactions.count)
                groups[index].averageAmount = (groups[index].averageAmount * count + amount) / (count + 1)
                groups[index].transactions.append(transaction)
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
    var billingPattern: RecurringHistory?
}

private struct AmountCluster {
    var transactions: [NormalizedTransaction]
    var averageAmount: Double
}

private struct BillingHistoryKey: Hashable {
    let currency: String
    let account: String
    let descriptor: String
    let merchantIdentity: String
    var sortKey: String { [currency, account, descriptor, merchantIdentity].joined(separator: "|") }
}
