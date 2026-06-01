import Foundation

struct XLSBinaryTransactionImporter {
    private let csvImporter = CSVTransactionImporter()

    func makeDraft(fileName: String, fileURL: URL) throws -> TransactionImportDraft {
        try fileURL.withUnsafeFileSystemRepresentation { rawPath in
            guard let rawPath else {
                throw XLSBinaryImportError.unreadableWorkbook
            }

            var errorPointer: UnsafeMutablePointer<CChar>?
            guard let csvPointer = TallyCreateCSVFromXLSFile(rawPath, &errorPointer) else {
                defer {
                    if let errorPointer {
                        TallyFreeCString(errorPointer)
                    }
                }

                if let errorPointer {
                    throw XLSBinaryImportError.bridgeError(String(cString: errorPointer))
                }
                throw XLSBinaryImportError.unreadableWorkbook
            }

            defer {
                TallyFreeCString(csvPointer)
                if let errorPointer {
                    TallyFreeCString(errorPointer)
                }
            }

            let csvText = String(cString: csvPointer)
            return try csvImporter.makeDraft(fileName: fileName, csvText: csvText)
        }
    }
}

enum XLSBinaryImportError: LocalizedError {
    case unreadableWorkbook
    case bridgeError(String)

    var errorDescription: String? {
        switch self {
        case .unreadableWorkbook:
            return "The Excel workbook could not be opened."
        case let .bridgeError(message):
            return message
        }
    }
}
