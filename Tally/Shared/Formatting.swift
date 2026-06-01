import Foundation
import SwiftData

extension Decimal {
    var numberValue: NSDecimalNumber {
        NSDecimalNumber(decimal: self)
    }

    var doubleValue: Double {
        numberValue.doubleValue
    }
}

extension Decimal {
    func currencyString(code: String = "USD") -> String {
        formatted(.currency(code: code))
    }
}

extension Date {
    var shortDateString: String {
        formatted(date: .abbreviated, time: .omitted)
    }

    var relativeDaysString: String {
        let days = Calendar.current.dateComponents([.day], from: .now, to: self).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Tomorrow" }
        if days < 0 { return "\(abs(days))d ago" }
        return "in \(days)d"
    }

    var monthYearString: String {
        formatted(.dateTime.month(.wide).year())
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

extension ModelContext {
    func fetchOrCreateReviewRule(canonicalName: String) throws -> SubscriptionReviewRule {
        let descriptor = FetchDescriptor<SubscriptionReviewRule>(
            predicate: #Predicate { $0.canonicalName == canonicalName }
        )

        if let existing = try fetch(descriptor).first {
            return existing
        }

        let created = SubscriptionReviewRule(canonicalName: canonicalName)
        insert(created)
        return created
    }
}
