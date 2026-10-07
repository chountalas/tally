import Foundation

struct RecurringCharge: Sendable {
    let id: UUID
    let date: Date
    let amount: Decimal
}

struct RecurringHistory: Sendable {
    let transactionIDs: [UUID]
    let schedule: BillingSchedule
    let consistency: Double
}

/// Separates simultaneous plans by their billing calendars. Price is a tie
/// breaker for duplicate payments in a cycle, rather than a plan's identity.
enum RecurringHistoryAnalyzer {
    @concurrent
    static func analyze(_ charges: [RecurringCharge]) async -> [RecurringHistory] {
        histories(in: charges)
    }

    static func histories(in charges: [RecurringCharge], calendar: Calendar = .current) -> [RecurringHistory] {
        var remaining = charges.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }.map { PreparedCharge(charge: $0, calendar: calendar) }
        var histories: [RecurringHistory] = []
        while remaining.count >= 2, !Task.isCancelled {
            var best: Candidate?
            var weeklyCandidates: [String: Candidate] = [:]
            var weeklyPhases = Set<String>()
            var weeklyBestScore = 0.0
            for seed in remaining {
                guard !Task.isCancelled else { return histories }
                let phase = seed.phaseKey(cadence: .weekly)
                guard weeklyPhases.insert(phase).inserted else { continue }
                if let candidate = candidate(from: remaining, seed: seed, cadence: .weekly, calendar: calendar) {
                    weeklyCandidates[phase] = candidate
                    weeklyBestScore = max(weeklyBestScore, candidate.score)
                }
            }
            // Each charge month can propose at most three adjacent cycles.
            // Fit is at most one per selected cycle and continuity at most 0.1.
            let monthScoreBound = Double(min(remaining.count, Set(remaining.map(\.monthStart)).count * 3)) + 0.1
            for cadence in SubscriptionCadence.allCases where cadence != .unknown {
                switch cadence {
                case .monthly, .quarterly, .semiannual, .annual:
                    if monthScoreBound < max(weeklyBestScore, best?.score ?? 0) { continue }
                case .weekly, .biweekly, .unknown:
                    break
                }
                // Retain original cadence and phase order, including strict score ties.
                var phases = Set<String>()
                for seed in remaining {
                    guard !Task.isCancelled else { return histories }
                    let phase = seed.phaseKey(cadence: cadence)
                    guard phases.insert(phase).inserted else { continue }
                    let candidate = cadence == .weekly ? weeklyCandidates[phase]
                        : candidate(from: remaining, seed: seed, cadence: cadence, calendar: calendar)
                    if let candidate, best == nil || candidate.score > (best?.score ?? 0) {
                        best = candidate
                    }
                }
            }
            guard let best else { break }
            histories.append(best.history)
            let used = Set(best.history.transactionIDs)
            remaining.removeAll { used.contains($0.charge.id) }
        }
        return histories
    }

    private struct PreparedCharge {
        let charge: RecurringCharge
        let dayStart: Date
        let monthStart: Date
        let day: Int
        let month: Int
        let isMonthEnd: Bool
        let epochDays: Int

        init(charge: RecurringCharge, calendar: Calendar) {
            self.charge = charge
            dayStart = calendar.startOfDay(for: charge.date)
            monthStart = calendar.dateInterval(of: .month, for: charge.date)?.start ?? charge.date
            day = calendar.component(.day, from: charge.date)
            month = calendar.component(.month, from: charge.date)
            isMonthEnd = calendar.isEndOfMonth(charge.date)
            epochDays = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: charge.date).day ?? 0
        }

        func phaseKey(cadence: SubscriptionCadence) -> String {
            switch cadence {
            case .weekly, .biweekly:
                return String(epochDays % (cadence == .weekly ? 7 : 14))
            case .annual, .semiannual, .quarterly:
                return "\(month):\(day)"
            case .monthly, .unknown:
                return isMonthEnd ? "end" : String(day)
            }
        }
    }

    private static func candidate(
        from charges: [PreparedCharge], seed: PreparedCharge, cadence: SubscriptionCadence, calendar: Calendar
    ) -> Candidate? {
        let seedDates = seed.isMonthEnd
            ? [seed.charge.date, calendar.endOfMonth(for: calendar.date(byAdding: .month, value: 1, to: seed.charge.date) ?? seed.charge.date)]
            : [seed.charge.date]
        let schedule = BillingSchedule(cadence: cadence, dates: seedDates, calendar: calendar)
        let tolerance: Int = switch cadence {
        case .annual: 14
        case .quarterly, .semiannual: 7
        case .monthly: 3
        case .biweekly: 2
        case .weekly: 1
        case .unknown: 0
        }
        let byCycle = selectCharges(charges, seed: seed, schedule: schedule, tolerance: tolerance)
        let cycles = byCycle.keys.sorted()
        guard cycles.count >= 2 else { return nil }
        let directIntervals = zip(cycles, cycles.dropFirst()).filter { $1 - $0 == 1 }.count
        guard directIntervals > 0 else { return nil }
        let purity = Double(cycles.count) / Double(charges.count)
        guard cycles.count >= 3 || purity >= 0.8 else { return nil }
        let selected = cycles.compactMap { byCycle[$0] }
        let fit = selected.map {
            1 - Double($0.distance) / Double(tolerance + 1)
        }.reduce(0, +)
        let continuity = Double(directIntervals) / Double(cycles.count - 1)
        guard continuity >= 0.75 || purity >= 0.8 else { return nil }
        return Candidate(
            history: RecurringHistory(
                transactionIDs: selected.map(\.charge.id),
                schedule: BillingSchedule(cadence: cadence, dates: selected.map(\.charge.date), calendar: calendar),
                consistency: fit / Double(cycles.count)
            ),
            score: fit + continuity * 0.1
        )
    }

    private struct SelectedCharge {
        let charge: RecurringCharge
        let distance: Int
    }

    private struct CandidateDates {
        let schedule: BillingSchedule
        let anchorMonth: Date
        var expectedDates: [Int: Date] = [:]
        var missingDates = Set<Int>()

        init(schedule: BillingSchedule) {
            self.schedule = schedule
            anchorMonth = schedule.calendar.dateInterval(of: .month, for: schedule.anchor)?.start ?? schedule.anchor
        }

        mutating func nearestCycle(to charge: PreparedCharge) -> (cycle: Int, distance: Int) {
            let calendar = schedule.calendar
            let estimate: Int
            switch schedule.cadence {
            case .weekly, .biweekly:
                let days = calendar.dateComponents([.day], from: schedule.anchor, to: charge.charge.date).day ?? 0
                estimate = days / (schedule.cadence == .weekly ? 7 : 14)
            case .monthly, .quarterly, .semiannual, .annual, .unknown:
                let months = calendar.dateComponents([.month], from: anchorMonth, to: charge.monthStart).month ?? 0
                let divisor = switch schedule.cadence {
                case .annual: 12
                case .semiannual: 6
                case .quarterly: 3
                default: 1
                }
                estimate = months / divisor
            }
            var best = (cycle: estimate - 1, distance: distance(from: charge, to: estimate - 1))
            for cycle in estimate...(estimate + 1) {
                let distance = distance(from: charge, to: cycle)
                if distance < best.distance { best = (cycle, distance) }
            }
            return best
        }

        mutating func distance(from charge: PreparedCharge, to cycle: Int) -> Int {
            if expectedDates[cycle] == nil && !missingDates.contains(cycle) {
                if let date = schedule.date(at: cycle) {
                    expectedDates[cycle] = date
                } else {
                    missingDates.insert(cycle)
                }
            }
            guard let expected = expectedDates[cycle] else { return Int.max }
            return abs(schedule.calendar.dateComponents([.day], from: expected, to: charge.dayStart).day ?? 0)
        }
    }

    private static func selectCharges(
        _ charges: [PreparedCharge], seed: PreparedCharge, schedule: BillingSchedule, tolerance: Int
    ) -> [Int: SelectedCharge] {
        var byCycle: [Int: SelectedCharge] = [:]
        var dates = CandidateDates(schedule: schedule)
        for prepared in charges {
            let charge = prepared.charge
            let (cycle, distance) = dates.nearestCycle(to: prepared)
            guard cycle >= 0, distance <= tolerance else { continue }
            if let existing = byCycle[cycle] {
                let existingPriceDelta = abs(existing.charge.amount - seed.charge.amount)
                let priceDelta = abs(charge.amount - seed.charge.amount)
                guard distance < existing.distance || (distance == existing.distance && priceDelta < existingPriceDelta) else {
                    continue
                }
            }
            byCycle[cycle] = SelectedCharge(charge: charge, distance: distance)
        }
        return byCycle
    }

    private struct Candidate {
        let history: RecurringHistory
        let score: Double
    }
}
