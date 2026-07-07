import SwiftData
import SwiftUI

/// Calendar — a real month grid showing when each subscription bills next,
/// with month navigation and an agenda list below. Matches the Tally design.
struct CalendarView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Subscription.predictedNextChargeDate) private var subscriptions: [Subscription]

    @State private var monthOffset = 0

    private let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private var calendar: Calendar { .current }

    private var activeSubs: [Subscription] {
        let referenceDate = Date()
        return DashboardMetrics.currentActiveSubscriptions(
            from: subscriptions,
            referenceDate: referenceDate
        )
            .filter {
                DashboardMetrics.currentRenewalDate(for: $0, referenceDate: referenceDate) != nil
            }
    }

    private var viewMonth: Date {
        let startOfThisMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? .now
        return calendar.date(byAdding: .month, value: monthOffset, to: startOfThisMonth) ?? startOfThisMonth
    }

    private var daysInMonth: Int {
        calendar.range(of: .day, in: .month, for: viewMonth)?.count ?? 30
    }

    /// First weekday index (0 = Sunday) of the visible month.
    private var leadingBlanks: Int {
        (calendar.component(.weekday, from: viewMonth) - 1 + 7) % 7
    }

    /// Renewals falling on each day of the visible month, expanded by each
    /// subscription's actual cadence.
    private var byDay: [Int: [Subscription]] {
        var result: [Int: [Subscription]] = [:]
        for sub in activeSubs {
            for date in renewalDates(inVisibleMonthFor: sub) {
                let day = calendar.component(.day, from: date)
                result[day, default: []].append(sub)
            }
        }
        return result
    }

    private var nextMonth: Date {
        calendar.date(byAdding: .month, value: 1, to: viewMonth) ?? viewMonth
    }

    private func renewalDates(inVisibleMonthFor sub: Subscription) -> [Date] {
        guard let currentRenewalDate = DashboardMetrics.currentRenewalDate(for: sub) else { return [] }

        var dates: [Date] = []
        // Always advance from the anchor date so month-end renewals keep their
        // day (Jan 31 → Feb 28 → Mar 31) instead of sticking to the clamp.
        let anchor = calendar.startOfDay(for: currentRenewalDate)
        let visibleStart = calendar.startOfDay(for: viewMonth)
        let visibleEnd = calendar.startOfDay(for: nextMonth)

        var current = anchor
        var period = 0
        while current < visibleEnd && period < 800 {
            if current >= visibleStart {
                dates.append(current)
            }
            period += 1
            guard let next = sub.cadence.tallyAdvanced(anchor, by: period, using: calendar)
                .map(calendar.startOfDay(for:)),
                  next > current else {
                break
            }
            current = next
        }

        return dates
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Colors.textPrimary).kerning(-0.6)
                    Text("When each subscription bills next.")
                        .font(.system(size: 14.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                }

                toolbar
                monthGrid
                agenda
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack {
            Text(viewMonth.formatted(.dateTime.month(.wide).year()))
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
                .contentTransition(.numericText())
            Spacer()
            HStack(spacing: 8) {
                CircleNavButton(systemImage: "chevron.left") { shift(-1) }
                Button("Today") { withAnimation(Theme.Animation.whenAllowed(Theme.Animation.smooth, reduceMotion: reduceMotion)) { monthOffset = 0 } }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .padding(.horizontal, 15).padding(.vertical, 8)
                    .background(Capsule().fill(Theme.Colors.bgCard))
                    .overlay(Capsule().strokeBorder(Theme.Colors.borderStrong, lineWidth: 0.5))
                CircleNavButton(systemImage: "chevron.right") { shift(1) }
            }
        }
    }

    private func shift(_ delta: Int) {
        withAnimation(Theme.Animation.whenAllowed(Theme.Animation.smooth, reduceMotion: reduceMotion)) { monthOffset += delta }
    }

    // MARK: Grid

    private var monthGrid: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(weekdays, id: \.self) { day in
                    Text(day.uppercased())
                        .font(.system(size: 11, weight: .bold)).tracking(0.8)
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(0..<leadingBlanks, id: \.self) { _ in Color.clear.frame(height: 86) }
                ForEach(1...daysInMonth, id: \.self) { day in
                    CalCell(day: day, isToday: isToday(day), events: byDay[day] ?? []) { sub in
                        appModel.tallySelectedSubscriptionID = sub.id
                    }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .cardShadow()
    }

    private func isToday(_ day: Int) -> Bool {
        guard monthOffset == 0 else { return false }
        return calendar.component(.day, from: .now) == day
    }

    // MARK: Agenda

    private var agenda: some View {
        let days = byDay.keys.sorted()
        return Group {
            if days.isEmpty {
                Text("Nothing renews in \(viewMonth.tallyMonthName) — enjoy the break.")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(34)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgInset))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.borderStrong, style: StrokeStyle(lineWidth: 0.5, dash: [4, 3])))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Renewals in \(viewMonth.tallyMonthName)".uppercased())
                        .font(.system(size: 13, weight: .bold)).tracking(1.3)
                        .foregroundStyle(Theme.Colors.textTertiary).padding(.horizontal, 4)
                    VStack(spacing: 0) {
                        let rows = days.flatMap { day in (byDay[day] ?? []).map { (day, $0) } }
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, entry in
                            AgendaRow(day: entry.0, month: viewMonth, sub: entry.1) {
                                appModel.tallySelectedSubscriptionID = entry.1.id
                            }
                            if index < rows.count - 1 { HairlineDivider().padding(.leading, 18) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
                    .cardShadow()
                }
            }
        }
    }
}

// MARK: - Cell

private struct CalCell: View {
    let day: Int
    let isToday: Bool
    let events: [Subscription]
    let onSelect: (Subscription) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("\(day)")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(isToday ? Theme.Colors.accent : Theme.Colors.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events.prefix(3)) { sub in
                    Button { onSelect(sub) } label: {
                        HStack(spacing: 6) {
                            MonogramTile(name: sub.tallyName, size: 20, cornerRadius: 6)
                            Text(sub.tallyName)
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textPrimary)
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if events.count > 3 {
                    Text("+\(events.count - 3) more")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.leading, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 86, alignment: .topLeading)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.Colors.bgInset))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .strokeBorder(isToday ? Theme.Colors.accent : Theme.Colors.border, lineWidth: isToday ? 1 : 0.5)
        )
    }
}

private struct AgendaRow: View {
    let day: Int
    let month: Date
    let sub: Subscription
    let onSelect: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var weekdayLabel: String {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month], from: month)
        comps.day = day
        let date = cal.date(from: comps) ?? month
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 14) {
                VStack(spacing: 3) {
                    Text("\(day)").font(.system(size: 20, weight: .heavy, design: .rounded)).foregroundStyle(Theme.Colors.textPrimary)
                    Text(weekdayLabel.uppercased()).font(.system(size: 10.5, weight: .bold)).tracking(0.5).foregroundStyle(Theme.Colors.textTertiary)
                }
                .frame(width: 42)
                MonogramTile(name: sub.tallyName, size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(sub.tallyName).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                    Text("\(sub.cadence.tallyPlanLabel) plan · \(sub.priceAmount.tallyMoney(code: sub.priceCurrency))")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary).opacity(hovering ? 1 : 0)
            }
            .padding(.vertical, 12).padding(.horizontal, 18)
            .background(hovering ? Theme.Colors.accent.opacity(0.06) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

private struct CircleNavButton: View {
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(hovering ? Theme.Colors.textPrimary : Theme.Colors.textSecondary)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.Colors.bgCard))
                .overlay(Circle().strokeBorder(hovering ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.borderStrong, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}
