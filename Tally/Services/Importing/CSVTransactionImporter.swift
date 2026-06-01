import Foundation

struct CSVTransactionImporter {
    private let draftBuilder = TabularTransactionDraftBuilder()
    private let candidateDelimiters: [Character] = [",", ";", "\t", "|"]

    func makeDraft(fileName: String, csvText: String) throws -> TransactionImportDraft {
        let rows = try parse(csvText: csvText)
        guard let headerRow = rows.first, !headerRow.isEmpty else {
            throw CSVImportError.emptyFile
        }

        let headers = headerRow.enumerated().map { index, value in
            var header = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if index == 0 {
                header.removePrefix("\u{FEFF}")
            }
            return header
        }
        let dictionaries = rows.dropFirst().compactMap { row -> [String: String]? in
            guard !row.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                return nil
            }

            var mapped: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < row.count {
                mapped[header] = row[index].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return mapped
        }

        return try draftBuilder.makeDraft(fileName: fileName, headers: headers, rows: dictionaries)
    }

    func materializeTransactions(
        from draft: TransactionImportDraft,
        mapping: ColumnMappingConfig
    ) throws -> [NormalizedTransactionSeed] {
        try draftBuilder.materializeTransactions(from: draft, mapping: mapping)
    }

    private func parse(csvText: String) throws -> [[String]] {
        let normalizedText = normalize(csvText: csvText)
        let rows = candidateDelimiters
            .map { delimiter in
                (delimiter, parse(csvText: normalizedText, delimiter: delimiter))
            }
            .max { lhs, rhs in
                score(rows: lhs.1) < score(rows: rhs.1)
            }?
            .1 ?? []

        if rows.isEmpty {
            throw CSVImportError.emptyFile
        }

        return rows
    }

    private func parse(csvText: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var isInsideQuotes = false
        var index = csvText.startIndex

        while index < csvText.endIndex {
            let character = csvText[index]
            switch character {
            case "\"":
                let nextIndex = csvText.index(after: index)
                if isInsideQuotes, nextIndex < csvText.endIndex, csvText[nextIndex] == "\"" {
                    currentField.append(character)
                    index = nextIndex
                } else {
                    isInsideQuotes.toggle()
                }
            case delimiter where !isInsideQuotes:
                currentRow.append(currentField)
                currentField = ""
            case "\n" where !isInsideQuotes:
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
            default:
                currentField.append(character)
            }

            index = csvText.index(after: index)
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }

    private func normalize(csvText: String) -> String {
        csvText
            .replacingOccurrences(of: "\u{0000}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
    }

    private func score(rows: [[String]]) -> Int {
        guard let headerRow = rows.first else {
            return 0
        }

        let headerWidth = headerRow.count
        guard headerWidth > 0 else {
            return 0
        }

        let nonEmptyRows = rows.filter { row in
            row.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }

        let matchingRows = nonEmptyRows.dropFirst().filter { row in
            let nonEmptyFields = row.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            return !nonEmptyFields.isEmpty && row.count == headerWidth
        }.count

        let rowBonus = min(nonEmptyRows.count, 25)
        return (headerWidth * 10) + (matchingRows * 20) + rowBonus
    }
}

private extension String {
    mutating func removePrefix(_ prefix: String) {
        guard hasPrefix(prefix) else {
            return
        }

        removeFirst(prefix.count)
    }
}

enum CSVImportError: LocalizedError {
    case emptyFile
    case noTransactionRows
    case noUsableTransactions
    case invalidDate(String)
    case invalidAmount(String)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The CSV file is empty."
        case .noTransactionRows:
            return "The CSV file does not contain any transaction rows."
        case .noUsableTransactions:
            return "The current column mapping did not produce any usable transactions."
        case let .invalidDate(value):
            return "Could not parse a date from '\(value)'."
        case let .invalidAmount(value):
            return "Could not parse an amount from '\(value)'."
        }
    }
}
