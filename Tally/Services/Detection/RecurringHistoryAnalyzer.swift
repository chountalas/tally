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

    static func histories(in charges: [RecurringCharge]) -> [RecurringHistory] {
        var remaining = charges.sorted {
            $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date < $1.date
        }
        var histories: [RecurringHistory] = []
        while remaining.count >= 2, !Task.isCancelled {
            var best: Candidate?
            for cadence in SubscriptionCadence.allCases where cadence != .unknown {
                // Each seed proposes a billing phase; multiple charges on the
                // same phase do not require repeating an identical hypothesis.
                var phases = Set<String>()
                for seed in remaining {
                    guard !Task.isCancelled else { return histories }
                    let calendar = Calendar.current
                    let phase = phaseKey(seed.date, cadence: cadence, calendar: calendar)
                    guard phases.insert(phase).inserted else { continue }
                    let candidate = candidate(from: remaining, seed: seed, cadence: cadence)
                    if let candidate, best == nil || candidate.score > (best?.score ?? 0) {
                        best = candidate
                    }
                }
            }
            guard let best else { break }
            histories.append(best.history)
            let used = Set(best.history.transactionIDs)
            remaining.removeAll { used.contains($0.id) }
        }
        return histories
    }

    private static func phaseKey(_ date: Date, cadence: SubscriptionCadence, calendar: Calendar) -> String {
        switch cadence {
        case .weekly, .biweekly:
            let days = calendar.dateComponents([.day], from: Date(timeIntervalSince1970: 0), to: date).day ?? 0
            return String(days % (cadence == .weekly ? 7 : 14))
        case .annual, .semiannual, .quarterly:
            return "\(calendar.component(.month, from: date)):\(calendar.component(.day, from: date))"
        case .monthly, .unknown:
            return calendar.isEndOfMonth(date) ? "end" : String(calendar.component(.day, from: date))
        }
    }

    private static func candidate(
        from charges: [RecurringCharge], seed: RecurringCharge, cadence: SubscriptionCadence
    ) -> Candidate? {
        let calendar = Calendar.current
        // Include a second synthetic month-end to retain that anchor even when
        // the first observed month ends on the 30th or in February.
        let seedDates = calendar.isEndOfMonth(seed.date)
            ? [seed.date, calendar.endOfMonth(for: calendar.date(byAdding: .month, value: 1, to: seed.date) ?? seed.date)]
            : [seed.date]
        let schedule = BillingSchedule(cadence: cadence, dates: seedDates)
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
        let fit = zip(cycles, selected).map { cycle, charge in
            1 - Double(schedule.distance(from: charge.date, toCycle: cycle)) / Double(tolerance + 1)
        }.reduce(0, +)
        let continuity = Double(directIntervals) / Double(cycles.count - 1)
        guard continuity >= 0.75 || purity >= 0.8 else { return nil }
        return Candidate(
            history: RecurringHistory(
                transactionIDs: selected.map(\.id),
                schedule: BillingSchedule(cadence: cadence, dates: selected.map(\.date)),
                consistency: fit / Double(cycles.count)
            ),
            score: fit + continuity * 0.1
        )
    }

    private static func selectCharges(
        _ charges: [RecurringCharge], seed: RecurringCharge, schedule: BillingSchedule, tolerance: Int
    ) -> [Int: RecurringCharge] {
        var byCycle: [Int: RecurringCharge] = [:]
        for charge in charges {
            let cycle = schedule.cycle(near: charge.date)
            guard cycle >= 0, schedule.distance(from: charge.date, toCycle: cycle) <= tolerance else { continue }
            if let existing = byCycle[cycle] {
                let existingDistance = schedule.distance(from: existing.date, toCycle: cycle)
                let distance = schedule.distance(from: charge.date, toCycle: cycle)
                let existingPriceDelta = abs(existing.amount - seed.amount)
                let priceDelta = abs(charge.amount - seed.amount)
                guard distance < existingDistance || (distance == existingDistance && priceDelta < existingPriceDelta) else {
                    continue
                }
            }
            byCycle[cycle] = charge
        }
        return byCycle
    }

    private struct Candidate {
        let history: RecurringHistory
        let score: Double
    }
}
