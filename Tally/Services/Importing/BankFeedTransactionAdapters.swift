import Foundation

struct OFXTransactionSourceAdapter {
    let source: TransactionSource
    let text: String

    init(text: String, source: TransactionSource = .ofx) {
        self.text = text
        self.source = source
    }

    func prepareTransactions() async throws -> [SourceTransactionDraft] {
        let documentCurrency = OFXTagParser.firstTag("CURDEF", in: text)
        let sections = OFXTagParser.statementSections(in: text)

        return sections.flatMap { section in
            let accountID = OFXTagParser.firstTag("ACCTID", in: section)
            let currency = OFXTagParser.firstTag("CURDEF", in: section) ?? documentCurrency
            let blocks = OFXTagParser.blocks(named: "STMTTRN", in: section)

            return blocks.compactMap { block in
                makeDraft(
                    from: block,
                    accountID: accountID,
                    currency: currency
                )
            }
        }
    }

    private func makeDraft(
        from block: String,
        accountID: String?,
        currency: String?
    ) -> SourceTransactionDraft? {
        guard
            let date = OFXDateParser.date(from: OFXTagParser.firstTag("DTPOSTED", in: block)),
            let amountValue = OFXTagParser.firstTag("TRNAMT", in: block),
            let amount = Decimal(string: amountValue.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }

        let merchant = [
            OFXTagParser.firstTag("NAME", in: block),
            OFXTagParser.firstTag("PAYEE", in: block),
            OFXTagParser.firstTag("MEMO", in: block)
        ]
            .compactMap { $0?.nilIfBlank }
            .first ?? "Unknown merchant"
        let fitID = OFXTagParser.firstTag("FITID", in: block)?.nilIfBlank
        let memo = OFXTagParser.firstTag("MEMO", in: block)?.nilIfBlank
        let transactionType = OFXTagParser.firstTag("TRNTYPE", in: block)?.nilIfBlank
        let seed = NormalizedTransactionSeed(
            transactionDate: date,
            transactionAmount: amount,
            merchantRaw: merchant,
            category: transactionType,
            accountName: accountID?.nilIfBlank,
            memo: memo,
            currency: currency?.nilIfBlank
        )

        return SourceTransactionDraft(
            seed: seed,
            source: source,
            externalTransactionID: fitID,
            externalAccountID: accountID,
            sourceReferenceID: fitID,
            sourceFingerprint: SourceTransactionDraft.fingerprint(for: seed),
            sourceMetadata: [
                "format": source.rawValue,
                "transactionType": transactionType ?? ""
            ].filter { $0.value.isEmpty == false }
        )
    }
}

struct SimpleFINTransactionSourceAdapter {
    let source: TransactionSource = .simpleFIN
    let data: Data

    func prepareTransactions() async throws -> [SourceTransactionDraft] {
        let payload = try JSONDecoder().decode(SimpleFINPayload.self, from: data)
        return payload.accounts.flatMap { account in
            account.transactions.compactMap { transaction in
                guard
                    let postedDate = transaction.posted.nonZeroDateValue ?? transaction.transactedAt?.nonZeroDateValue,
                    let amount = Decimal(string: transaction.amount)
                else {
                    return nil
                }

                let merchant = [
                    transaction.payee,
                    transaction.description,
                    transaction.memo
                ]
                    .compactMap { $0?.nilIfBlank }
                    .first ?? "Unknown merchant"
                let seed = NormalizedTransactionSeed(
                    transactionDate: postedDate,
                    transactionAmount: amount,
                    merchantRaw: merchant,
                    category: nil,
                    accountName: account.name.nilIfBlank ?? account.id,
                    memo: transaction.memo?.nilIfBlank,
                    currency: account.currency?.nilIfBlank
                )

                return SourceTransactionDraft(
                    seed: seed,
                    source: source,
                    externalTransactionID: transaction.id.nilIfBlank,
                    externalAccountID: account.id,
                    sourceReferenceID: transaction.id.nilIfBlank,
                    sourceFingerprint: SourceTransactionDraft.fingerprint(for: seed),
                    pendingExternalTransactionID: transaction.pending == true ? transaction.id.nilIfBlank : nil,
                    status: transaction.pending == true ? .pending : .posted,
                    sourceMetadata: [
                        "accountID": account.id,
                        "pending": transaction.pending == true ? "true" : "false"
                    ]
                )
            }
        }
    }
}

private enum OFXTagParser {
    static func statementSections(in text: String) -> [String] {
        let sections = ["STMTRS", "CCSTMTRS", "INVSTMTRS"]
            .flatMap { blocks(named: $0, in: text) }
        return sections.isEmpty ? [text] : sections
    }

    static func firstTag(_ name: String, in text: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "<\(escapedName)>\\s*([^<\\r\\n]+)"
        guard
            let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = expression.firstMatch(
                in: text,
                range: NSRange(text.startIndex..<text.endIndex, in: text)
            ),
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func blocks(named name: String, in text: String) -> [String] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = "<\(escapedName)>[\\s\\S]*?</\(escapedName)>"
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let closedBlocks = expression.matches(in: text, range: range).compactMap { match in
            Range(match.range, in: text).map { String(text[$0]) }
        }
        if closedBlocks.isEmpty == false {
            return closedBlocks
        }

        return unclosedBlocks(named: name, in: text)
    }

    private static func unclosedBlocks(named name: String, in text: String) -> [String] {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        guard let expression = try? NSRegularExpression(
            pattern: "<\(escapedName)>",
            options: [.caseInsensitive]
        ) else {
            return []
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = expression.matches(in: text, range: range)
        guard matches.isEmpty == false else {
            return []
        }

        return matches.enumerated().compactMap { index, match in
            guard let blockStartRange = Range(match.range, in: text) else {
                return nil
            }

            let startIndex = blockStartRange.lowerBound
            let endIndex: String.Index
            if index + 1 < matches.count,
               let nextStartRange = Range(matches[index + 1].range, in: text) {
                endIndex = nextStartRange.lowerBound
            } else if let listEndRange = text.range(
                of: "</BANKTRANLIST>",
                options: [.caseInsensitive],
                range: blockStartRange.upperBound..<text.endIndex
            ) {
                endIndex = listEndRange.lowerBound
            } else {
                endIndex = text.endIndex
            }

            return String(text[startIndex..<endIndex])
        }
    }
}

private enum OFXDateParser {
    static func date(from value: String?) -> Date? {
        guard let value = value?.nilIfBlank else {
            return nil
        }
        let digits = String(value.prefix { $0.isNumber })
        guard digits.count >= 8 else {
            return nil
        }

        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = Int(digits.prefix(4))
        components.month = Int(digits.dropFirst(4).prefix(2))
        components.day = Int(digits.dropFirst(6).prefix(2))
        if digits.count >= 14 {
            components.hour = Int(digits.dropFirst(8).prefix(2))
            components.minute = Int(digits.dropFirst(10).prefix(2))
            components.second = Int(digits.dropFirst(12).prefix(2))
        }
        return components.date
    }
}

private struct SimpleFINPayload: Decodable {
    var accounts: [SimpleFINAccount]
}

private struct SimpleFINAccount: Decodable {
    var id: String
    var name: String
    var currency: String?
    var transactions: [SimpleFINTransaction]
}

private struct SimpleFINTransaction: Decodable {
    var id: String
    var posted: SimpleFINDate
    var transactedAt: SimpleFINDate?
    var amount: String
    var description: String?
    var payee: String?
    var memo: String?
    var pending: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case posted
        case transactedAt = "transacted_at"
        case amount
        case description
        case payee
        case memo
        case pending
    }
}

private enum SimpleFINDate: Decodable {
    case timestamp(TimeInterval)
    case string(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(TimeInterval.self) {
            self = .timestamp(value)
            return
        }
        self = .string(try container.decode(String.self))
    }

    var dateValue: Date? {
        switch self {
        case let .timestamp(value):
            return Date(timeIntervalSince1970: value)
        case let .string(value):
            if let timestamp = TimeInterval(value) {
                return Date(timeIntervalSince1970: timestamp)
            }
            return ISO8601DateFormatter().date(from: value)
        }
    }

    var nonZeroDateValue: Date? {
        switch self {
        case let .timestamp(value):
            guard value > 0 else {
                return nil
            }
            return Date(timeIntervalSince1970: value)
        case let .string(value):
            if let timestamp = TimeInterval(value) {
                guard timestamp > 0 else {
                    return nil
                }
                return Date(timeIntervalSince1970: timestamp)
            }
            return ISO8601DateFormatter().date(from: value)
        }
    }
}
