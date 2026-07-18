import SwiftData
import SwiftUI

private struct ChargeRowData: Identifiable, Equatable {
    let id: String
    let label: String
    let amount: Decimal
    let currency: String?
    let isOld: Bool
}

struct SubscriptionDetailView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    let subscription: Subscription

    @State private var isConfirmingRemoval = false
    @State private var isConfirmingCancellation = false
    @State private var displayedChargeRows: [ChargeRowData] = []
    @State private var chargeRowsAreProjected = false
    @State private var chargeLoadErrorMessage: String?

    init(subscription: Subscription) {
        self.subscription = subscription
    }

    private var sub: Subscription { subscription }
    private var isCurrentActive: Bool {
        DashboardMetrics.currentActiveSubscriptions(from: [sub]).contains { $0.id == sub.id }
    }
    private var displayStatus: SubscriptionStatus {
        sub.status == .active && isCurrentActive == false ? .former : sub.status
    }
    private var currentRenewalDate: Date? {
        DashboardMetrics.currentRenewalDate(for: sub)
    }
    private var isActive: Bool { displayStatus == .active }
    private var isNeedsReview: Bool { displayStatus == .needsReview }
    /// A suggested (needs-review) item is still an ongoing detected charge, so it
    /// shares the active layout for next-charge / tenure / renews. Stale active
    /// records render as ended until the next rebuild persists that status.
    private var isOngoing: Bool { displayStatus != .former }
    private var isManualRecord: Bool {
        sub.creationPath == .manual || sub.libraryState == .manual
    }
    private var removalMessage: String {
        if isManualRecord {
            return "This deletes it from your list. You can't undo this."
        }

        return "This deletes it from your list and stops Tally from detecting \(sub.tallyName) in future imports. You can't undo this."
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                backLink
                hero.padding(.bottom, 22)
                headlineCard.padding(.bottom, 14)
                if sub.tallyPriceWentUp { priceCallout.padding(.bottom, 14) }
                factGrid.padding(.bottom, 22)
                SectionHead(chargeRowsAreProjected ? "Projected charges" : "Recent charges")
                    .padding(.bottom, chargeRowsAreProjected ? 6 : 14)
                if chargeRowsAreProjected {
                    Text("No imported charges are linked yet, so this is a cadence-based estimate.")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textTertiary)
                        .padding(.bottom, 14)
                }
                if let chargeLoadErrorMessage {
                    Text(chargeLoadErrorMessage)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .padding(.vertical, 8)
                } else {
                    chargeList
                }
                actions.padding(.top, 22)
            }
            .padding(Theme.Spacing.page)
            .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .scrollIndicators(.hidden)
        .task(id: chargeRefreshID) {
            do {
                let loadedCharges = try loadDisplayedCharges()
                displayedChargeRows = loadedCharges.rows
                chargeRowsAreProjected = loadedCharges.isProjected
                chargeLoadErrorMessage = nil
            } catch {
                displayedChargeRows = []
                chargeRowsAreProjected = false
                chargeLoadErrorMessage = "Tally couldn't load this subscription's charges."
            }
        }
        .confirmationDialog(
            "Mark \(sub.tallyName) as cancelled?",
            isPresented: $isConfirmingCancellation,
            titleVisibility: .visible
        ) {
            Button("Mark as cancelled", role: .destructive) {
                cancelSubscription()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This moves it to Ended, clears renewal reminders, and removes synced calendar events. Imported transactions stay in your history.")
        }
        .confirmationDialog(
            "Remove \(sub.tallyName) from your list?",
            isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                do {
                    try appModel.removeSubscription(id: sub.id, in: modelContext)
                    appModel.tallySelectedSubscriptionID = nil
                } catch {
                    appModel.importErrorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removalMessage)
        }
    }

    // MARK: Back

    private var backLink: some View {
        Button {
            appModel.tallySelectedSubscriptionID = nil
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.left").font(.system(size: 14, weight: .semibold))
                Text("Back").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(Theme.Colors.textSecondary)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 22)
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 18) {
            MonogramTile(name: sub.tallyName, size: 64, cornerRadius: 18)
            VStack(alignment: .leading, spacing: 6) {
                Text(sub.tallyName)
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .kerning(-0.6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 10) {
                    statusPill
                    Text(sub.tallyCategory)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var statusPill: some View {
        let label: String
        let fg: Color
        let bg: Color
        switch displayStatus {
        case .active:
            label = "Active"; fg = Theme.Colors.positive; bg = Theme.Colors.positive.opacity(0.16)
        case .needsReview:
            label = "Needs review"; fg = Theme.Colors.accent; bg = Theme.Colors.accentSoft
        case .former:
            label = "No longer charging"; fg = Theme.Colors.textSecondary; bg = Theme.Colors.textPrimary.opacity(0.09)
        }
        return Text(label)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(fg)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .background(Capsule().fill(bg))
    }

    // MARK: Headline

    private var headlineCard: some View {
        HStack(alignment: .bottom, spacing: 26) {
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(sub.priceAmount.tallyMoney(code: sub.priceCurrency))
                    .font(.system(size: 50, weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .kerning(-1)
                Text(" / \(sub.cadence.tallyBillingUnit)")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)

            if isOngoing, let next = currentRenewalDate {
                detailFact(label: "Next charge") {
                    (Text("\(next.tallyShortDate) · ").foregroundStyle(Theme.Colors.textPrimary)
                     + Text(next.tallyRelativeDay).foregroundStyle(Theme.Colors.accent).bold())
                        .font(.system(size: 18, weight: .semibold))
                }
            }
            if let tenure = displayTenureMonths {
                detailFact(label: isOngoing ? "With you for" : "You kept it for") {
                    Text(tallyTenureLabel(months: tenure))
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .cardShadow()
    }

    private func detailFact<V: View>(label: String, @ViewBuilder value: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.Colors.textTertiary)
            value()
        }
        .padding(.bottom, 4)
    }

    private var displayTenureMonths: Int? {
        if let tenure = sub.tenureMonths, tenure > 0 { return tenure }
        guard let start = sub.firstChargeDate else { return nil }
        let end = isOngoing ? Date.now : (sub.lastChargeDate ?? Date.now)
        let components = Calendar.current.dateComponents([.month], from: start, to: end)
        return max(0, components.month ?? 0)
    }

    // MARK: Price callout

    private var priceCallout: some View {
        let pct = sub.priceChangePercent ?? 0
        let factor = 1.0 / (1.0 + pct)
        let wasRaw = sub.priceAmount * Decimal(factor)
        let moreAYear = (sub.normalizedMonthlyAmount - sub.normalizedMonthlyAmount * Decimal(factor)) * 12
        return HStack(spacing: 14) {
            Circle().fill(Theme.Colors.bgCard).frame(width: 38, height: 38)
                .overlay(Image(systemName: "arrow.up").font(.system(size: 18, weight: .bold)).foregroundStyle(Theme.Colors.warning))
            VStack(alignment: .leading, spacing: 1) {
                Text("The price went up")
                    .font(.system(size: 14.5, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                (Text("You used to pay \(wasRaw.tallyMoney(code: sub.priceCurrency)) — that's ")
                 + Text("\(moreAYear.tallyMoney(code: sub.priceCurrency, showCents: false)) more a year").bold())
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.warning.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.warning.opacity(0.32), lineWidth: 0.5))
    }

    // MARK: Facts

    private var factGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: .infinity), spacing: 10)], spacing: 10) {
            factTile("Billing", sub.cadence.tallyBillingSummary)
            if isOngoing {
                factTile("Renews on", currentRenewalDate?.tallyShortDate ?? "—")
            } else {
                factTile("Last charged", sub.lastChargeDate?.tallyMonthName ?? "—")
            }
            factTile("Category", sub.tallyCategory)
            factTile("Started", sub.firstChargeDate?.tallyMonthYear ?? "—")
        }
    }

    private func factTile(_ key: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.Colors.textTertiary)
            Text(value).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).fill(Theme.Colors.bgInset))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
    }

    // MARK: Recent charges

    private var chargeList: some View {
        let charges = displayedChargeRows.isEmpty ? recentCharges() : displayedChargeRows
        return VStack(spacing: 0) {
            ForEach(Array(charges.enumerated()), id: \.element.id) { index, charge in
                HStack {
                    Text(charge.label)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                    Spacer()
                    Text(charge.amount.tallyMoney(code: charge.currency ?? sub.priceCurrency))
                        .font(.system(size: 14.5, weight: .bold, design: .rounded))
                        .foregroundStyle(charge.isOld ? Theme.Colors.textTertiary : Theme.Colors.textPrimary)
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 13)
                if index < charges.count - 1 { HairlineDivider().padding(.leading, 18) }
            }
        }
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Theme.Colors.bgCard))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).strokeBorder(Theme.Colors.border, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous))
        .cardShadow()
    }

    private var chargeRefreshID: String {
        "\(sub.id.uuidString)-\(appModel.libraryRevision.generation)"
    }

    /// Prefer the subscription's actual imported charges; only synthesize a
    /// cadence-based history when there are no linked transactions at all.
    private func loadDisplayedCharges() throws -> (rows: [ChargeRowData], isProjected: Bool) {
        let actual = try loadActualCharges()
        return actual.isEmpty ? (recentCharges(), true) : (actual, false)
    }

    /// Real `NormalizedTransaction` rows for this subscription, most-recent first,
    /// shown with their own dates / amounts / currencies.
    private func loadActualCharges(count: Int = 6) throws -> [ChargeRowData] {
        try linkedTransactions().prefix(count).map { transaction in
            let label = transaction.transactionDate.formatted(.dateTime.month(.abbreviated).day().year())
            let amount = abs(transaction.transactionAmount)
            return ChargeRowData(
                id: transaction.id.uuidString,
                label: label,
                amount: amount,
                currency: transaction.currency,
                isOld: false
            )
        }
    }

    /// Transactions linked to this subscription, most-recent first. Falls back to a
    /// canonical-name match (mirrors `AppModel.fetchLinkedTransactions`) so charges
    /// still surface for items linked by merchant rather than id.
    private func linkedTransactions() throws -> [NormalizedTransaction] {
        let subscriptionID = sub.id
        let linkedDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { $0.subscriptionID == subscriptionID },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        let linked = try modelContext.fetch(linkedDescriptor)
        if linked.isEmpty == false {
            return linked
        }
        let canonicalName = sub.canonicalName
        let canonicalDescriptor = FetchDescriptor<NormalizedTransaction>(
            predicate: #Predicate { $0.merchantNormalized == canonicalName },
            sortBy: [SortDescriptor(\.transactionDate, order: .reverse)]
        )
        return try modelContext.fetch(canonicalDescriptor)
    }

    private func recentCharges(count: Int = 6) -> [ChargeRowData] {
        let cal = Calendar.current
        let anchor: Date = isOngoing
            ? (sub.cadence.advanced(currentRenewalDate ?? .now, by: -1, using: cal) ?? .now)
            : (sub.lastChargeDate ?? .now)
        let pct = sub.priceChangePercent ?? 0
        let oldAmount = pct > 0 ? sub.priceAmount * Decimal(1.0 / (1.0 + pct)) : sub.priceAmount
        return (0..<count).map { i in
            let date = sub.cadence.advanced(anchor, by: -i, using: cal) ?? anchor
            let isOld = pct > 0.05 && i >= 3
            let label = date.formatted(.dateTime.month(.abbreviated).day().year())
            return ChargeRowData(
                id: "synthetic-\(i)-\(date.timeIntervalSinceReferenceDate)",
                label: label,
                amount: isOld ? oldAmount : sub.priceAmount,
                currency: nil,
                isOld: isOld
            )
        }
    }

    // MARK: Actions

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 10) {
                actionButtons
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        Group {
            if isNeedsReview {
                TallyActionButton(title: "Keep", systemImage: "checkmark", kind: .primary) {
                    appModel.confirmSuggestedSubscription(sub.id, in: modelContext)
                    appModel.tallySelectedSubscriptionID = nil
                }
                TallyActionButton(title: "Edit details", systemImage: "pencil", kind: .normal) {
                    appModel.addOrEditSheet = .edit(sub.id)
                }
                TallyActionButton(title: "Not a subscription", systemImage: "xmark.circle", kind: .normal) {
                    appModel.ignoreSuggestedSubscription(sub.id, in: modelContext)
                    appModel.tallySelectedSubscriptionID = nil
                }
                TallyActionButton(title: "Not mine", systemImage: "person.crop.circle.badge.xmark", kind: .danger) {
                    appModel.hideSuggestedSubscription(sub.id, in: modelContext)
                    appModel.tallySelectedSubscriptionID = nil
                }
            } else {
                if isActive {
                    TallyActionButton(title: "Remind me before it renews", systemImage: "bell", kind: .primary) {
                        scheduleRenewalReminder()
                    }
                }
                TallyActionButton(title: "Edit details", systemImage: "pencil", kind: .normal) {
                    appModel.addOrEditSheet = .edit(sub.id)
                }
                if isActive {
                    TallyActionButton(title: "Mark as cancelled", systemImage: "trash", kind: .danger) {
                        isConfirmingCancellation = true
                    }
                } else {
                    TallyActionButton(title: "Remove from list", systemImage: "trash", kind: .danger) {
                        isConfirmingRemoval = true
                    }
                }
            }
        }
    }

    private func cancelSubscription() {
        do {
            try appModel.cancelSubscription(id: sub.id, in: modelContext)
            appModel.tallySelectedSubscriptionID = nil
        } catch {
            appModel.importErrorMessage = error.localizedDescription
        }
    }

    /// Schedule the renewal notification (requesting authorization first),
    /// keeping each subscription's saved reminder lead time. The service
    /// updates `lastNotificationScheduledAt` and saves the context itself.
    private func scheduleRenewalReminder() {
        let context = modelContext
        let name = sub.tallyName
        Task { @MainActor in
            do {
                try context.save()
                let service = RenewalNotificationService()
                let granted = try await service.requestAccess()
                guard granted else {
                    appModel.importErrorMessage =
                        "Tally can't set a reminder without notification permission. " +
                        "Turn on notifications for Tally in System Settings, then try again."
                    return
                }
                let all = try context.fetch(FetchDescriptor<Subscription>())
                _ = try await service.schedule(subscriptions: all, context: context)
                appModel.infoMessage = "You'll get a reminder before \(name) renews."
            } catch {
                appModel.importErrorMessage =
                    "Tally couldn't schedule the reminder. \(error.localizedDescription)"
            }
        }
    }
}
