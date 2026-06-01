import SwiftData
import SwiftUI

/// Insights — a few things worth knowing, all derived from imported statements:
/// service overlap, price increases, spend by category, and big annual charges.
struct InsightsView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]
    @Query(sort: \NormalizedTransaction.transactionDate, order: .forward) private var transactions: [NormalizedTransaction]

    private var metrics: DashboardMetrics {
        appModel.dashboardMetricsSnapshot(subscriptions: subscriptions, transactions: transactions).metrics
    }
    private var active: [Subscription] { subscriptions.filter { $0.status == .active } }

    private var categories: [(name: String, value: Decimal)] {
        let grouped = Dictionary(grouping: active) { $0.tallyCategory }
        return grouped
            .map { (name: $0.key, value: $0.value.reduce(Decimal(0)) { $0 + $1.normalizedMonthlyAmount }) }
            .sorted { $0.value > $1.value }
    }

    private var annuals: [Subscription] {
        active.filter(\.tallyIsYearly).sorted { ($0.tallyDaysUntilRenewal ?? .max) < ($1.tallyDaysUntilRenewal ?? .max) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.gap) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Insights")
                        .font(.system(size: 32, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Colors.textPrimary).kerning(-0.6)
                    Text("A few things worth knowing — all from your own statements.")
                        .font(.system(size: 14.5, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
                .padding(.bottom, 2)

                if let overlap = metrics.overlapGroups.first {
                    overlapCard(overlap)
                }
                if !metrics.priceChangedSubscriptions.isEmpty {
                    priceChangeCard(metrics.priceChangedSubscriptions)
                }
                if !categories.isEmpty {
                    categoryCard
                }
                if !annuals.isEmpty {
                    annualCard
                }
                if metrics.overlapGroups.isEmpty, metrics.priceChangedSubscriptions.isEmpty, categories.isEmpty {
                    emptyState
                }
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: Cards

    private func overlapCard(_ overlap: OverlapGroup) -> some View {
        InsightCard(icon: "square.3.layers.3d", title: "You're paying for \(overlap.subscriptions.count) \(overlap.category.lowercased()) services") {
            (Text("That's ").foregroundStyle(Theme.Colors.textSecondary)
             + Text("\(overlap.monthlyExposure.tallyMoney()) a month").foregroundStyle(Theme.Colors.textPrimary).bold()
             + Text(" — about \(monthlyToYearly(overlap.monthlyExposure)) a year. Keeping one or two could save the rest.").foregroundStyle(Theme.Colors.textSecondary))
                .font(.system(size: 13.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        } rows: {
            ForEach(overlap.subscriptions) { sub in
                Button { appModel.tallySelectedSubscriptionID = sub.id } label: {
                    HStack(spacing: 12) {
                        MonogramTile(name: sub.tallyName, size: 34)
                        Text(sub.tallyName).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                        Spacer()
                        Text("\(sub.tallyMonthly.tallyMoney(code: sub.priceCurrency))/mo")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.Colors.textSecondary)
                    }
                    .padding(.vertical, 11)
                    .overlay(alignment: .top) { HairlineDivider() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func priceChangeCard(_ items: [Subscription]) -> some View {
        InsightCard(icon: "arrow.up.right", title: "\(items.count) \(items.count == 1 ? "price" : "prices") went up") {
            Text("We compared your recent charges to older ones. These cost more than they used to.")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } rows: {
            ForEach(items) { sub in priceRow(sub) }
        }
    }

    private func priceRow(_ sub: Subscription) -> some View {
        let pct = sub.priceChangePercent ?? 0
        let was = sub.priceAmount * Decimal(1.0 / (1.0 + pct))
        let delta = sub.priceAmount - was
        return Button { appModel.tallySelectedSubscriptionID = sub.id } label: {
            HStack(spacing: 12) {
                MonogramTile(name: sub.tallyName, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(sub.tallyName).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                    Text("Was \(was.tallyMoney(code: sub.priceCurrency)) · now \(sub.priceAmount.tallyMoney(code: sub.priceCurrency))")
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                }
                Spacer()
                Text("+\(delta.tallyMoney(code: sub.priceCurrency))")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Colors.warning)
            }
            .padding(.vertical, 12)
            .overlay(alignment: .top) { HairlineDivider() }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var categoryCard: some View {
        let maxValue = max(Decimal(1), categories.map(\.value).max() ?? 1)
        return InsightCard(icon: "rectangle.stack", title: "Where your money goes") {
            (Text("Your ").foregroundStyle(Theme.Colors.textSecondary)
             + Text(metrics.monthlyRunRate.tallyMoney()).foregroundStyle(Theme.Colors.textPrimary).bold()
             + Text(" a month, by type of service.").foregroundStyle(Theme.Colors.textSecondary))
                .font(.system(size: 13.5, weight: .medium))
        } rows: {
            ForEach(categories, id: \.name) { cat in
                HStack(spacing: 14) {
                    Text(cat.name).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                        .frame(width: 110, alignment: .leading)
                    CategoryFill(fraction: (cat.value / maxValue).doubleValue)
                    Text(cat.value.tallyMoney()).font(.system(size: 13.5, weight: .bold, design: .rounded)).foregroundStyle(Theme.Colors.textPrimary)
                        .frame(minWidth: 56, alignment: .trailing)
                }
                .padding(.vertical, 8)
            }
        }
    }

    private var annualCard: some View {
        InsightCard(icon: "calendar", title: "Big once-a-year charges") {
            Text("These bill in one lump sum, so they're easy to forget. Here's when they're next due.")
                .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } rows: {
            ForEach(annuals) { sub in
                Button { appModel.tallySelectedSubscriptionID = sub.id } label: {
                    HStack(spacing: 12) {
                        MonogramTile(name: sub.tallyName, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sub.tallyName).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(Theme.Colors.textPrimary)
                            if let d = sub.predictedNextChargeDate {
                                Text("Renews \(d.tallyShortDate) · \(d.tallyRelativeDay)")
                                    .font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                            }
                        }
                        Spacer()
                        Text(sub.priceAmount.tallyMoney(code: sub.priceCurrency, showCents: false))
                            .font(.system(size: 15, weight: .heavy, design: .rounded)).foregroundStyle(Theme.Colors.textPrimary)
                    }
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { HairlineDivider() }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "sparkles").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.Colors.accent)
            Text("Insights appear as you import statements")
                .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgInset))
    }

    private func monthlyToYearly(_ monthly: Decimal) -> String {
        (monthly * 12).tallyMoney(showCents: false)
    }
}

// MARK: - Insight card shell

private struct InsightCard<Sub: View, Rows: View>: View {
    let icon: String
    let title: String
    @ViewBuilder var subtitle: () -> Sub
    @ViewBuilder var rows: () -> Rows

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Theme.Colors.accentSoft)
                    .frame(width: 34, height: 34)
                    .overlay(Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.Colors.accent))
                Text(title).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.bottom, 4)
            subtitle()
                .padding(.bottom, 12)
            rows()
        }
        .featureCard(padding: Theme.Spacing.cardPad)
    }
}

private struct CategoryFill: View {
    let fraction: Double
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Colors.bgInset)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.Colors.accent2, Theme.Colors.accent], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * (grown || reduceMotion ? max(0.02, min(1, fraction)) : 0))
            }
        }
        .frame(height: 12)
        .onAppear {
            guard !reduceMotion else { grown = true; return }
            withAnimation(Theme.Animation.progressSmooth) { grown = true }
        }
    }
}
