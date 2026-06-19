import SwiftData
import SwiftUI

/// Subscriptions — the full list. "You're paying for these" (active, soonest
/// first) and "No longer charging" (former), with quick filters and a running
/// monthly total. Matches the Tally design.
struct SubscriptionsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]
    @Query(sort: \NormalizedTransaction.transactionDate, order: .forward) private var transactions: [NormalizedTransaction]

    /// Set when the user drills into the review queue from a specific import
    /// (Imports → "Review items"); scopes the review list to that import.
    @State private var scopedImportRecordID: UUID?

    private var active: [Subscription] {
        let referenceDate = Date()
        return DashboardMetrics.currentActiveSubscriptions(
            from: subscriptions,
            referenceDate: referenceDate
        )
            .sorted {
                (DashboardMetrics.currentRenewalDate(for: $0, referenceDate: referenceDate) ?? .distantFuture) <
                    (DashboardMetrics.currentRenewalDate(for: $1, referenceDate: referenceDate) ?? .distantFuture)
            }
    }
    private var former: [Subscription] {
        let activeIDs = Set(active.map(\.id))
        return subscriptions.filter {
            $0.status == .former || ($0.status == .active && activeIDs.contains($0.id) == false)
        }
    }
    /// AI-detected charges awaiting a keep/skip decision (the review queue),
    /// scoped to a single import when the user drilled in from the Imports screen.
    private var review: [Subscription] {
        let scopedIDs = importScopedSubscriptionIDs
        return subscriptions
            .filter { $0.libraryState == .suggested && (scopedIDs?.contains($0.id) ?? true) }
            .sorted { $0.confidenceScore > $1.confidenceScore }
    }

    /// Subscription IDs charged within the import the user drilled in from
    /// (Imports → "Review items"). `nil` means no import scope is active, so the
    /// full review queue shows.
    private var importScopedSubscriptionIDs: Set<UUID>? {
        guard let scopedImportRecordID else { return nil }
        return Set(transactions.compactMap { txn in
            txn.importRecordID == scopedImportRecordID ? txn.subscriptionID : nil
        })
    }

    private var monthlyTotal: Decimal {
        appModel.dashboardMetricsSnapshot(subscriptions: subscriptions, transactions: transactions).metrics.monthlyRunRate
    }

    private var filter: SubsFilter { appModel.selectedSubscriptionFilter }

    private var counts: [SubsFilter: Int] {
        [
            .review: review.count,
            .all: active.count + former.count,
            .active: active.count,
            .ended: former.count,
            .yearly: active.filter(\.tallyIsYearly).count
        ]
    }

    /// The review chip only appears when there's something to review, and leads.
    private var visibleFilters: [SubsFilter] {
        var result: [SubsFilter] = []
        if !review.isEmpty { result.append(.review) }
        result += [.all, .active, .ended, .yearly]
        return result
    }

    private var groups: [(head: String?, items: [Subscription])] {
        switch filter {
        case .all:
            return [("You're paying for these", active), ("No longer charging", former)]
        case .active:
            return [(nil, active)]
        case .ended:
            return [(nil, former)]
        case .yearly:
            return [(nil, active.filter(\.tallyIsYearly))]
        case .review:
            return [(nil, review)]
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, 18)

                filterRow
                    .padding(.bottom, 8)

                if filter == .review {
                    reviewSection
                } else {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        if !group.items.isEmpty {
                            if let head = group.head {
                                Text(head.uppercased())
                                    .font(.system(size: 13, weight: .bold))
                                    .tracking(1.3)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 24)
                                    .padding(.bottom, 8)
                            } else {
                                Spacer().frame(height: 14)
                            }
                            listCard(group.items)
                        }
                    }

                    totalCard
                        .padding(.top, 14)
                }
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .task(id: appModel.navigationToken) {
            if let request = appModel.consumePendingSubscriptionLibraryNavigation() {
                // Honor the import the request came from: nil (e.g. from the
                // dashboard) shows the full review queue; a record id scopes it.
                scopedImportRecordID = request.importRecordID
                switch request.state {
                case .suggested, .ignored: appModel.selectedSubscriptionFilter = .review
                case .inactive: appModel.selectedSubscriptionFilter = .ended
                case .confirmed, .manual: appModel.selectedSubscriptionFilter = .active
                }
            }
        }
    }

    // MARK: Review queue

    @ViewBuilder
    private var reviewSection: some View {
        if review.isEmpty {
            VStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "checkmark.seal").font(.system(size: 30, weight: .light)).foregroundStyle(Theme.Colors.positive)
                Text("All caught up").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                Text("Nothing to review right now. New charges show up here after you import a statement.")
                    .font(.system(size: 13.5, weight: .medium)).foregroundStyle(Theme.Colors.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 44)
            .padding(.top, 14)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Text("Keep the ones you recognize. Skip anything that isn't really a subscription.")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.horizontal, 4)
                    .padding(.top, 16)
                    .padding(.bottom, 10)
                reviewCard(review)
            }
        }
    }

    private func reviewCard(_ items: [Subscription]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, sub in
                ReviewRow(
                    sub: sub,
                    onOpen: { appModel.tallySelectedSubscriptionID = sub.id },
                    onKeep: { appModel.confirmSuggestedSubscription(sub.id, in: modelContext) },
                    onSkip: { appModel.ignoreSuggestedSubscription(sub.id, in: modelContext) }
                )
                if index < items.count - 1 {
                    HairlineDivider()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardShadow()
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom) {
                headerCopy
                Spacer(minLength: Theme.Spacing.lg)
                addOrUpdateButton
            }

            VStack(alignment: .leading, spacing: 14) {
                headerCopy
                addOrUpdateButton
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Your subscriptions")
                .font(.system(size: 34, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
                .kerning(-0.7)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            (Text("\(active.count) active · ").foregroundStyle(Theme.Colors.textSecondary)
             + Text(monthlyTotal.tallyMoney()).foregroundStyle(Theme.Colors.textPrimary).bold()
             + Text(" a month").foregroundStyle(Theme.Colors.textSecondary))
                .font(.system(size: 14.5, weight: .medium))
        }
    }

    private var addOrUpdateButton: some View {
        SolidAccentButton(title: "Add or update", systemImage: "plus") {
            appModel.addOrEditSheet = .chooser
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var filterRow: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(visibleFilters) { f in
                    TallyChip(label: f.label, count: counts[f], isSelected: filter == f) {
                        withAnimation(Theme.Animation.whenAllowed(Theme.Animation.quickSmooth, reduceMotion: reduceMotion)) {
                            appModel.selectedSubscriptionFilter = f
                            // Manually choosing a filter clears any import scope,
                            // so the user can always get back to the full queue.
                            scopedImportRecordID = nil
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    private func listCard(_ items: [Subscription]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, sub in
                SubRow(sub: sub) { appModel.tallySelectedSubscriptionID = sub.id }
                if index < items.count - 1 {
                    HairlineDivider()
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardShadow()
    }

    private var totalCard: some View {
        HStack {
            Text("Active subscriptions, every month")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Colors.textSecondary)
            Spacer()
            Text(monthlyTotal.tallyMoney())
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .cardShadow()
    }
}

enum SubsFilter: String, CaseIterable, Identifiable {
    case all, active, ended, yearly, review
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .active: "Active"
        case .ended: "Ended"
        case .yearly: "Yearly"
        case .review: "To review"
        }
    }
}

// MARK: - Row

private struct SubRow: View {
    let sub: Subscription
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isCurrentActive: Bool {
        DashboardMetrics.currentActiveSubscriptions(from: [sub]).contains { $0.id == sub.id }
    }
    private var displaysAsEnded: Bool {
        sub.status == .former || (sub.status == .active && isCurrentActive == false)
    }
    private var renewalDate: Date? {
        DashboardMetrics.currentRenewalDate(for: sub)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                MonogramTile(name: sub.tallyName, size: 42)
                    .rotationEffect(.degrees(hovering && !reduceMotion ? -3 : 0))
                    .scaleEffect(hovering && !reduceMotion ? 1.07 : 1)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 9) {
                        Text(sub.tallyName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        badges
                    }
                    Text(metaLine)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Theme.Spacing.md)

                VStack(alignment: .trailing, spacing: 1) {
                    Text(sub.tallyMonthly.tallyMoney(code: sub.priceCurrency))
                        .font(.system(size: 17, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(sub.cadence == .monthly || sub.cadence == .unknown ? "per month" : "per month avg")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textTertiary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -6)
            }
            .padding(.vertical, Theme.Spacing.rowV)
            .padding(.horizontal, 18)
            .background(hovering ? Theme.Colors.accent.opacity(0.06) : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(Theme.Colors.accent).frame(width: 3)
                    .scaleEffect(y: hovering ? 1 : 0, anchor: .center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }

    @ViewBuilder
    private var badges: some View {
        if isCurrentActive,
           let date = renewalDate,
           date.tallyDaysFromNow >= 0,
           date.tallyDaysFromNow <= 7 {
            TallyBadge(text: "renews \(date.tallyRelativeDay)", kind: .soon)
        }
        if displaysAsEnded {
            TallyBadge(text: "ended", kind: .ended)
        }
        if sub.tallyPriceWentUp {
            TallyBadge(text: "price went up", kind: .priceUp)
        }
        if sub.tallyIsYearly {
            TallyBadge(text: "yearly", kind: .yearly)
        }
    }

    private var metaLine: String {
        if displaysAsEnded {
            if let last = sub.lastChargeDate {
                return "Last charged in \(last.tallyMonthName)"
            }
            return "No longer charging"
        }
        var line = "\(sub.priceAmount.tallyMoney(code: sub.priceCurrency)) \(sub.cadence.tallyBillingPhrase)"
        if let date = renewalDate {
            line += " · renews \(date.tallyShortDate)"
        }
        return line
    }
}

// MARK: - Review row

/// A row in the review queue: detected charge with explicit Keep / Skip actions.
private struct ReviewRow: View {
    let sub: Subscription
    let onOpen: () -> Void
    let onKeep: () -> Void
    let onSkip: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 14) {
            Button(action: onOpen) {
                HStack(spacing: 14) {
                    MonogramTile(name: sub.tallyName, size: 42)
                        .scaleEffect(hovering && !reduceMotion ? 1.05 : 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sub.tallyName)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(metaLine)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: Theme.Spacing.md)

            HStack(spacing: 8) {
                Button(action: onSkip) {
                    Text("Not mine")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Theme.Colors.bgInset))
                        .overlay(Capsule().strokeBorder(Theme.Colors.border, lineWidth: 0.5))
                }
                .buttonStyle(.plain)

                Button(action: onKeep) {
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                        Text("Keep").font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(Theme.Colors.onAccent)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.Colors.accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, Theme.Spacing.rowV)
        .padding(.horizontal, 18)
        .background(hovering ? Theme.Colors.accent.opacity(0.04) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }

    private var metaLine: String {
        var line = "\(sub.priceAmount.tallyMoney(code: sub.priceCurrency)) \(sub.cadence.tallyBillingPhrase)"
        if let category = sub.serviceCategory?.nilIfBlank {
            line += " · \(category)"
        }
        return line
    }
}
