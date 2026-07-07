import Foundation

struct TabularTransactionDraftBuilder {
    func makeDraft(
        fileName: String,
        headers: [String],
        rows: [[String: String]],
        warnings: [String] = []
    ) throws -> TransactionImportDraft {
        guard !headers.isEmpty else {
            throw CSVImportError.emptyFile
        }

        let filteredRows = rows.filter { row in
            row.values.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        guard !filteredRows.isEmpty else {
            throw CSVImportError.noTransactionRows
        }

        let mapping = suggestMapping(headers: headers, rows: filteredRows)
        let preview = filteredRows.prefix(6).enumerated().map { offset, row in
            ImportPreviewRow(id: offset, values: row)
        }

        return TransactionImportDraft(
            fileName: fileName,
            headers: headers,
            previewRows: preview,
            rawRows: filteredRows,
            suggestedMapping: mapping.config,
            confidence: mapping.confidence,
            warnings: warnings
        )
    }

    func materializeTransactions(
        from draft: TransactionImportDraft,
        mapping: ColumnMappingConfig
    ) throws -> [NormalizedTransactionSeed] {
        try materializeSeeds(from: draft, mapping: mapping).seeds
    }

    func materializeSeeds(
        from draft: TransactionImportDraft,
        mapping: ColumnMappingConfig
    ) throws -> MaterializedTransactionSeeds {
        let parser = dateAwareParser(for: draft.rawRows, dateColumn: mapping.dateColumn)

        var seeds: [NormalizedTransactionSeed] = []
        var skippedRowCount = 0

        for row in draft.rawRows {
            let dateValue = row[mapping.dateColumn] ?? ""
            let amountValue = row[mapping.amountColumn] ?? ""
            let merchantValue = row[mapping.merchantColumn ?? ""] ??
                row[mapping.descriptionColumn ?? ""] ??
                ""

            // Blank rows are silently ignored; they are not "unreadable".
            guard !merchantValue.isEmpty else {
                continue
            }

            // A single unparseable date or amount skips just that row rather
            // than aborting the whole file. The count is surfaced to the user.
            guard let transactionDate = parser.tryParseDate(dateValue),
                  var amount = parser.tryParseAmount(amountValue) else {
                skippedRowCount += 1
                continue
            }

            if mapping.debitSignConvention == .positive {
                amount *= -1
            }

            seeds.append(
                NormalizedTransactionSeed(
                    transactionDate: transactionDate,
                    transactionAmount: amount,
                    merchantRaw: merchantValue,
                    category: row[mapping.categoryColumn ?? ""],
                    accountName: row[mapping.accountColumn ?? ""],
                    memo: row[mapping.descriptionColumn ?? ""],
                    currency: row[mapping.currencyColumn ?? ""]
                )
            )
        }

        if seeds.isEmpty {
            throw CSVImportError.noUsableTransactions
        }

        return MaterializedTransactionSeeds(
            seeds: seeds.sorted { $0.transactionDate < $1.transactionDate },
            skippedRowCount: skippedRowCount
        )
    }

    func dateAwareParser(
        for rows: [[String: String]],
        dateColumn: String
    ) -> TransactionFieldParser {
        let dateSamples = rows.compactMap { $0[dateColumn] }
        let order = TransactionFieldParser.inferDateComponentOrder(fromSamples: dateSamples)
        return TransactionFieldParser(dateComponentOrder: order)
    }

    func previewValidation(
        for draft: TransactionImportDraft,
        mapping: ColumnMappingConfig,
        sampleLimit: Int = 200
    ) -> ImportMappingValidationSummary {
        let parser = dateAwareParser(for: draft.rawRows, dateColumn: mapping.dateColumn)
        let sampleRows = Array(draft.rawRows.prefix(sampleLimit))
        let merchantColumn = mapping.merchantColumn ?? mapping.descriptionColumn ?? ""
        let stats = previewValidationStats(
            for: sampleRows,
            mapping: mapping,
            merchantColumn: merchantColumn,
            parser: parser
        )
        let warnings = draft.warnings + previewValidationWarnings(for: stats)

        return ImportMappingValidationSummary(
            sampleRowCount: sampleRows.count,
            parseableRowCount: stats.parseableRowCount,
            usableMerchantRowCount: stats.usableMerchantRowCount,
            debitRowCount: stats.debitRowCount,
            missingMerchantRowCount: stats.missingMerchantRowCount,
            warnings: warnings
        )
    }

    private func previewValidationStats(
        for sampleRows: [[String: String]],
        mapping: ColumnMappingConfig,
        merchantColumn: String,
        parser: TransactionFieldParser
    ) -> PreviewValidationStats {
        var stats = PreviewValidationStats()

        for row in sampleRows {
            let dateValue = row[mapping.dateColumn] ?? ""
            let amountValue = row[mapping.amountColumn] ?? ""
            let merchantValue = row[merchantColumn] ?? ""

            guard parser.tryParseDate(dateValue) != nil,
                  var amount = parser.tryParseAmount(amountValue) else {
                continue
            }
            stats.parseableRowCount += 1

            guard merchantValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                stats.missingMerchantRowCount += 1
                continue
            }

            stats.usableMerchantRowCount += 1
            if mapping.debitSignConvention == .positive {
                amount *= -1
            }
            if amount < 0 {
                stats.debitRowCount += 1
            }
        }

        return stats
    }

    private func previewValidationWarnings(
        for stats: PreviewValidationStats
    ) -> [String] {
        var warnings: [String] = []

        if stats.parseableRowCount == 0 {
            warnings.append("Current mapping does not produce any parseable transaction rows.")
        }
        if stats.usableMerchantRowCount == 0, stats.parseableRowCount > 0 {
            warnings.append(
                """
                Current mapping leaves every parsed row without a merchant or
                fallback description.
                """
            )
        }
        if stats.debitRowCount == 0, stats.usableMerchantRowCount > 0 {
            warnings.append(
                """
                Current debit sign setting makes every parsed charge non-debit,
                so subscription detection will skip them.
                """
            )
        } else if stats.usableMerchantRowCount > 0,
                  stats.debitRowCount * 4 < stats.usableMerchantRowCount {
            warnings.append(
                """
                Only a small share of parsed rows are debits with the current
                sign setting.
                """
            )
        }

        return warnings
    }
}

private struct PreviewValidationStats {
    var parseableRowCount = 0
    var usableMerchantRowCount = 0
    var debitRowCount = 0
    var missingMerchantRowCount = 0
}
