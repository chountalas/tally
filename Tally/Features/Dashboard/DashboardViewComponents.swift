import Charts
import SwiftData
import SwiftUI

struct DashboardHeader: View {
    let activeCount: Int
    let reviewCount: Int
    let reviewAutomationPlan: ReviewAutomationPlan
    @Binding var showingAddSheet: Bool
    @Binding var isPresentingImporter: Bool
    let isPreparingImport: Bool
    let isRefreshingAnalysis: Bool
    let onRefreshAnalysis: () -> Void
    let onOpenCopilot: () -> Void

    var body: some View {
        EditorialPageHeader(
            eyebrow: "Private recurring spend",
            title: "Your subscriptions",
            subtitle: headerSummary
        ) {
            HStack(spacing: Theme.Spacing.lg) {
                EditorialActionButton(
                    title: isRefreshingAnalysis ? "Refreshing" : "Refresh",
                    systemImage: "arrow.clockwise",
                    isDisabled: isPreparingImport || isRefreshingAnalysis,
                    action: onRefreshAnalysis
                )

                EditorialActionButton(
                    title: "Import",
                    systemImage: "tray.and.arrow.down",
                    isDisabled: isPreparingImport || isRefreshingAnalysis
                ) {
                    isPresentingImporter = true
                }

                EditorialActionButton(
                    title: "Copilot",
                    systemImage: "sparkle.magnifyingglass",
                    tone: .primary,
                    isDisabled: isRefreshingAnalysis,
                    action: onOpenCopilot
                )

                EditorialActionButton(
                    title: "Add",
                    systemImage: "plus",
                    tone: .primary
                ) {
                    showingAddSheet = true
                }
            }
        }
    }

    private var headerSummary: String {
        guard reviewCount > 0 else {
            return "\(activeCount) services tracked. Nothing needs your attention right now."
        }

        if reviewAutomationPlan.automatableCandidates.isEmpty == false {
            return "\(activeCount) services tracked. \(reviewAutomationPlan.automatableCount) obvious calls are ready; \(reviewAutomationPlan.manualCountAfterAutomation) need your eye."
        }

        return "\(activeCount) services tracked. \(reviewCount) items need a quick look."
    }
}

struct DashboardHeroSummary: View {
    let metrics: DashboardMetrics

    var body: some View {
        ViewThatFits(in: .horizontal) {
            heroSpread
            compactHeroSpread
        }
    }

    private var heroSpread: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.section) {
            heroValueBlock
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .leading)

            heroDetailColumn
                .frame(width: 320, alignment: .leading)
                .padding(.top, Theme.Spacing.xxl)
        }
        .padding(.horizontal, Theme.Spacing.section)
        .padding(.vertical, Theme.Spacing.breathe)
        .background {
            EmberHaloBackground()
        }
    }

    private var compactHeroSpread: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
            heroValueBlock
            heroDetailColumn
        }
        .padding(Theme.Spacing.xxl)
        .background {
            EmberHaloBackground()
        }
    }

    private var heroValueBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.sm) {
                EmberPulseDot(color: Theme.Colors.accent, size: 6)
                Text("MONTHLY OUTFLOW")
                    .font(Theme.Typography.stamp)
                    .tracking(3.2)
                    .foregroundStyle(Theme.Colors.accent)

                Rectangle()
                    .fill(Theme.Colors.border.opacity(0.6))
                    .frame(width: 36, height: 0.5)

                Text(Date.now.formatted(.dateTime.month(.wide).day().year()))
                    .font(Theme.Typography.stamp)
                    .tracking(1.8)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }

            EmberAuraText(
                text: metrics.monthlyRunRate.currencyString(),
                font: Theme.Typography.masthead
            )

            Text("Expected to leave your account this month — across every active service.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 480, alignment: .leading)

            if let monthlyChange = metrics.monthlyChange {
                HStack(spacing: Theme.Spacing.sm) {
                    Image(systemName: monthlyChange.isPositive ? "arrow.down.right" : "arrow.up.right")
                        .font(.system(size: 11, weight: .bold))
                    Text(changeNarrative(for: monthlyChange))
                        .font(Theme.Typography.footnote)
                }
                .foregroundStyle(monthlyChange.isPositive ? Theme.Colors.positive : Theme.Colors.warning)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.xs + 2)
                .background(
                    Capsule(style: .continuous)
                        .fill((monthlyChange.isPositive ? Theme.Colors.positive : Theme.Colors.warning).opacity(0.12))
                )
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            (monthlyChange.isPositive ? Theme.Colors.positive : Theme.Colors.warning).opacity(0.35),
                            lineWidth: 0.5
                        )
                }
                .padding(.top, Theme.Spacing.xs)
            }
        }
    }

    private var heroDetailColumn: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            DashboardSummaryLine(
                symbol: "calendar",
                label: "Year view",
                value: metrics.annualizedSpend.currencyString(),
                tone: .quietBlue
            )

            DashboardSummaryLine(
                symbol: "scalemass",
                label: "Typical service",
                value: metrics.averagePerSubscription.currencyString(),
                tone: .moss
            )

            DashboardSummaryLine(
                symbol: metrics.needsReviewCount == 0 ? "checkmark" : "hand.raised",
                label: "Needs your call",
                value: metrics.needsReviewCount == 0 ? "All clear" : "\(metrics.needsReviewCount) items",
                tone: metrics.needsReviewCount == 0 ? .moss : .rose
            )

            if let annualChange = metrics.annualChange {
                DashboardSummaryLine(
                    symbol: annualChange.isPositive ? "arrow.down.right" : "arrow.up.right",
                    label: "Versus last year",
                    value: annualChange.label,
                    tone: annualChange.isPositive ? .moss : .clay
                )
            }
        }
    }

    private func changeNarrative(for change: MetricChange) -> String {
        if change.isPositive {
            return "Down \(change.label) from the prior month."
        }
        return "Up \(change.label) from the prior month."
    }
}

struct DashboardCopilotSection: View {
    @Binding var promptText: String
    let onAsk: () -> Void

    private let promptSuggestions = [
        "What renews in the next 30 days?",
        "Where can I save this month?",
        "Which merchants should I clean up?"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Copilot")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text("Ask a plain question before you keep, skip, or trim.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)

            TextEditor(text: $promptText)
                .font(Theme.Typography.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 88)
                .padding(Theme.Spacing.sm)
                .background(Theme.Colors.bg, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                        .stroke(Theme.Colors.border, lineWidth: 0.5)
                }

            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(promptSuggestions, id: \.self) { suggestion in
                    Button {
                        promptText = suggestion
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text(suggestion)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack {
                Text("No changes happen without your approval.")
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.textTertiary)

                Spacer()

                DashboardTextAction(
                    title: "Ask copilot",
                    tone: .accent,
                    isDisabled: promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: onAsk
                )
            }
        }
        .featureCard()
    }
}

struct ReviewQueueSection: View {
    let subscriptions: [Subscription]
    let previews: [UUID: MerchantLearningPreview]
    let plan: ReviewAutomationPlan
    let isApplyingAutomation: Bool
    let processingSubscriptionID: UUID?
    let onConfirm: (Subscription) -> Void
    let onReject: (Subscription) -> Void
    let onOpenDetails: (Subscription) -> Void
    let onApplySafeConfirmations: () -> Void
    let onOpenReviewInbox: () -> Void

    var body: some View {
        let lastSubscriptionID = subscriptions.last?.id

        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text("Decision inbox")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)

                    Text(reviewNarrative)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }

                Spacer(minLength: Theme.Spacing.lg)

                DashboardTextAction(
                    title: "Review all",
                    tone: .secondary,
                    action: onOpenReviewInbox
                )
            }

            ReviewAutomationOverview(
                plan: plan,
                isApplyingAutomation: isApplyingAutomation,
                onApplySafeConfirmations: onApplySafeConfirmations
            )

            VStack(spacing: 0) {
                ForEach(subscriptions) { subscription in
                    ReviewQueueRow(
                        subscription: subscription,
                        preview: previews[subscription.id],
                        isProcessing: processingSubscriptionID == subscription.id,
                        onConfirm: { onConfirm(subscription) },
                        onReject: { onReject(subscription) },
                        onOpenDetails: { onOpenDetails(subscription) }
                    )

                    if subscription.id != lastSubscriptionID {
                        HairlineDivider()
                            .padding(.leading, 56)
                    }
                }
            }
            .featureCard()
        }
    }

    private var reviewNarrative: String {
        guard plan.totalReviewCount > subscriptions.count else {
            return "Keep what belongs. Skip what does not. The app learns your taste."
        }
        return "Showing \(subscriptions.count) of \(plan.totalReviewCount). Obvious calls can move together; uncertain ones stay here."
    }
}

private struct ReviewAutomationOverview: View {
    let plan: ReviewAutomationPlan
    let isApplyingAutomation: Bool
    let onApplySafeConfirmations: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                    automationMetric(
                        title: "Ready to keep",
                        count: plan.confirmCandidates.count,
                        tone: .positive
                    )
                    automationMetric(
                        title: "Ready to skip",
                        count: plan.suppressCandidates.count,
                        tone: .warning
                    )
                    automationMetric(
                        title: "Need your call",
                        count: plan.manualCountAfterAutomation,
                        tone: .secondary
                    )
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    automationMetric(
                        title: "Ready to keep",
                        count: plan.confirmCandidates.count,
                        tone: .positive
                    )
                    automationMetric(
                        title: "Ready to skip",
                        count: plan.suppressCandidates.count,
                        tone: .warning
                    )
                    automationMetric(
                        title: "Need your call",
                        count: plan.manualCountAfterAutomation,
                        tone: .secondary
                    )
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.lg) {
                Text(actionSummary)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.textSecondary)

                Spacer()

                DashboardTextAction(
                    title: isApplyingAutomation ? "Applying..." : "Apply the obvious calls",
                    tone: .accent,
                    isDisabled: plan.automatableCandidates.isEmpty || isApplyingAutomation,
                    action: onApplySafeConfirmations
                )
            }
        }
        .surfaceTile()
    }

    private func automationMetric(
        title: String,
        count: Int,
        tone: DashboardStoryTone
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("\(count)")
                .font(Theme.Typography.headline)
                .foregroundStyle(tone.color)
                .contentTransition(.numericText())
            Text(title)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Colors.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionSummary: String {
        if plan.automatableCandidates.isEmpty {
            return "Nothing is confident enough to handle without you."
        }
        return "Confident matches move now; gray areas wait for you."
    }
}

private struct ReviewQueueRow: View {
    let subscription: Subscription
    let preview: MerchantLearningPreview?
    let isProcessing: Bool
    let onConfirm: () -> Void
    let onReject: () -> Void
    let onOpenDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                ServiceLogoBadge(
                    displayName: subscription.displayName,
                    canonicalName: subscription.canonicalName,
                    serviceIdentifier: subscription.serviceIdentifier,
                    size: 40,
                    cornerRadius: Theme.Radius.sm
                )

                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text(subscription.displayName)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Text(subscription.reviewStateTitle)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(subscription.reviewStateColor)
                    }

                    Text(subscription.reviewReasonText)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let preview {
                        Text(preview.dashboardSummary)
                            .font(Theme.Typography.caption)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }

                Spacer(minLength: Theme.Spacing.md)

                ConfidenceBar(value: subscription.confidenceScore)
            }

            HStack(spacing: Theme.Spacing.lg) {
                if isProcessing {
                    ProgressView()
                        .controlSize(.small)
                    Text("Applying decision")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                } else {
                    DashboardTextAction(title: "Track this", tone: .accent, action: onConfirm)
                    DashboardTextAction(title: "Skip it", tone: .destructive, action: onReject)
                    DashboardTextAction(title: "Look closer", tone: .secondary, action: onOpenDetails)
                }
            }
        }
        .padding(.vertical, Theme.Spacing.md)
    }
}

struct SpendStorySection: View {
    let metrics: DashboardMetrics
    let onSelectSubscription: (UUID) -> Void
    @State private var selectedMonth: Date?

    private var selectedPoint: MonthlySpendPoint? {
        guard let selectedMonth else { return nil }
        return metrics.monthlySpend.first {
            Calendar.current.isDate($0.month, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    private var actNowEntries: [DashboardStoryEntry] {
        metrics.actNowItems.prefix(3).map { item in
            DashboardStoryEntry(
                id: item.subscriptionID.uuidString,
                title: item.subscriptionName,
                detail: item.detail,
                tone: tone(for: item.action),
                subscriptionID: item.subscriptionID
            )
        }
    }

    private var priceShiftEntries: [DashboardStoryEntry] {
        metrics.priceChangedSubscriptions.prefix(3).map { subscription in
            let percent = Int((subscription.priceChangePercent ?? 0) * 100)
            let detail: String
            if percent > 0 {
                let latestAmount = subscription.priceAmount.currencyString(code: subscription.priceCurrency)
                detail = "Now \(latestAmount), up \(percent)% from earlier charges."
            } else {
                detail = "Recently changed."
            }

            return DashboardStoryEntry(
                id: subscription.id.uuidString,
                title: subscription.displayName,
                detail: detail,
                tone: .warning,
                subscriptionID: subscription.id
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Text("Spend story")
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)

            Text(storySummary)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)

            VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                chartSection

                if actNowEntries.isEmpty == false {
                    DashboardStoryList(
                        title: "Act now",
                        entries: actNowEntries,
                        onSelectSubscription: onSelectSubscription
                    )
                }

                if priceShiftEntries.isEmpty == false {
                    DashboardStoryList(
                        title: "Price shifts",
                        entries: priceShiftEntries,
                        onSelectSubscription: onSelectSubscription
                    )
                }
            }
            .featureCard()
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly spend")
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textPrimary)

                Spacer()

                if let selectedPoint {
                    Text(selectedPoint.totalSpend.currencyString())
                        .font(Theme.Typography.price)
                        .foregroundStyle(Theme.Colors.accent)
                        .contentTransition(.numericText())
                }
            }

            Chart(metrics.monthlySpend) { point in
                BarMark(
                    x: .value("Month", point.month, unit: .month),
                    y: .value("Spend", point.totalSpend.doubleValue)
                )
                .foregroundStyle(
                    isSelected(point)
                        ? Theme.Colors.accent.gradient
                        : Theme.Colors.accent.opacity(0.5).gradient
                )
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xs))

                if let selectedPoint,
                   Calendar.current.isDate(point.month, equalTo: selectedPoint.month, toGranularity: .month) {
                    RuleMark(x: .value("Selected", point.month, unit: .month))
                        .foregroundStyle(Theme.Colors.accent.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 0))
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .month)) { _ in
                    AxisValueLabel(format: .dateTime.month(.abbreviated))
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                        .foregroundStyle(Theme.Colors.border)
                    AxisValueLabel {
                        if let doubleValue = value.as(Double.self) {
                            Text("$\(Int(doubleValue))")
                                .font(Theme.Typography.caption)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedMonth)
            .frame(height: 190)
        }
    }

    private var storySummary: String {
        var fragments: [String] = [
            "\(metrics.monthlyRunRate.currencyString()) monthly across \(metrics.activeCount) services."
        ]

        if let monthlyChange = metrics.monthlyChange {
            let prefix = monthlyChange.isPositive ? "Down" : "Up"
            fragments.append("\(prefix) \(monthlyChange.label) from the previous month.")
        }

        if metrics.actNowItems.isEmpty == false {
            fragments.append("\(metrics.actNowItems.count) renewals need attention in the next 30 days.")
        }

        if metrics.priceChangedSubscriptions.isEmpty == false {
            fragments.append("\(metrics.priceChangedSubscriptions.count) subscriptions changed price recently.")
        }

        return fragments.joined(separator: " ")
    }

    private func tone(for action: RenewalAction) -> DashboardStoryTone {
        switch action {
        case .keep:
            return .secondary
        case .review:
            return .warning
        case .cancel:
            return .destructive
        }
    }

    private func isSelected(_ point: MonthlySpendPoint) -> Bool {
        guard let selectedMonth else { return true }
        return Calendar.current.isDate(point.month, equalTo: selectedMonth, toGranularity: .month)
    }
}

private struct DashboardStoryList: View {
    let title: String
    let entries: [DashboardStoryEntry]
    var onSelectSubscription: ((UUID) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)

            VStack(spacing: Theme.Spacing.sm) {
                ForEach(entries) { entry in
                    if let subscriptionID = entry.subscriptionID,
                       let onSelectSubscription {
                        Button {
                            onSelectSubscription(subscriptionID)
                        } label: {
                            storyRow(entry)
                        }
                        .buttonStyle(.plain)
                    } else {
                        storyRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func storyRow(_ entry: DashboardStoryEntry) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.textPrimary)
                Text(entry.detail)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(entry.tone.color)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if entry.subscriptionID != nil {
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(.top, 2)
            }
        }
    }
}

private struct DashboardStoryEntry: Identifiable {
    let id: String
    let title: String
    let detail: String
    let tone: DashboardStoryTone
    let subscriptionID: UUID?

    init(
        id: String,
        title: String,
        detail: String,
        tone: DashboardStoryTone,
        subscriptionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.tone = tone
        self.subscriptionID = subscriptionID
    }
}

private enum DashboardStoryTone {
    case primary
    case secondary
    case positive
    case warning
    case destructive

    var color: Color {
        switch self {
        case .primary:
            return Theme.Colors.textPrimary
        case .secondary:
            return Theme.Colors.textSecondary
        case .positive:
            return Theme.Colors.positive
        case .warning:
            return Theme.Colors.warning
        case .destructive:
            return Theme.Colors.destructive
        }
    }
}

private struct DashboardTextAction: View {
    enum Tone {
        case accent
        case secondary
        case destructive

        var color: Color {
            switch self {
            case .accent:
                return Theme.Colors.accent
            case .secondary:
                return Theme.Colors.textSecondary
            case .destructive:
                return Theme.Colors.destructive
            }
        }
    }

    let title: String
    let tone: Tone
    var isDisabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.callout)
                .foregroundStyle(tone.color.opacity(isDisabled ? 0.45 : 1))
                .padding(.vertical, Theme.Spacing.xs)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(tone.color)
                        .frame(height: 0.5)
                        .opacity(isHovered && !isDisabled ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(EditorialButtonFeedbackStyle(isDisabled: isDisabled))
        .disabled(isDisabled)
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(
            Theme.Animation.whenAllowed(
                Theme.Animation.feedbackSmooth,
                reduceMotion: reduceMotion
            ),
            value: isHovered
        )
    }
}

private struct DashboardSummaryLine: View {
    enum Tone {
        case quietBlue
        case moss
        case rose
        case clay

        var color: Color {
            switch self {
            case .quietBlue:
                return Theme.Colors.quietBlue
            case .moss:
                return Theme.Colors.moss
            case .rose:
                return Theme.Colors.rose
            case .clay:
                return Theme.Colors.clay
            }
        }
    }

    let symbol: String
    let label: String
    let value: String
    let tone: Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            // Editorial marker — a tiny glyph + accent rule, no circle background
            VStack(spacing: 2) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(tone.color)
                Rectangle()
                    .fill(tone.color.opacity(0.5))
                    .frame(width: 1, height: 16)
            }
            .frame(width: 14)
            .padding(.top, 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(label.uppercased())
                    .font(Theme.Typography.stamp)
                    .tracking(1.8)
                    .foregroundStyle(Theme.Colors.textTertiary)

                Text(value)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textPrimary)
                    .contentTransition(.numericText())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Theme.Spacing.sm)
    }
}

struct MetricChange {
    let label: String
    let isPositive: Bool
}

extension Subscription {
    var isSingleChargeReviewCandidate: Bool {
        status == .needsReview &&
            firstChargeDate != nil &&
            firstChargeDate == lastChargeDate &&
            predictedNextChargeDate != nil
    }

    var cardSubtitle: String {
        let frequencyLabel = cadence == .unknown ? "" : cadence.rawValue.capitalized
        if let nextChargeDate = predictedNextChargeDate {
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d"
            let dateString = formatter.string(from: nextChargeDate)
            return frequencyLabel.isEmpty
                ? "Next: \(dateString)"
                : "\(frequencyLabel) - Next: \(dateString)"
        }
        return frequencyLabel
    }

    var cadenceShortLabel: String {
        switch cadence {
        case .monthly: "/mo"
        case .annual: "/yr"
        case .quarterly: "/qtr"
        case .semiannual: "/6mo"
        case .biweekly: "/2wk"
        case .weekly: "/wk"
        case .unknown: ""
        }
    }

    var reviewStateTitle: String {
        if isSingleChargeReviewCandidate,
           let date = predictedNextChargeDate {
            return "Likely renews \(date.shortDateString)"
        }
        return "Needs confirmation"
    }

    var reviewStateColor: Color {
        isSingleChargeReviewCandidate ? Theme.Colors.warning : Theme.Colors.textTertiary
    }

    var reviewReasonText: String {
        detectionReason?.nilIfBlank ?? "Recurring activity needs a decision before it becomes part of your subscription list."
    }
}
