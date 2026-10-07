import Foundation

/// Calendar dates are always calculated from the original anchor, never the
/// previous renewal. A February clamp must not move a March renewal to the 28th.
struct BillingSchedule: Sendable {
    let cadence: SubscriptionCadence
    let anchor: Date
    let anchorDay: Int
    let isMonthEnd: Bool
    let calendar: Calendar

    init(cadence: SubscriptionCadence, dates: [Date], calendar: Calendar = .current) {
        self.cadence = cadence
        self.calendar = calendar
        anchor = calendar.startOfDay(for: dates.min() ?? .now)
        let days = dates.map { calendar.component(.day, from: $0) }
        let counts = Dictionary(grouping: days, by: { $0 }).mapValues(\.count)
        anchorDay = counts.keys.max {
            counts[$0, default: 0] == counts[$1, default: 0]
                ? $0 < $1 : counts[$0, default: 0] < counts[$1, default: 0]
        } ?? calendar.component(.day, from: anchor)
        isMonthEnd = dates.count >= 2 &&
            Double(dates.filter { calendar.isEndOfMonth($0) }.count) / Double(dates.count) >= 0.7
    }

    func date(at cycle: Int) -> Date? {
        guard cadence != .unknown,
              let advanced = cadence.advanced(anchor, by: cycle, using: calendar) else { return nil }
        switch cadence {
        case .monthly, .quarterly, .semiannual, .annual:
            return isMonthEnd ? calendar.endOfMonth(for: advanced)
                : calendar.dateByClamping(day: anchorDay, inMonthOf: advanced)
        case .weekly, .biweekly, .unknown:
            return calendar.startOfDay(for: advanced)
        }
    }

    func cycle(near date: Date) -> Int {
        let months = calendar.dateComponents([.month], from: calendar.dateInterval(of: .month, for: anchor)?.start ?? anchor,
                                             to: calendar.dateInterval(of: .month, for: date)?.start ?? date).month ?? 0
        let days = calendar.dateComponents([.day], from: anchor, to: date).day ?? 0
        let estimate: Int = switch cadence {
        case .monthly, .unknown: months
        case .quarterly: months / 3
        case .semiannual: months / 6
        case .annual: months / 12
        case .weekly: days / 7
        case .biweekly: days / 14
        }
        return ((estimate - 1)...(estimate + 1)).min {
            distance(from: date, toCycle: $0) < distance(from: date, toCycle: $1)
        } ?? estimate
    }

    func distance(from date: Date, toCycle cycle: Int) -> Int {
        guard let expected = self.date(at: cycle) else { return Int.max }
        return abs(calendar.dateComponents([.day], from: expected, to: calendar.startOfDay(for: date)).day ?? 0)
    }

    func next(after date: Date) -> Date? { self.date(at: cycle(near: date) + 1) }

    func dates(from start: Date, through end: Date) -> [Date] {
        guard cadence != .unknown, end >= start else { return [] }
        let lower = max(0, cycle(near: start) - 1)
        let upper = max(lower, cycle(near: end) + 1)
        return (lower...upper).compactMap { date(at: $0) }.filter { $0 >= start && $0 <= end }
    }
}

extension Calendar {
    func isEndOfMonth(_ date: Date) -> Bool {
        component(.day, from: date) == range(of: .day, in: .month, for: date)?.upperBound.advanced(by: -1)
    }

    func endOfMonth(for date: Date) -> Date {
        let components = dateComponents([.year, .month], from: date)
        guard let monthStart = self.date(from: components),
              let nextMonth = self.date(byAdding: .month, value: 1, to: monthStart),
              let end = self.date(byAdding: .day, value: -1, to: nextMonth) else { return date }
        return startOfDay(for: end)
    }

    func dateByClamping(day: Int, inMonthOf date: Date) -> Date {
        var components = dateComponents([.year, .month], from: date)
        let maximumDay = range(of: .day, in: .month, for: date)?.upperBound.advanced(by: -1) ?? day
        components.day = min(day, maximumDay)
        return self.date(from: components).map(startOfDay) ?? date
    }
}
