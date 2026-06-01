import Foundation

extension TabularTransactionDraftBuilder {
    func suggestMapping(
        headers: [String],
        rows: [[String: String]]
    ) -> (config: ColumnMappingConfig, confidence: Double) {
        let parser = TransactionFieldParser()
        let mappingContext = suggestedMappingContext(
            headers: headers,
            rows: rows,
            parser: parser
        )
        let textPlans = textColumnPlans(for: mappingContext)
        let merchantColumn = bestTextColumn(
            in: headers,
            rows: rows,
            parser: parser,
            plan: textPlans.merchant
        )
        let descriptionColumn = bestTextColumn(
            in: headers,
            rows: rows,
            parser: parser,
            plan: textPlans.description(merchantColumn: merchantColumn)
        )

        return (
            suggestedMappingConfig(
                context: mappingContext,
                merchantColumn: merchantColumn,
                descriptionColumn: descriptionColumn,
                rows: rows,
                parser: parser
            ),
            mappingConfidence(
                using: mappingContext,
                merchantColumn: merchantColumn,
                descriptionColumn: descriptionColumn,
                rows: rows,
                parser: parser
            )
        )
    }

    private func suggestedMappingContext(
        headers: [String],
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> TabularMappingContext {
        let dateColumn = bestDateColumn(in: headers, rows: rows, parser: parser) ?? headers[0]
        let amountColumn = bestAmountColumn(in: headers, rows: rows, parser: parser) ??
            headers.dropFirst().first ??
            headers[0]

        return TabularMappingContext(
            dateColumn: dateColumn,
            amountColumn: amountColumn,
            categoryColumn: bestKeywordColumn(
                in: headers,
                keywords: ["category", "service category", "type", "classification", "group"]
            ),
            accountColumn: bestKeywordColumn(
                in: headers,
                keywords: ["account", "card", "wallet", "source", "payment method"]
            ),
            currencyColumn: bestKeywordColumn(
                in: headers,
                keywords: ["currency", "curr", "fx currency"]
            )
        )
    }

    private func suggestedMappingConfig(
        context: TabularMappingContext,
        merchantColumn: String?,
        descriptionColumn: String?,
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> ColumnMappingConfig {
        ColumnMappingConfig(
            dateColumn: context.dateColumn,
            descriptionColumn: descriptionColumn,
            amountColumn: context.amountColumn,
            merchantColumn: merchantColumn,
            categoryColumn: context.categoryColumn,
            accountColumn: context.accountColumn,
            currencyColumn: context.currencyColumn,
            debitSignConvention: debitSignConvention(
                for: context.amountColumn,
                rows: rows,
                parser: parser
            )
        )
    }

    private func bestDateColumn(
        in headers: [String],
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> String? {
        bestColumn(
            in: headers,
            rows: rows,
            keywords: ["date", "posted date", "transaction date", "post date", "effective date", "booking date"],
            parser: parser.tryParseDate
        )
    }

    private func bestAmountColumn(
        in headers: [String],
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> String? {
        bestColumn(
            in: headers,
            rows: rows,
            keywords: [
                "amount",
                "transaction amount",
                "net amount",
                "debit",
                "credit",
                "charge",
                "payment",
                "withdrawal",
                "deposit",
                "total",
                "value"
            ],
            parser: parser.tryParseAmount
        )
    }

    private func textColumnPlans(for context: TabularMappingContext) -> TabularTextColumnPlans {
        TabularTextColumnPlans(baseExclusions: context.baseExclusions)
    }

    private func debitSignConvention(
        for amountColumn: String,
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> DebitSign {
        let amountSamples = rows.prefix(12).compactMap { row in row[amountColumn] }
        let positiveCount = amountSamples.compactMap(parser.tryParseAmount).filter { $0 > 0 }.count
        let negativeCount = amountSamples.compactMap(parser.tryParseAmount).filter { $0 < 0 }.count
        return positiveCount > negativeCount ? .positive : .negative
    }

    private func mappingConfidence(
        using context: TabularMappingContext,
        merchantColumn: String?,
        descriptionColumn: String?,
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> Double {
        let requiredMatches = [
            parseableFraction(for: context.dateColumn, rows: rows, parser: parser.tryParseDate) > 0.5,
            parseableFraction(for: context.amountColumn, rows: rows, parser: parser.tryParseAmount) > 0.5,
            merchantColumn != nil || descriptionColumn != nil
        ]
        return Double(requiredMatches.filter(\.self).count) / Double(requiredMatches.count)
    }

    private func bestKeywordColumn(in headers: [String], keywords: [String]) -> String? {
        headers
            .map { ($0, keywordScore(for: $0, keywords: keywords)) }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }
            .map(\.0)
    }

    private func bestColumn<Value>(
        in headers: [String],
        rows: [[String: String]],
        keywords: [String],
        parser: (String) -> Value?
    ) -> String? {
        headers
            .map { header in
                let score = keywordScore(for: header, keywords: keywords) * 2
                    + parseableFraction(for: header, rows: rows, parser: parser)
                return (header, score)
            }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in lhs.1 < rhs.1 }
            .map(\.0)
    }

    private func bestTextColumn(
        in headers: [String],
        rows: [[String: String]],
        parser: TransactionFieldParser,
        plan: TabularTextColumnPlan
    ) -> String? {
        let excludedHeaders = Set(plan.exclusions.compactMap { $0 })

        return headers
            .filter { !excludedHeaders.contains($0) }
            .filter { keywordScore(for: $0, keywords: plan.disallowedKeywords) == 0 }
            .map { header in
                let score = keywordScore(for: header, keywords: plan.keywords) * 2
                    + textSampleScore(for: header, rows: rows, parser: parser)
                return (header, score)
            }
            .filter { $0.1 >= 0.35 }
            .max { lhs, rhs in lhs.1 < rhs.1 }
            .map(\.0)
    }

    private func parseableFraction<Value>(
        for header: String,
        rows: [[String: String]],
        parser: (String) -> Value?
    ) -> Double {
        let samples = sampleValues(for: header, rows: rows)
        guard !samples.isEmpty else {
            return 0
        }

        let matches = samples.compactMap(parser).count
        return Double(matches) / Double(samples.count)
    }

    private func textSampleScore(
        for header: String,
        rows: [[String: String]],
        parser: TransactionFieldParser
    ) -> Double {
        let samples = sampleValues(for: header, rows: rows)
        guard !samples.isEmpty else {
            return 0
        }

        let alphaHeavyCount = samples.filter { $0.containsLetter }.count
        let nonDateCount = samples.filter { parser.tryParseDate($0) == nil }.count
        let nonAmountCount = samples.filter { parser.tryParseAmount($0) == nil }.count

        return (Double(alphaHeavyCount) + Double(nonDateCount) + Double(nonAmountCount))
            / Double(samples.count * 3)
    }

    private func sampleValues(
        for header: String,
        rows: [[String: String]],
        limit: Int = 12
    ) -> [String] {
        rows.prefix(limit).compactMap { row in
            let value = row[header]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return value.isEmpty ? nil : value
        }
    }

    private func keywordScore(for header: String, keywords: [String]) -> Double {
        let normalizedHeader = header.normalizedColumnName

        return keywords.reduce(0) { bestScore, keyword in
            let normalizedKeyword = keyword.normalizedColumnName
            let score: Double
            if normalizedHeader == normalizedKeyword {
                score = 1
            } else if normalizedHeader.contains(normalizedKeyword) {
                score = 0.9
            } else {
                let headerTokens = Set(normalizedHeader.split(separator: " ").map(String.init))
                let keywordTokens = Set(normalizedKeyword.split(separator: " ").map(String.init))
                score = keywordTokens.isSubset(of: headerTokens) ? 0.7 : 0
            }
            return max(bestScore, score)
        }
    }
}

private struct TabularMappingContext {
    let dateColumn: String
    let amountColumn: String
    let categoryColumn: String?
    let accountColumn: String?
    let currencyColumn: String?

    var baseExclusions: [String?] {
        [dateColumn, amountColumn, categoryColumn, accountColumn, currencyColumn]
    }
}

private struct TabularTextColumnPlans {
    let baseExclusions: [String?]

    var merchant: TabularTextColumnPlan {
        TabularTextColumnPlan(
            keywords: ["merchant", "vendor", "payee", "counterparty", "seller", "name"],
            disallowedKeywords: [
                "description",
                "memo",
                "details",
                "reference",
                "statement",
                "note",
                "comment",
                "remarks"
            ],
            exclusions: baseExclusions
        )
    }

    func description(merchantColumn: String?) -> TabularTextColumnPlan {
        TabularTextColumnPlan(
            keywords: [
                "original statement",
                "statement",
                "description",
                "memo",
                "details",
                "reference",
                "narrative",
                "transaction details",
                "notes",
                "note",
                "comment",
                "remarks"
            ],
            disallowedKeywords: [],
            exclusions: baseExclusions + [merchantColumn]
        )
    }
}

private struct TabularTextColumnPlan {
    let keywords: [String]
    let disallowedKeywords: [String]
    let exclusions: [String?]
}
