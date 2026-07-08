import Foundation

struct TransactionFieldParser {
    enum DateComponentOrder {
        case monthFirst
        case dayFirst
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        return formatter
    }()

    private static let currencySymbols = ["$", "€", "£", "¥", "₹", "₩", "¢"]
    private static let currencyCodes = Set(Locale.commonISOCurrencyCodes.map { $0.uppercased() })

    private let dateComponentOrder: DateComponentOrder
    private let dateFormatters: [(format: String, formatter: DateFormatter)]

    init(dateComponentOrder: DateComponentOrder = .monthFirst, timeZone: TimeZone = .current) {
        self.dateComponentOrder = dateComponentOrder
        self.dateFormatters = Self.dateFormats(order: dateComponentOrder).map { format in
            (format, Self.makeDateFormatter(format: format, timeZone: timeZone))
        }
    }

    private static func makeDateFormatter(format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter
    }

    private static func dateFormats(order: DateComponentOrder) -> [String] {
        var formats = [
            "yyyy-MM-dd",
            "yyyy/MM/dd",
            "yyyy.MM.dd"
        ]
        formats.append(contentsOf: numericDateFormats(order: order))
        formats.append(contentsOf: [
            "MMM d, yyyy",
            "MMMM d, yyyy",
            "MMM d yyyy",
            "d MMM yyyy",
            "d MMMM yyyy"
        ])
        return formats
    }

    private static func numericDateFormats(order: DateComponentOrder) -> [String] {
        // Four-digit years stay before two-digit years, but parseDateCandidate
        // filters these formats by the actual year token length.
        let years = ["yyyy", "yy"]
        let separators = ["/", "-", "."]
        let dayFirstPairs = [("dd", "MM"), ("d", "M"), ("MM", "dd"), ("M", "d")]
        let monthFirstPairs = [("MM", "dd"), ("M", "d"), ("dd", "MM"), ("d", "M")]
        let orderedPairs = order == .dayFirst ? dayFirstPairs : monthFirstPairs

        var formats: [String] = []
        for year in years {
            for separator in separators {
                for (first, second) in orderedPairs {
                    formats.append("\(first)\(separator)\(second)\(separator)\(year)")
                }
            }
        }
        return formats
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

        if let date = parseDateCandidate(trimmed) {
            return date
        }

        // Retry after removing a trailing time component (e.g. "2026-06-07 13:45:00").
        if let dateOnly = Self.strippingTimeSuffix(from: trimmed), dateOnly != trimmed {
            return parseDateCandidate(dateOnly)
        }

        return nil
    }

    private func parseDateCandidate(_ value: String) -> Date? {
        if let isoDate = Self.isoFormatter.date(from: value) {
            return isoDate
        }

        let trailingYearLength = Self.trailingNumericYearLength(in: value)
        for entry in dateFormatters {
            if let trailingYearLength {
                guard entry.format.hasSuffix("yyyy") || entry.format.hasSuffix("yy") else {
                    continue
                }
                if entry.format.hasSuffix("yyyy"), trailingYearLength != 4 {
                    continue
                }
                if !entry.format.hasSuffix("yyyy"),
                   entry.format.hasSuffix("yy"),
                   trailingYearLength != 2 {
                    continue
                }
            }

            let formatter = entry.formatter
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static func trailingNumericYearLength(in value: String) -> Int? {
        let pattern = #"^\d{1,2}([/\-.])\d{1,2}\1(\d{2}|\d{4})$"#
        guard
            let expression = try? NSRegularExpression(pattern: pattern),
            let match = expression.firstMatch(
                in: value,
                range: NSRange(value.startIndex..<value.endIndex, in: value)
            ),
            let range = Range(match.range(at: 2), in: value)
        else {
            return nil
        }
        return value[range].count
    }

    private static func strippingTimeSuffix(from value: String) -> String? {
        let pattern = #"[ T]\d{1,2}:\d{2}(:\d{2})?.*$"#
        guard let range = value.range(of: pattern, options: .regularExpression) else {
            return nil
        }
        let stripped = String(value[..<range.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }

    /// Detects whether a set of sampled date strings are day-first (e.g. dd/MM/yyyy).
    /// A file is treated as day-first as soon as any ambiguous value has a leading
    /// component greater than 12, which cannot be a month.
    static func inferDateComponentOrder(fromSamples values: [String]) -> DateComponentOrder {
        for value in values where firstNumericComponentExceedsTwelve(value) {
            return .dayFirst
        }
        return .monthFirst
    }

    private static func firstNumericComponentExceedsTwelve(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let dateOnly = strippingTimeSuffix(from: trimmed) ?? trimmed
        let separators = CharacterSet(charactersIn: "/-.")
        let components = dateOnly.components(separatedBy: separators)
        guard components.count == 3 else {
            return false
        }
        // A four-digit leading component is an ISO-style year, not an ambiguous day.
        guard components[0].count <= 2, let first = Int(components[0]) else {
            return false
        }
        return first > 12 && first <= 31
    }

    func parseAmount(_ rawValue: String) throws -> Decimal {
        if let parsed = tryParseAmount(rawValue) {
            return parsed
        }
        throw CSVImportError.invalidAmount(rawValue)
    }

    func tryParseAmount(_ rawValue: String) -> Decimal? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let isParentheticalNegative = trimmed.hasPrefix("(") && trimmed.hasSuffix(")")

        var working = Self.strippingCurrency(from: trimmed)
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: " ", with: "")
        guard !working.isEmpty else {
            return nil
        }

        working = Self.normalizeDecimalSeparators(in: working)

        guard working.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }

        guard var decimal = Decimal(string: working) else {
            return nil
        }

        if isParentheticalNegative {
            decimal *= -1
        }

        return decimal
    }

    private static func strippingCurrency(from value: String) -> String {
        var result = value
        for symbol in currencySymbols {
            result = result.replacingOccurrences(of: symbol, with: "")
        }
        result = strippingCurrencyCodes(from: result)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingCurrencyCodes(from value: String) -> String {
        let pattern = #"\b[A-Za-z]{3}\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        let matches = expression.matches(
            in: value,
            range: NSRange(value.startIndex..<value.endIndex, in: value)
        )
        guard matches.isEmpty == false else {
            return value
        }

        var result = ""
        var currentIndex = value.startIndex
        for match in matches {
            guard let range = Range(match.range, in: value) else {
                continue
            }

            result += value[currentIndex..<range.lowerBound]
            let token = String(value[range])
            if currencyCodes.contains(token.uppercased()) == false {
                result += token
            }
            currentIndex = range.upperBound
        }
        result += value[currentIndex...]
        return result
    }

    /// Normalizes thousands and decimal separators to a plain `1234.56` form,
    /// handling European decimal commas (`1.234,56` and `1234,56`).
    private static func normalizeDecimalSeparators(in value: String) -> String {
        let hasComma = value.contains(",")
        let hasDot = value.contains(".")

        if hasComma, hasDot {
            guard let lastComma = value.lastIndex(of: ","),
                  let lastDot = value.lastIndex(of: ".") else {
                return value
            }
            if lastComma > lastDot {
                // Comma is the decimal separator, dots group thousands.
                return value
                    .replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            }
            // Dot is the decimal separator, commas group thousands.
            return value.replacingOccurrences(of: ",", with: "")
        }

        if hasComma {
            let parts = value.components(separatedBy: ",")
            if parts.count == 2, (1...2).contains(parts[1].count) {
                // A comma trailed by one or two digits is a decimal comma.
                return value.replacingOccurrences(of: ",", with: ".")
            }
            // Otherwise the commas group thousands.
            return value.replacingOccurrences(of: ",", with: "")
        }

        if hasDot {
            let parts = value.components(separatedBy: ".")
            if parts.count > 2 || (parts.count == 2 && parts[1].count == 3) {
                // Dots followed by three digits are thousands separators.
                return value.replacingOccurrences(of: ".", with: "")
            }
        }

        return value
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
