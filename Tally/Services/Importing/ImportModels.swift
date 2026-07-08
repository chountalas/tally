import Foundation

struct TransactionImportDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let headers: [String]
    let previewRows: [ImportPreviewRow]
    let rawRows: [[String: String]]
    let suggestedMapping: ColumnMappingConfig
    let confidence: Double
    let warnings: [String]

    init(
        id: UUID = UUID(),
        fileName: String,
        headers: [String],
        previewRows: [ImportPreviewRow],
        rawRows: [[String: String]],
        suggestedMapping: ColumnMappingConfig,
        confidence: Double,
        warnings: [String] = []
    ) {
        self.id = id
        self.fileName = fileName
        self.headers = headers
        self.previewRows = previewRows
        self.rawRows = rawRows
        self.suggestedMapping = suggestedMapping
        self.confidence = confidence
        self.warnings = warnings
    }
}

struct ImportPreviewRow: Identifiable, Equatable, Sendable {
    let id: Int
    let values: [String: String]
}

struct ImportMappingValidationSummary: Equatable, Sendable {
    let sampleRowCount: Int
    let parseableRowCount: Int
    let usableMerchantRowCount: Int
    let debitRowCount: Int
    let missingMerchantRowCount: Int
    let warnings: [String]
}

struct MaterializedTransactionSeeds: Equatable, Sendable {
    let seeds: [NormalizedTransactionSeed]
    let skippedRowCount: Int
}

struct NormalizedTransactionSeed: Equatable, Sendable {
    let transactionDate: Date
    let transactionAmount: Decimal
    let merchantRaw: String
    let category: String?
    let accountName: String?
    let memo: String?
    let currency: String?
}

enum PreparedImportOutcome: Sendable {
    case success(TransactionImportDraft)
    case failure(String)
}

enum ImportPreparationService {
    static let maxImportFileSizeBytes: Int64 = 50 * 1024 * 1024

    static func prepareDraft(from url: URL) -> PreparedImportOutcome {
        do {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            try validateImportFileSize(at: url)

            let draft: TransactionImportDraft
            switch url.pathExtension.lowercased() {
            case "csv":
                let data = try Data(contentsOf: url)
                guard let decoded = decodeImportText(from: data) else {
                    throw ImportPreparationError.unreadableContent
                }
                draft = try CSVTransactionImporter().makeDraft(
                    fileName: url.lastPathComponent,
                    csvText: decoded.text,
                    warnings: decoded.warnings
                )
            case "xlsx":
                draft = try XLSXTransactionImporter().makeDraft(
                    fileName: url.lastPathComponent,
                    fileURL: url
                )
            case "xls":
                draft = try XLSBinaryTransactionImporter().makeDraft(
                    fileName: url.lastPathComponent,
                    fileURL: url
                )
            default:
                throw ImportPreparationError.unsupportedFileType(url.pathExtension)
            }

            return .success(draft)
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    private static func validateImportFileSize(at url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        if fileSize > maxImportFileSizeBytes {
            throw ImportPreparationError.fileTooLarge(
                actualBytes: fileSize,
                maxBytes: maxImportFileSizeBytes
            )
        }
    }

    private static func decodeImportText(from data: Data) -> DecodedImportText? {
        let encodings: [String.Encoding] = [
            .utf8,
            .windowsCP1252,
            .macOSRoman,
            .isoLatin1,
            .unicode,
            .utf16LittleEndian,
            .utf16BigEndian
        ]

        var fallback: DecodedImportText?
        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                let decoded = DecodedImportText(
                    text: text,
                    warnings: warnings(for: text, decodedWith: encoding)
                )
                if looksLikeTabularText(text) {
                    return decoded
                }
                fallback = fallback ?? decoded
            }
        }

        return fallback
    }

    private static func warnings(for text: String, decodedWith encoding: String.Encoding) -> [String] {
        guard [.windowsCP1252, .macOSRoman, .isoLatin1].contains(encoding),
              looksSuspiciouslyGarbled(text)
        else {
            return []
        }

        return [
            "The file encoding looked unusual, so some imported text may appear garbled. Review merchant names and memos before importing."
        ]
    }

    private static func looksSuspiciouslyGarbled(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        guard sample.isEmpty == false else {
            return false
        }

        let scalars = Array(sample.unicodeScalars)
        let scalarCount = max(scalars.count, 1)
        let replacementCount = scalars.filter { $0.value == 0xFFFD }.count
        let controlCount = scalars.filter {
            CharacterSet.controlCharacters.contains($0) &&
                $0 != "\n" &&
                $0 != "\r" &&
                $0 != "\t"
        }.count
        let mojibakeMarkers = ["Ã", "Â", "â€", "â€™", "â€œ", "â€�", "â€“", "â€”"]
        let markerCount = mojibakeMarkers.reduce(0) { count, marker in
            count + sample.components(separatedBy: marker).count - 1
        }

        return Double(replacementCount) / Double(scalarCount) > 0.002 ||
            Double(controlCount) / Double(scalarCount) > 0.01 ||
            markerCount >= 1
    }

    private static func looksLikeTabularText(_ text: String) -> Bool {
        let sample = String(text.prefix(20_000))
        guard sample.isEmpty == false else {
            return false
        }

        let normalized = sample
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let nonEmptyLines = normalized
            .split(separator: "\n", omittingEmptySubsequences: true)
            .prefix(10)
        let delimiterCount = sample.reduce(0) { count, character in
            [",", ";", "\t", "|"].contains(character) ? count + 1 : count
        }
        let scalarCount = max(sample.unicodeScalars.count, 1)
        let nulCount = sample.unicodeScalars.filter { $0.value == 0 }.count

        return nonEmptyLines.count >= 2 &&
            delimiterCount > 0 &&
            Double(nulCount) / Double(scalarCount) < 0.01
    }
}

private struct DecodedImportText {
    let text: String
    let warnings: [String]
}

enum TabularHeaderDetector {
    static func headerIndex(in rows: [[String]], scanLimit: Int = 10) -> Int {
        let upperBound = min(scanLimit, rows.count)
        guard upperBound > 0 else {
            return 0
        }

        return (0..<upperBound)
            .map { index in
                (
                    index,
                    headerScore(
                        rows[index],
                        followedBy: Array(rows.dropFirst(index + 1).prefix(5))
                    )
                )
            }
            .filter { $0.1 > 0 }
            .max { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0 > rhs.0
                }
                return lhs.1 < rhs.1
            }?
            .0 ?? 0
    }

    static func warning(skippedRowCount: Int) -> String? {
        guard skippedRowCount > 0 else {
            return nil
        }

        return "Skipped \(skippedRowCount) leading preamble \(skippedRowCount == 1 ? "row" : "rows") before the detected header row."
    }

    private static func headerScore(_ row: [String], followedBy followingRows: [[String]]) -> Double {
        let dateParser = TransactionFieldParser(
            dateComponentOrder: TransactionFieldParser.inferDateComponentOrder(
                fromSamples: followingRows.flatMap { $0 }
            )
        )
        let amountParser = TransactionFieldParser()
        let labels = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard labels.count >= 2 else {
            return 0
        }

        let distinctCount = Set(labels.map { $0.lowercased() }).count
        guard distinctCount >= max(2, Int((Double(labels.count) * 0.75).rounded(.down))) else {
            return 0
        }

        let labelLikeCount = labels.filter { value in
            value.containsLetter &&
                dateParser.tryParseDate(value) == nil &&
                amountParser.tryParseAmount(value) == nil
        }.count
        guard Double(labelLikeCount) / Double(labels.count) >= 0.6 else {
            return 0
        }

        let hasTransactionData = followingRows.contains { row in
            let values = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard values.count >= 2 else {
                return false
            }

            let hasDate = values.contains { dateParser.tryParseDate($0) != nil }
            let hasAmount = values.contains { amountParser.tryParseAmount($0) != nil }
            return hasDate && hasAmount
        }
        guard hasTransactionData else {
            return 0
        }

        let normalizedLabels = labels.map(\.normalizedColumnName)
        let keywordScore = normalizedLabels.reduce(0.0) { score, label in
            score + headerKeywordScore(for: label)
        }

        return Double(labels.count) + keywordScore
    }

    private static func headerKeywordScore(for normalizedLabel: String) -> Double {
        let keywordGroups: [[String]] = [
            ["date", "posted date", "transaction date", "post date", "effective date", "booking date"],
            ["amount", "transaction amount", "net amount", "debit", "credit", "charge", "payment", "withdrawal", "deposit", "total", "value"],
            ["merchant", "vendor", "payee", "counterparty", "seller", "name"],
            ["description", "memo", "details", "statement", "note"],
            ["account", "card", "wallet", "source", "payment method"]
        ]

        return keywordGroups.reduce(0.0) { score, keywords in
            score + (keywords.contains { keyword in
                let normalizedKeyword = keyword.normalizedColumnName
                return normalizedLabel == normalizedKeyword || normalizedLabel.contains(normalizedKeyword)
            } ? 2.0 : 0.0)
        }
    }
}

private enum ImportPreparationError: LocalizedError {
    case unsupportedFileType(String)
    case unreadableContent
    case fileTooLarge(actualBytes: Int64, maxBytes: Int64)

    var errorDescription: String? {
        switch self {
        case let .unsupportedFileType(extensionName):
            return "Supported imports are .csv, .xlsx, and .xls. Received .\(extensionName)."
        case .unreadableContent:
            return "The selected file could not be read as text."
        case let .fileTooLarge(actualBytes, maxBytes):
            return """
            The selected file is too large to import \
            (\(Self.byteCountString(actualBytes))). Split it into files under \(Self.byteCountString(maxBytes)).
            """
        }
    }

    private static func byteCountString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
