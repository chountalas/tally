import Foundation

extension SubscriptionDetectionService {
    func identifyHistories(
        _ clusters: [SubscriptionCandidateCluster], environment: DetectionEnvironment, state: DetectionAccumulator
    ) -> [SubscriptionCandidateCluster] {
        var owners: [Int: Subscription] = [:]
        let existingByID = Dictionary(uniqueKeysWithValues: environment.existingSubscriptions.map { ($0.id, $0) })
        let savedKeys = Set(environment.rulesByCanonical.keys)
            .union(environment.correctionsByCanonical.keys)
            .union(environment.existingByCanonical.keys)
        var rememberedKeysByChargeID: [UUID: String] = [:]
        for rawValue in savedKeys.sorted() {
            guard let key = SubscriptionHistoryKey(rawValue: rawValue) else { continue }
            if rememberedKeysByChargeID[key.firstChargeID] == nil {
                rememberedKeysByChargeID[key.firstChargeID] = rawValue
            }
        }
        var overlaps: [HistoryOverlap] = []
        for (index, cluster) in clusters.enumerated() {
            var counts: [UUID: Int] = [:]
            for transaction in cluster.transactions {
                if let owner = environment.previousAssignments[transaction.id] { counts[owner, default: 0] += 1 }
            }
            overlaps += counts.map { HistoryOverlap(index: index, id: $0.key, count: $0.value) }
        }
        overlaps.sort { $0.count == $1.count ? $0.index < $1.index : $0.count > $1.count }
        for overlap in overlaps where owners[overlap.index] == nil {
            guard !state.claimedSubscriptionIDs.contains(overlap.id), let existing = existingByID[overlap.id] else { continue }
            owners[overlap.index] = existing
            state.claimedSubscriptionIDs.insert(existing.id)
        }
        let merchantRuleIndex = clusters.firstIndex { cluster in
            cluster.billingPattern != nil && environment.rulesByCanonical[cluster.canonicalName] != nil &&
                environment.existingByCanonical[cluster.canonicalName] == nil
        }
        return clusters.enumerated().map { index, cluster in
            var existing = owners[index]
            // Imported legacy stores may not yet contain transaction links.
            if existing == nil, clusters.count == 1,
               let saved = environment.existingByCanonical[cluster.canonicalName],
               !state.claimedSubscriptionIDs.contains(saved.id),
               saved.priceCurrency == (cluster.transactions.first?.currency ?? "USD") {
                existing = saved
                state.claimedSubscriptionIDs.insert(saved.id)
            }
            let needsIdentity = clusters.count > 1 ||
                environment.existingByCanonical[cluster.canonicalName] != nil ||
                state.seenCanonicals.contains(cluster.canonicalName)
            // A rejected history has no live subscription or assigned charges.
            // Its saved anchor still identifies it when an older export extends
            // the history before that anchor.
            let rememberedKey = cluster.transactions.lazy.compactMap { rememberedKeysByChargeID[$0.id] }.first
            let key = existing?.canonicalName ?? rememberedKey ?? (index == merchantRuleIndex ? cluster.canonicalName :
                (needsIdentity ? historyKey(cluster) : cluster.canonicalName))
            let display = existing?.displayName ?? (clusters.count > 1 ? historyDisplayName(cluster) : cluster.displayName)
            return SubscriptionCandidateCluster(canonicalName: key, displayName: display,
                                                transactions: cluster.transactions, billingPattern: cluster.billingPattern)
        }
    }

    private func historyKey(_ cluster: SubscriptionCandidateCluster) -> String {
        // The earliest imported charge is a stable identity across reordered and
        // overlapping exports. Existing histories retain their persisted key.
        let first = cluster.transactions.min {
            $0.transactionDate == $1.transactionDate ? $0.id.uuidString < $1.id.uuidString : $0.transactionDate < $1.transactionDate
        }
        return SubscriptionHistoryKey(merchant: cluster.canonicalName, firstChargeID: first?.id ?? UUID()).rawValue
    }

    private func historyDisplayName(_ cluster: SubscriptionCandidateCluster) -> String {
        guard let schedule = cluster.billingPattern?.schedule else { return cluster.displayName }
        let phase = schedule.isMonthEnd ? "month end" : "day \(schedule.anchorDay)"
        let currency = cluster.transactions.first?.currency ?? "USD"
        return "\(cluster.displayName) · \(schedule.cadence.rawValue.capitalized), \(phase) · \(currency)"
    }
}

private struct HistoryOverlap {
    let index: Int
    let id: UUID
    let count: Int
}
