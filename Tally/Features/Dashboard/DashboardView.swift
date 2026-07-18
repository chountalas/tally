import SwiftData
import SwiftUI

struct DashboardView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]
    @Query(
        filter: #Predicate<NormalizedTransaction> { transaction in
            transaction.subscriptionID != nil
        },
        sort: \NormalizedTransaction.transactionDate,
        order: .forward
    )
    private var subscriptionTransactions: [NormalizedTransaction]

    private var snapshot: DashboardContentSnapshot {
        appModel.dashboardContentSnapshot(
            subscriptions: subscriptions,
            transactions: subscriptionTransactions
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.gap) {
                let content = snapshot
                let metrics = content.metrics
                let upcoming = Array(content.upcomingRenewals.prefix(5))
                let overlap = metrics.overlapGroups.first
                let history = Array(metrics.monthlySpend.sorted { $0.month < $1.month }.suffix(6))
                let reviewCount = content.reviewQueueTotalCount

                heroSection(
                    metrics: metrics,
                    upcoming: upcoming,
                    overlap: overlap,
                    referenceDate: content.referenceDay
                )

                if reviewCount > 0 {
                    ReviewNudge(count: reviewCount) {
                        appModel.openSubscriptionLibrary(state: .suggested)
                    }
                }

                if !upcoming.isEmpty {
                    comingUpSection(upcoming, referenceDate: content.referenceDay)
                }
                if !history.isEmpty {
                    SpendChart(history: history)
                }
                if let overlap {
                    OverlapNudge(group: overlap) { appModel.selectedTab = .audit }
                }
                updatedLine
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Hero

    private func heroSection(
        metrics: DashboardMetrics,
        upcoming: [Subscription],
        overlap: OverlapGroup?,
        referenceDate: Date
    ) -> some View {
        let heroContext = DashboardHeroContext(metrics: metrics)
        let monthly = metrics.monthlyRunRate
        let yearly = metrics.annualizedSpend
        return VStack(alignment: .leading, spacing: 0) {
            Text(greeting)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
                .padding(.bottom, 8)

            (Text("You're spending about ")
                .foregroundStyle(Theme.Colors.textSecondary)
             + Text("\(monthly.tallyMoney(showCents: false)) a month")
                .foregroundStyle(Theme.Colors.textPrimary).bold()
             + Text(" across \(heroContext.activeSubscriptionCount) subscriptions.")
                .foregroundStyle(Theme.Colors.textSecondary))
                .font(.system(size: 25, weight: .semibold))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)

            HeroAmount(value: monthly.doubleValue, animate: !reduceMotion)
                .padding(.top, 6)
                .padding(.bottom, 4)

            (Text("That's ").foregroundStyle(Theme.Colors.textSecondary)
             + Text(yearly.tallyMoney(showCents: false)).foregroundStyle(Theme.Colors.textPrimary).bold()
             + Text(" a year.").foregroundStyle(Theme.Colors.textSecondary))
                .font(.system(size: 15, weight: .medium))

            heroStats(
                metrics: metrics,
                upcoming: upcoming,
                overlap: overlap,
                referenceDate: referenceDate
            )
                .padding(.top, 20)
        }
    }

    private func heroStats(
        metrics: DashboardMetrics,
        upcoming: [Subscription],
        overlap: OverlapGroup?,
        referenceDate: Date
    ) -> some View {
        HStack(spacing: 10) {
            if let next = upcoming.first {
                let renewalDate = DashboardMetrics.currentRenewalDate(
                    for: next,
                    referenceDate: referenceDate
                )
                StatTile(icon: "calendar", label: "Next renewal") {
                    (Text(next.tallyName)
                     + statUnit(renewalDate.map { " · \($0.tallyRelativeDay)" } ?? ""))
                        .modifier(StatValueText())
                }
            }
            StatTile(icon: "rectangle.stack", label: "Yearly cost") {
                Text(metrics.annualizedSpend.tallyMoney(showCents: false)).modifier(StatValueText())
            }
            if let overlap {
                Button {
                    appModel.selectedTab = .audit
                } label: {
                    StatTile(icon: "lightbulb", label: "Worth a look") {
                        (Text("\(overlap.subscriptions.count) \(overlap.category.lowercased())")
                         + statUnit(" · review overlap"))
                            .modifier(StatValueText())
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let part = hour < 12 ? "morning" : (hour < 18 ? "afternoon" : "evening")
        return "Good \(part) 👋"
    }

    // MARK: Coming up

    private func comingUpSection(_ upcoming: [Subscription], referenceDate: Date) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHead("Coming up next") {
                LinkButton(title: "See all") { appModel.selectedTab = .subscriptions }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: .infinity), spacing: 12)], spacing: 12) {
                ForEach(upcoming) { sub in
                    RenewalCard(sub: sub, referenceDate: referenceDate) {
                        appModel.tallySelectedSubscriptionID = sub.id
                    }
                }
            }
        }
    }

    // MARK: Updated line

    private var updatedLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.clockwise").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
            Group {
                if let updated = lastUpdatedLabel {
                    Text("Your list was last updated ").foregroundStyle(Theme.Colors.textTertiary)
                    + Text(updated).foregroundStyle(Theme.Colors.textSecondary).bold()
                    + Text(".").foregroundStyle(Theme.Colors.textTertiary)
                } else {
                    Text("Keep your list fresh as new charges land.").foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .font(.system(size: 13, weight: .medium))
            Spacer(minLength: Theme.Spacing.md)
            LinkButton(title: "Add or update") { appModel.addOrEditSheet = .chooser }
        }
        .padding(.top, Theme.Spacing.md)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.Colors.border).frame(height: 0.5)
        }
    }

    private var lastUpdatedLabel: String? {
        let latest = subscriptions.map { $0.createdAt }.max()
        guard let latest else { return nil }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: latest), to: Calendar.current.startOfDay(for: .now)).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days) days ago"
    }
}

struct DashboardHeroContext: Equatable {
    let activeSubscriptionCount: Int

    init(metrics: DashboardMetrics) {
        activeSubscriptionCount = metrics.activeCount
    }
}

// MARK: - Hero amount (count-up)

private struct HeroAmount: View {
    let value: Double
    let animate: Bool
    private let duration: Double = 1.1
    @State private var start: Date = .now
    @State private var finished = false

    var body: some View {
        Group {
            if animate && !finished {
                TimelineView(.animation) { ctx in
                    let t = min(max(ctx.date.timeIntervalSince(start), 0) / duration, 1)
                    let eased = 1 - pow(1 - t, 3)
                    numberView(value * eased)
                }
            } else {
                numberView(value)
            }
        }
        .task {
            guard animate else { finished = true; return }
            start = .now
            try? await Task.sleep(for: .seconds(duration + 0.05))
            finished = true
        }
    }

    private func numberView(_ shown: Double) -> some View {
        let dollars = Int(shown)
        let cents = Int((shown - Double(dollars)) * 100 + 0.5)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text("$\(dollars.formatted(.number.grouping(.automatic)))")
                .font(.system(size: 78, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(String(format: ".%02d", min(99, max(0, cents))))
                .font(.system(size: 33, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textSecondary)
                .baselineOffset(30)
            Text("per month")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.Colors.textTertiary)
                .padding(.leading, 2)
        }
        .kerning(-1)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

private struct StatValueText: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 26, weight: .heavy, design: .rounded))
            .foregroundStyle(Theme.Colors.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.55)
    }
}

/// Small muted suffix inside a stat value (the design's `.stat .v small`).
/// Applied per-Text-run so it keeps its size/color when concatenated under StatValueText.
private func statUnit(_ string: String) -> Text {
    Text(string)
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(Theme.Colors.textSecondary)
}

// MARK: - Stat tile

private struct StatTile<Value: View>: View {
    let icon: String
    let label: String
    @ViewBuilder var value: () -> Value

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.accent)
                Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.Colors.textTertiary)
            }
            value()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .cardShadow()
        .hoverLift()
    }
}

// MARK: - Renewal card

private struct RenewalCard: View {
    let sub: Subscription
    let referenceDate: Date
    let action: () -> Void
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var renewalDate: Date? {
        DashboardMetrics.currentRenewalDate(for: sub, referenceDate: referenceDate)
    }
    private var days: Int { renewalDate?.tallyDaysFromNow ?? 30 }
    private var soon: Bool { days <= 7 }
    private var fraction: CGFloat { CGFloat(max(0.06, min(1, 1 - Double(days) / 30))) }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    MonogramTile(name: sub.tallyName, size: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(sub.tallyName).font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary).lineLimit(1)
                        Text(renewLabel)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(soon ? Theme.Colors.accent : Theme.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.bottom, 14)
                Text(sub.priceAmount.tallyMoney(code: sub.priceCurrency))
                    .font(.system(size: 22, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geo in
                    Rectangle().fill(Theme.Colors.accent)
                        .frame(width: geo.size.width * (grown || reduceMotion ? fraction : 0), height: 3)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
            .cardShadow()
        }
        .buttonStyle(.plain)
        .hoverLift()
        .onAppear {
            guard !reduceMotion else { grown = true; return }
            withAnimation(Theme.Animation.progressSmooth) { grown = true }
        }
    }

    private var renewLabel: String {
        guard let date = renewalDate else { return "renews soon" }
        return "\(date.tallyRelativeDay) · \(date.tallyShortDate)"
    }
}

// MARK: - Spend chart

private struct SpendChart: View {
    let history: [MonthlySpendPoint]

    private var maxValue: Double {
        max(1, history.map { $0.totalSpend.doubleValue }.max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((history.last?.totalSpend ?? 0).tallyMoney(showCents: false))
                        .font(.system(size: 26, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text("Spent this month · last 6 months")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.accent)
                    Text(trendLabel).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            HStack(alignment: .bottom, spacing: 14) {
                ForEach(Array(history.enumerated()), id: \.element.id) { index, point in
                    VStack(spacing: 9) {
                        GrowingBar(
                            fraction: CGFloat(point.totalSpend.doubleValue / maxValue),
                            isHighlighted: index == history.count - 1,
                            delay: Double(index) * 0.06
                        )
                        .frame(maxWidth: 46)
                        Text(point.month.formatted(.dateTime.month(.abbreviated)))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 132)
        }
        .featureCard(padding: Theme.Spacing.cardPad)
    }

    private var trendLabel: String {
        guard history.count >= 2 else { return "steady" }
        let last = history[history.count - 1].totalSpend.doubleValue
        let prev = history[history.count - 2].totalSpend.doubleValue
        if prev == 0 { return "steady" }
        let change = (last - prev) / prev
        if change > 0.05 { return "trending up" }
        if change < -0.05 { return "trending down" }
        return "steady"
    }
}

// MARK: - Review nudge

/// Post-import call to action: the app detected charges that need a quick decision.
/// Tapping opens the Subscriptions screen filtered to the review queue.
private struct ReviewNudge: View {
    let count: Int
    let onReview: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(Theme.Colors.accent).frame(width: 42, height: 42)
                .overlay(Image(systemName: "checklist").font(.system(size: 19, weight: .semibold)).foregroundStyle(Theme.Colors.onAccent))
                .cardShadow()
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) \(count == 1 ? "charge" : "charges") to review")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                Text("We spotted \(count == 1 ? "a possible subscription" : "possible subscriptions") in your statements. Keep real subscriptions, dismiss yours-but-not-recurring charges, or mark wrong-account charges as not mine.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.md)
            SolidAccentButton(title: "Review now", action: onReview)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.accent.opacity(0.3), lineWidth: 0.5))
    }
}

// MARK: - Overlap nudge

private struct OverlapNudge: View {
    let group: OverlapGroup
    let onSeeInsights: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Circle().fill(Theme.Colors.bgCard).frame(width: 42, height: 42)
                .overlay(Image(systemName: "lightbulb").font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.Colors.accent))
                .cardShadow()
            VStack(alignment: .leading, spacing: 2) {
                Text("You're paying for \(group.subscriptions.count) \(group.category.lowercased()) services")
                    .font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                (Text("That's ").foregroundStyle(Theme.Colors.textSecondary)
                 + Text("\(group.monthlyExposure.tallyMoney(showCents: false)) a month").foregroundStyle(Theme.Colors.textPrimary).bold()
                 + Text(" on \(group.category.lowercased()) alone. Worth a quick look?").foregroundStyle(Theme.Colors.textSecondary))
                    .font(.system(size: 13.5, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.md)
            SolidAccentButton(title: "See insights", action: onSeeInsights)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.accentSoft))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.accent.opacity(0.3), lineWidth: 0.5))
    }
}
