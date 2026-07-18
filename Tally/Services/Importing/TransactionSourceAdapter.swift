import Foundation
import SwiftData

struct SourceTransactionDraft: Equatable, Sendable {
    var seed: NormalizedTransactionSeed
    var source: TransactionSource
    var externalTransactionID: String?
    var externalAccountID: String?
    var sourceReferenceID: String?
    var sourceFingerprint: String
    var pendingExternalTransactionID: String?
    var status: SourceTransactionIdentityStatus
    var sourceMetadata: [String: String]

    init(
        seed: NormalizedTransactionSeed,
        source: TransactionSource,
        externalTransactionID: String? = nil,
        externalAccountID: String? = nil,
        sourceReferenceID: String? = nil,
        sourceFingerprint: String? = nil,
        pendingExternalTransactionID: String? = nil,
        status: SourceTransactionIdentityStatus = .posted,
        sourceMetadata: [String: String] = [:]
    ) {
        self.seed = seed
        self.source = source
        self.externalTransactionID = externalTransactionID?.nilIfBlank
        self.externalAccountID = externalAccountID?.nilIfBlank
        self.sourceReferenceID = sourceReferenceID?.nilIfBlank
        self.sourceFingerprint = sourceFingerprint?.nilIfBlank ?? Self.fingerprint(for: seed)
        self.pendingExternalTransactionID = pendingExternalTransactionID?.nilIfBlank
        self.status = status
        self.sourceMetadata = sourceMetadata
    }

    static func fingerprint(for seed: NormalizedTransactionSeed) -> String {
        [
            seed.transactionDate.ISO8601Format(),
            seed.transactionAmount.description,
            seed.merchantRaw.normalizedIdentityToken,
            seed.category?.normalizedIdentityToken ?? "",
            seed.accountName?.normalizedIdentityToken ?? "",
            seed.memo?.normalizedIdentityToken ?? "",
            seed.currency?.uppercased() ?? ""
        ].joined(separator: "|")
    }
}

struct SourceTransactionMaterialization: Sendable {
    var draft: SourceTransactionDraft
    var merchantNormalized: String
    var category: String?
    var merchantKind: MerchantKind
    var merchantSubscriptionAffinity: Double
    var classificationConfidence: Double
}

struct SourceTransactionUpsertSummary: Sendable {
    var insertedCount: Int = 0
    var updatedCount: Int = 0
    var unchangedCount: Int = 0
    var fuzzyDuplicateCount: Int = 0

    var reconciledCount: Int {
        insertedCount + updatedCount + unchangedCount
    }
}

@MainActor
struct SourceTransactionUpsertService {
    func upsert(
        _ materializations: [SourceTransactionMaterialization],
        importRecordID: UUID?,
        into context: ModelContext
    ) async throws -> SourceTransactionUpsertSummary {
        var summary = SourceTransactionUpsertSummary()
        var identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())
        var transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        var transactionsByID = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })

        for (index, materialization) in materializations.enumerated() {
            let match = findIdentity(
                for: materialization.draft,
                identities: identities,
                transactions: transactions
            )

            let identity: SourceTransactionIdentity
            let transaction: NormalizedTransaction
            let wasFuzzyMatch: Bool

            switch match {
            case let .identity(existing):
                identity = existing
                wasFuzzyMatch = false
                if let transactionID = existing.normalizedTransactionID,
                   let existingTransaction = transactionsByID[transactionID] {
                    transaction = existingTransaction
                } else {
                    transaction = makeTransaction(
                        from: materialization,
                        importRecordID: importRecordID
                    )
                    context.insert(transaction)
                    transactions.append(transaction)
                    transactionsByID[transaction.id] = transaction
                    identity.normalizedTransactionID = transaction.id
                    summary.insertedCount += 1
                }
            case let .fuzzyDuplicate(existingTransaction):
                wasFuzzyMatch = true
                transaction = existingTransaction
                identity = SourceTransactionIdentity(
                    normalizedTransactionID: transaction.id,
                    source: materialization.draft.source,
                    externalTransactionID: materialization.draft.externalTransactionID,
                    externalAccountID: materialization.draft.externalAccountID,
                    sourceReferenceID: materialization.draft.sourceReferenceID,
                    sourceFingerprint: materialization.draft.sourceFingerprint,
                    pendingExternalTransactionID: materialization.draft.pendingExternalTransactionID,
                    status: materialization.draft.status
                )
                context.insert(identity)
                identities.append(identity)
                summary.fuzzyDuplicateCount += 1
            case .none:
                wasFuzzyMatch = false
                transaction = makeTransaction(
                    from: materialization,
                    importRecordID: importRecordID
                )
                context.insert(transaction)
                transactions.append(transaction)
                transactionsByID[transaction.id] = transaction
                identity = SourceTransactionIdentity(
                    normalizedTransactionID: transaction.id,
                    source: materialization.draft.source,
                    externalTransactionID: materialization.draft.externalTransactionID,
                    externalAccountID: materialization.draft.externalAccountID,
                    sourceReferenceID: materialization.draft.sourceReferenceID,
                    sourceFingerprint: materialization.draft.sourceFingerprint,
                    pendingExternalTransactionID: materialization.draft.pendingExternalTransactionID,
                    status: materialization.draft.status
                )
                context.insert(identity)
                identities.append(identity)
                summary.insertedCount += 1
            }

            let changed = update(
                transaction,
                identity: identity,
                from: materialization,
                importRecordID: importRecordID
            )
            if changed, match.didFindExistingRecord {
                summary.updatedCount += 1
            } else if match.didFindExistingRecord && wasFuzzyMatch == false {
                summary.unchangedCount += 1
            }

            if index.isMultiple(of: 250) {
                await Task.yield()
            }
        }

        return summary
    }

}

private enum SourceIdentityMatch {
    case identity(SourceTransactionIdentity)
    case fuzzyDuplicate(NormalizedTransaction)
    case none

    var didFindExistingRecord: Bool {
        switch self {
        case .identity, .fuzzyDuplicate:
            return true
        case .none:
            return false
        }
    }
}

private extension SourceTransactionUpsertService {
    func findIdentity(
        for draft: SourceTransactionDraft,
        identities: [SourceTransactionIdentity],
        transactions: [NormalizedTransaction]
    ) -> SourceIdentityMatch {
        if let externalTransactionID = draft.externalTransactionID,
           let identity = identities.first(where: {
               $0.sourceRawValue == draft.source.rawValue &&
                   ($0.externalAccountID ?? "") == (draft.externalAccountID ?? "") &&
                   $0.externalTransactionID == externalTransactionID
           }) {
            return .identity(identity)
        }

        if let pendingExternalTransactionID = draft.pendingExternalTransactionID,
           let identity = identities.first(where: {
               $0.sourceRawValue == draft.source.rawValue &&
                   ($0.externalAccountID ?? "") == (draft.externalAccountID ?? "") &&
                   (
                    $0.externalTransactionID == pendingExternalTransactionID ||
                        $0.pendingExternalTransactionID == pendingExternalTransactionID
                   )
           }) {
            return .identity(identity)
        }

        if let sourceReferenceID = draft.sourceReferenceID,
           let identity = identities.first(where: {
            $0.sourceRawValue == draft.source.rawValue &&
                ($0.externalAccountID ?? "") == (draft.externalAccountID ?? "") &&
                $0.sourceReferenceID == sourceReferenceID &&
                $0.sourceFingerprint == draft.sourceFingerprint
        }) {
            return .identity(identity)
        }

        if let identity = fuzzyPendingReplacementIdentity(
            for: draft,
            identities: identities,
            transactions: transactions
        ) {
            return .identity(identity)
        }

        if let duplicate = fuzzyDuplicate(for: draft, transactions: transactions) {
            return .fuzzyDuplicate(duplicate)
        }

        return .none
    }

    func fuzzyDuplicate(
        for draft: SourceTransactionDraft,
        transactions: [NormalizedTransaction]
    ) -> NormalizedTransaction? {
        guard draft.sourceReferenceID == nil else {
            return nil
        }
        guard draft.externalTransactionID != nil || draft.pendingExternalTransactionID != nil else {
            return nil
        }

        return transactions.first { fuzzyTransactionMatches($0, draft: draft) }
    }

    func fuzzyPendingReplacementIdentity(
        for draft: SourceTransactionDraft,
        identities: [SourceTransactionIdentity],
        transactions: [NormalizedTransaction]
    ) -> SourceTransactionIdentity? {
        guard draft.externalTransactionID != nil else {
            return nil
        }

        for identity in identities where identity.status == .pending || identity.pendingExternalTransactionID != nil {
            guard identity.sourceRawValue == draft.source.rawValue else {
                continue
            }
            guard (identity.externalAccountID ?? "") == (draft.externalAccountID ?? "") else {
                continue
            }
            guard let transactionID = identity.normalizedTransactionID,
                  let transaction = transactions.first(where: { $0.id == transactionID }),
                  fuzzyTransactionMatches(transaction, draft: draft) else {
                continue
            }
            return identity
        }

        return nil
    }

    func fuzzyTransactionMatches(_ transaction: NormalizedTransaction, draft: SourceTransactionDraft) -> Bool {
        guard transaction.sourceRawValue == draft.source.rawValue else {
            return false
        }
        guard (transaction.accountName ?? "") == (draft.seed.accountName ?? "") else {
            return false
        }
        guard transaction.transactionAmount == draft.seed.transactionAmount else {
            return false
        }
        let days = abs(
            Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: transaction.transactionDate),
                to: Calendar.current.startOfDay(for: draft.seed.transactionDate)
            ).day ?? .max
        )
        guard days <= 2 else {
            return false
        }

        return merchantSimilarity(
            lhs: transaction.merchantRaw,
            rhs: draft.seed.merchantRaw
        ) >= 0.82
    }

    func makeTransaction(
        from materialization: SourceTransactionMaterialization,
        importRecordID: UUID?
    ) -> NormalizedTransaction {
        let draft = materialization.draft
        let transaction = NormalizedTransaction(
            transactionDate: draft.seed.transactionDate,
            transactionAmount: draft.seed.transactionAmount,
            source: draft.source,
            merchantRaw: draft.seed.merchantRaw,
            merchantNormalized: materialization.merchantNormalized,
            currency: draft.seed.currency,
            accountName: draft.seed.accountName,
            category: materialization.category,
            memo: draft.seed.memo,
            merchantKind: materialization.merchantKind,
            merchantSubscriptionAffinity: materialization.merchantSubscriptionAffinity,
            importRecordID: importRecordID,
            externalTransactionID: draft.externalTransactionID,
            externalAccountID: draft.externalAccountID,
            sourceReferenceID: draft.sourceReferenceID,
            sourceFingerprint: draft.sourceFingerprint,
            pendingExternalTransactionID: draft.pendingExternalTransactionID,
            sourceMetadataJSON: SubscriptionEvidenceJSON.encode(draft.sourceMetadata)
        )
        transaction.classificationConfidence = materialization.classificationConfidence
        return transaction
    }

    @discardableResult
    func update(
        _ transaction: NormalizedTransaction,
        identity: SourceTransactionIdentity,
        from materialization: SourceTransactionMaterialization,
        importRecordID: UUID?
    ) -> Bool {
        let draft = materialization.draft
        var changed = false

        func assign<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<NormalizedTransaction, Value>, _ value: Value) {
            if transaction[keyPath: keyPath] != value {
                transaction[keyPath: keyPath] = value
                changed = true
            }
        }

        assign(\.transactionDate, draft.seed.transactionDate)
        assign(\.transactionAmount, draft.seed.transactionAmount)
        assign(\.sourceRawValue, draft.source.rawValue)
        assign(\.merchantRaw, draft.seed.merchantRaw)
        assign(\.merchantNormalized, materialization.merchantNormalized)
        assign(\.currency, draft.seed.currency)
        assign(\.accountName, draft.seed.accountName)
        assign(\.category, materialization.category)
        assign(\.memo, draft.seed.memo)
        assign(\.merchantKindRawValue, materialization.merchantKind.rawValue)
        assign(\.merchantSubscriptionAffinity, materialization.merchantSubscriptionAffinity)
        assign(\.classificationConfidence, materialization.classificationConfidence)
        assign(\.importRecordID, importRecordID)
        assign(\.externalTransactionID, draft.externalTransactionID)
        assign(\.externalAccountID, draft.externalAccountID)
        assign(\.sourceReferenceID, draft.sourceReferenceID)
        assign(\.sourceFingerprint, draft.sourceFingerprint)
        assign(\.pendingExternalTransactionID, draft.pendingExternalTransactionID)
        assign(\.sourceMetadataJSON, SubscriptionEvidenceJSON.encode(draft.sourceMetadata))

        identity.normalizedTransactionID = transaction.id
        identity.source = draft.source
        identity.externalTransactionID = draft.externalTransactionID
        identity.externalAccountID = draft.externalAccountID
        identity.sourceReferenceID = draft.sourceReferenceID
        identity.sourceFingerprint = draft.sourceFingerprint
        identity.pendingExternalTransactionID = draft.pendingExternalTransactionID
        identity.status = draft.status
        identity.lastSeenAt = .now

        return changed
    }

    func merchantSimilarity(lhs: String, rhs: String) -> Double {
        let lhsTokens = Set(lhs.identityTokens)
        let rhsTokens = Set(rhs.identityTokens)
        guard lhsTokens.isEmpty == false, rhsTokens.isEmpty == false else {
            return lhs.normalizedIdentityToken == rhs.normalizedIdentityToken ? 1 : 0
        }

        let intersection = lhsTokens.intersection(rhsTokens).count
        let union = lhsTokens.union(rhsTokens).count
        return union == 0 ? 0 : Double(intersection) / Double(union)
    }
}

private extension String {
    var normalizedIdentityToken: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var identityTokens: [String] {
        normalizedIdentityToken
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 1 }
    }
}
