import Foundation

struct TransactionImportDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let headers: [String]
    let previewRows: [ImportPreviewRow]
    let rawRows: [[String: String]]
    let suggestedMapping: ColumnMappingConfig
    let confidence: Double

    init(
        id: UUID = UUID(),
        fileName: String,
        headers: [String],
        previewRows: [ImportPreviewRow],
        rawRows: [[String: String]],
        suggestedMapping: ColumnMappingConfig,
        confidence: Double
    ) {
        self.id = id
        self.fileName = fileName
        self.headers = headers
        self.previewRows = previewRows
        self.rawRows = rawRows
        self.suggestedMapping = suggestedMapping
        self.confidence = confidence
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
                guard let text = decodeImportText(from: data) else {
                    throw ImportPreparationError.unreadableContent
                }
                draft = try CSVTransactionImporter().makeDraft(
                    fileName: url.lastPathComponent,
                    csvText: text
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

    private static func decodeImportText(from data: Data) -> String? {
        let encodings: [String.Encoding] = [
            .utf8,
            .unicode,
            .utf16LittleEndian,
            .utf16BigEndian,
            .windowsCP1252,
            .macOSRoman,
            .isoLatin1
        ]

        for encoding in encodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }

        return nil
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
