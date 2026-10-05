import Foundation
import SwiftData

extension AppModel {
    /// Merchant learning applies to the entire payee only when no sibling
    /// subscription shares its descriptors. Otherwise, edits belong to a history.
    func prepareHistoryLearningScope(
        for subscription: Subscription, linkedTransactions: [NormalizedTransaction], in context: ModelContext
    ) throws -> Bool {
        let rawMerchants = Set(linkedTransactions.map(\.merchantRaw))
        let sharedMerchant = try context.fetch(FetchDescriptor<NormalizedTransaction>()).contains {
            rawMerchants.contains($0.merchantRaw) && $0.subscriptionID != nil && $0.subscriptionID != subscription.id
        }
        guard subscription.historyIdentity != nil || sharedMerchant else { return false }
        guard subscription.historyIdentity == nil, let first = linkedTransactions.min(by: {
            $0.transactionDate == $1.transactionDate ? $0.id.uuidString < $1.id.uuidString : $0.transactionDate < $1.transactionDate
        }) else { return true }

        let oldKey = subscription.canonicalName
        let newKey = SubscriptionHistoryKey(merchant: oldKey, firstChargeID: first.id).rawValue
        let rules = try context.fetch(FetchDescriptor<SubscriptionReviewRule>(
            predicate: #Predicate { $0.canonicalName == oldKey }
        ))
        for rule in rules { rule.canonicalName = newKey }
        let corrections = try context.fetch(FetchDescriptor<MerchantCorrection>(
            predicate: #Predicate { $0.canonicalName == oldKey }
        ))
        for correction in corrections { correction.canonicalName = newKey }
        let subscriptionID = subscription.id
        let matchRules = try context.fetch(FetchDescriptor<SubscriptionMatchRule>(
            predicate: #Predicate { $0.canonicalName == oldKey && $0.subscriptionID == subscriptionID }
        ))
        for rule in matchRules { context.delete(rule) }
        subscription.canonicalName = newKey
        return true
    }
}
