import Foundation

struct TransactionFieldParser {
    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private static let dateFormats = [
        "yyyy-MM-dd",
        "M/d/yyyy",
        "MM/dd/yyyy",
        "d/M/yyyy",
        "MMM d, yyyy",
        "MMMM d, yyyy"
    ]

    private static func makeDateFormatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    private static func dateFormatters(timeZone: TimeZone) -> [DateFormatter] {
        dateFormats.map { makeDateFormatter(format: $0, timeZone: timeZone) }
    }

    func parseDate(_ rawValue: String) throws -> Date {
        if let parsed = tryParseDate(rawValue) {
            return parsed
        }
        throw CSVImportError.invalidDate(rawValue)
    }

    func tryParseDate(_ rawValue: String) -> Date? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let isoDate = Self.isoFormatter.date(from: trimmed) {
            return isoDate
        }

        for formatter in Self.dateFormatters(timeZone: .current) {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    func parseAmount(_ rawValue: String) throws -> Decimal {
        if let parsed = tryParseAmount(rawValue) {
            return parsed
        }
        throw CSVImportError.invalidAmount(rawValue)
    }

    func tryParseAmount(_ rawValue: String) -> Decimal? {
        let trimmed = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")

        let isParentheticalNegative = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")
        let sanitized = trimmed
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "+", with: "")

        guard sanitized.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }

        guard var decimal = Decimal(string: sanitized) else {
            return nil
        }

        if isParentheticalNegative {
            decimal *= -1
        }

        return decimal
    }
}

extension String {
    var normalizedColumnName: String {
        unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }
            .joined()
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    var containsLetter: Bool {
        rangeOfCharacter(from: .letters) != nil
    }
}
