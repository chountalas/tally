import Foundation

extension Decimal {
    var numberValue: NSDecimalNumber {
        NSDecimalNumber(decimal: self)
    }

    var doubleValue: Double {
        numberValue.doubleValue
    }
}

extension Decimal {
    /// Currency-default precision (e.g. JPY 0 digits, USD 2, BHD 3). Distinct from
    /// `tallyMoney`, which forces 2-or-0 digits for design-consistent display.
    func currencyString(code: String = "USD") -> String {
        formatted(.currency(code: code))
    }
}

extension Date {
    var shortDateString: String {
        formatted(date: .abbreviated, time: .omitted)
    }
}

extension Double {
    var percentString: String {
        formatted(.percent.precision(.fractionLength(0)))
    }
}

extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func parsedAsPrice() -> Decimal? {
        let sanitized = trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        return Decimal(string: sanitized)
    }
}
