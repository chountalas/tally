import CoreXLSX
import Foundation

struct XLSXTransactionImporter {
    private let draftBuilder = TabularTransactionDraftBuilder()

    func makeDraft(fileName: String, fileURL: URL) throws -> TransactionImportDraft {
        guard let file = XLSXFile(filepath: fileURL.path(percentEncoded: false)) else {
            throw XLSXImportError.unreadableWorkbook
        }

        let sharedStrings = try file.parseSharedStrings()
        let workbooks = try file.parseWorkbooks()

        guard let workbook = workbooks.first else {
            throw XLSXImportError.unreadableWorkbook
        }

        let worksheetPaths = try file.parseWorksheetPathsAndNames(workbook: workbook)
        guard let firstWorksheetPath = worksheetPaths.first?.path else {
            throw XLSXImportError.noWorksheets
        }

        let worksheet = try file.parseWorksheet(at: firstWorksheetPath)
        let rows = worksheet.data?.rows ?? []

        let rowValues = rows.map { orderedCellValues(from: $0.cells, sharedStrings: sharedStrings) }
        let headerIndex = TabularHeaderDetector.headerIndex(in: rowValues)
        guard rows.indices.contains(headerIndex) else {
            throw XLSXImportError.noRows
        }

        let headerRow = rows[headerIndex]
        let headerValues = orderedCellValues(from: headerRow.cells, sharedStrings: sharedStrings)
        let headers = headerValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let headerReferences = headerRow.cells.map(\.reference.column)

        let dictionaries: [[String: String]] = rows.dropFirst(headerIndex + 1).map { row in
            let values = alignedCellValues(
                from: row.cells,
                alignedTo: headerReferences,
                sharedStrings: sharedStrings
            )
            var mapped: [String: String] = [:]
            for (index, header) in headers.enumerated() where index < values.count {
                mapped[header] = values[index]
            }
            return mapped
        }

        return try draftBuilder.makeDraft(
            fileName: fileName,
            headers: headers,
            rows: dictionaries,
            warnings: [TabularHeaderDetector.warning(skippedRowCount: headerIndex)].compactMap { $0 }
        )
    }

    func materializeTransactions(
        from draft: TransactionImportDraft,
        mapping: ColumnMappingConfig
    ) throws -> [NormalizedTransactionSeed] {
        try draftBuilder.materializeTransactions(from: draft, mapping: mapping)
    }

    private func orderedCellValues(from cells: [Cell], sharedStrings: SharedStrings?) -> [String] {
        cells
            .sorted { $0.reference.column < $1.reference.column }
            .map { stringValue(for: $0, sharedStrings: sharedStrings) }
    }

    private func alignedCellValues(
        from cells: [Cell],
        alignedTo columns: [ColumnReference],
        sharedStrings: SharedStrings?
    ) -> [String] {
        let valuesByColumn = Dictionary(uniqueKeysWithValues: cells.map { cell in
            (cell.reference.column.value, stringValue(for: cell, sharedStrings: sharedStrings))
        })

        return columns.map { valuesByColumn[$0.value] ?? "" }
    }

    private func stringValue(for cell: Cell, sharedStrings: SharedStrings?) -> String {
        let parser = TransactionFieldParser()

        if let sharedStrings, let stringValue = cell.stringValue(sharedStrings) {
            return stringValue
        }
        if let inlineString = cell.inlineString?.text {
            return inlineString
        }
        if let dateValue = cell.dateValue {
            return dateValue.formatted(date: .numeric, time: .omitted)
        }
        if let rawValue = cell.value,
           let decimal = parser.tryParseAmount(rawValue) {
            return decimal.description
        }
        return cell.value ?? ""
    }
}

enum XLSXImportError: LocalizedError {
    case unreadableWorkbook
    case noWorksheets
    case noRows

    var errorDescription: String? {
        switch self {
        case .unreadableWorkbook:
            return "The Excel workbook could not be opened."
        case .noWorksheets:
            return "The Excel workbook does not contain any worksheets."
        case .noRows:
            return "The Excel worksheet does not contain any rows."
        }
    }
}
