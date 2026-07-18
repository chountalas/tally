import EventKit
import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceOption = .system
    @State private var isConfirmingReset = false
    @State private var exportDocument: AppDataExportDocument?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @State private var dataOperationMessage: String?
    @State private var calendarOperationMessage: String?
    @State private var calendarAuthorizationStatus: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)
    @State private var calendarService = RenewalCalendarService()
    @State private var isSyncingCalendar = false
    @State private var libraryCounts = LibraryCounts()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    appearanceSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    intelligenceSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    librarySection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    calendarSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    #if os(iOS)
                    recordsSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)
                    #endif

                    dataSection

                    EditorialDivider()
                        .padding(.vertical, Theme.Spacing.xxl)

                    dangerSection
                }
                .editorialPage(maxWidth: Theme.Layout.preferencesMaxWidth)
            }
            .background(Theme.Colors.bg)
            .alert("Delete all local data?", isPresented: $isConfirmingReset) {
                Button("Delete", role: .destructive) {
                    Task { await wipeAllData() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This removes imports, transactions, and detected subscriptions from the local SwiftData store.")
            }
            .alert(
                "Export",
                isPresented: Binding(
                    get: { exportErrorMessage != nil },
                    set: { newValue in
                        if !newValue { exportErrorMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) { exportErrorMessage = nil }
            } message: {
                Text(exportErrorMessage ?? "")
            }
            .alert(
                "Data library",
                isPresented: Binding(
                    get: { dataOperationMessage != nil },
                    set: { newValue in
                        if !newValue { dataOperationMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) { dataOperationMessage = nil }
            } message: {
                Text(dataOperationMessage ?? "")
            }
            .alert(
                "Calendar",
                isPresented: Binding(
                    get: { calendarOperationMessage != nil },
                    set: { newValue in
                        if !newValue { calendarOperationMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) { calendarOperationMessage = nil }
            } message: {
                Text(calendarOperationMessage ?? "")
            }
            .fileExporter(
                isPresented: $isExporting,
                document: exportDocument,
                contentType: .json,
                defaultFilename: "tally-export"
            ) { result in
                if case let .failure(error) = result {
                    exportErrorMessage = error.localizedDescription
                }
            }
            .task {
                refreshLibraryCounts()
                appModel.refreshIntelligenceProviderState()
                refreshCalendarAuthorizationStatus()
            }
        }
    }

    private var headerSection: some View {
        EditorialPageHeader(
            eyebrow: "Local controls",
            title: "Preferences",
            subtitle: "Choose appearance, intelligence provider, Gemma model storage, and data export behavior for this Mac."
        )
    }

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Appearance", subtitle: "Keep the interface warm, quiet, and readable in every mode.")

            VStack(spacing: 0) {
                ForEach(Array(AppearanceOption.allCases.enumerated()), id: \.element.id) { index, option in
                    PreferenceSelectionRow(
                        title: option.label,
                        detail: option.detail,
                        isSelected: appearanceMode == option
                    ) {
                        withAnimation(Theme.Animation.quickSmooth) {
                            appearanceMode = option
                        }
                    }

                    if index < AppearanceOption.allCases.count - 1 {
                        HairlineDivider()
                            .padding(.leading, Theme.Spacing.xl)
                    }
                }
            }
            .featureCard()
        }
    }

    private var intelligenceSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            sectionHeading(
                title: "Intelligence",
                subtitle: "Switch providers deliberately, then manage the local Gemma library without leaving Preferences."
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                PreferenceValueRow(
                    title: "Current provider",
                    value: appModel.intelligenceProviderKind.title,
                    detail: appModel.intelligenceProviderStatus.detail,
                    tone: appModel.intelligenceProviderStatus.isReady ? .secondary : .warning
                )

                VStack(spacing: 0) {
                    ForEach(Array(AIProviderKind.allCases.enumerated()), id: \.element.id) { index, providerKind in
                        PreferenceSelectionRow(
                            title: providerKind.title,
                            detail: providerKind.detail,
                            isSelected: appModel.intelligenceProviderKind == providerKind
                        ) {
                            withAnimation(Theme.Animation.quickSmooth) {
                                appModel.selectIntelligenceProvider(providerKind)
                            }
                        }

                        if index < AIProviderKind.allCases.count - 1 {
                            HairlineDivider()
                                .padding(.leading, Theme.Spacing.xl)
                        }
                    }
                }
            }
            .featureCard()

            GemmaStatusPanel(
                gemmaStatus: appModel.gemmaModelStatus,
                isDownloading: appModel.isDownloadingGemmaModel,
                downloadProgress: appModel.gemmaDownloadProgress,
                downloadMessage: appModel.gemmaDownloadStatusMessage,
                isSelectedProvider: appModel.intelligenceProviderKind == .gemmaLocal,
                onAdopt: { appModel.adoptGemmaModelIfNeeded() },
                onDownload: { Task { await appModel.downloadGemmaModel() } },
                onRemove: { appModel.removeGemmaModel() }
            )
        }
    }

    private var librarySection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Library", subtitle: "A calm snapshot of what the local data store is carrying right now.")

            VStack(spacing: 0) {
                PreferenceValueRow(title: "Imports", value: "\(libraryCounts.imports)")
                HairlineDivider()
                    .padding(.leading, Theme.Spacing.xl)
                PreferenceValueRow(title: "Subscriptions", value: "\(libraryCounts.subscriptions)")
                HairlineDivider()
                    .padding(.leading, Theme.Spacing.xl)
                PreferenceValueRow(title: "Transactions", value: "\(libraryCounts.transactions)")
                HairlineDivider()
                    .padding(.leading, Theme.Spacing.xl)
                PreferenceValueRow(title: "Rules", value: "\(libraryCounts.reviewRules)")
            }
            .featureCard()
        }
    }

    #if os(iOS)
    // Tally keeps Transactions and Import history out of the iOS tab bar (they
    // live behind the gear on macOS). Surface them here so they stay reachable;
    // openTab drives the iOS utility fullScreenCover in RootTabView.
    private var recordsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Records", subtitle: "Open the full transaction ledger and import history.")

            VStack(spacing: 0) {
                PreferenceActionRow(
                    title: "Transactions",
                    detail: "Every imported charge, normalized and searchable.",
                    tone: .accent
                ) {
                    appModel.openTab(.transactions)
                }

                HairlineDivider()
                    .padding(.leading, Theme.Spacing.xl)

                PreferenceActionRow(
                    title: "Import history",
                    detail: "Review the statements you've imported.",
                    tone: .accent
                ) {
                    appModel.openTab(.imports)
                }
            }
            .featureCard()
        }
    }
    #endif

    private var calendarSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(
                title: "Calendar",
                subtitle: "Create one all-day renewal event per active subscription in a Tally calendar."
            )

            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                PreferenceValueRow(
                    title: "Permission",
                    value: calendarPermissionTitle,
                    detail: calendarPermissionDetail,
                    tone: calendarPermissionTone
                )

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Theme.Spacing.lg) {
                        calendarActions
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        calendarActions
                    }
                }
            }
            .featureCard()
        }
    }

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Data", subtitle: "Export the library before making broader structural changes.")

            VStack(spacing: 0) {
                PreferenceActionRow(
                    title: appModel.isRefreshingAnalysis ? "Re-scanning transactions..." : "Re-scan my transactions",
                    detail: "Run subscription detection again using the transactions already stored on this Mac.",
                    tone: .accent
                ) {
                    Task { await refreshSubscriptionAnalysis() }
                }

                HairlineDivider()
                    .padding(.leading, Theme.Spacing.xl)

                PreferenceActionRow(
                    title: "Export data as JSON",
                    detail: "Create a portable archive of imports, subscriptions, transactions, aliases, and review rules.",
                    tone: .accent
                ) {
                    exportJSON()
                }
            }
            .featureCard()
        }
    }

    @ViewBuilder
    private var calendarActions: some View {
        PreferenceTextAction(
            title: isSyncingCalendar ? "Syncing..." : "Sync now",
            tone: .accent,
            isDisabled: isSyncingCalendar
        ) {
            Task { await syncCalendar() }
        }

        PreferenceTextAction(
            title: "Remove synced events",
            tone: .destructive,
            isDisabled: isSyncingCalendar || subscriptions.allSatisfy { $0.calendarEventIdentifier == nil }
        ) {
            removeSyncedCalendarEvents()
        }
    }

    private var dangerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Danger zone", subtitle: "Only use destructive actions when you intend to reset the library.")

            VStack(spacing: 0) {
                PreferenceActionRow(
                    title: "Delete all data",
                    detail: "Remove imports, transactions, subscriptions, aliases, and review rules from the local SwiftData store.",
                    tone: .destructive
                ) {
                    isConfirmingReset = true
                }
            }
            .featureCard()
        }
    }

    private func sectionHeading(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(subtitle)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    private func exportJSON() {
        do {
            let data = try AppDataExporter().exportData(from: AppDataExportSource(
                imports: try modelContext.fetch(FetchDescriptor<ImportRecord>()),
                subscriptions: try modelContext.fetch(FetchDescriptor<Subscription>()),
                transactions: try modelContext.fetch(FetchDescriptor<NormalizedTransaction>()),
                classifications: try modelContext.fetch(FetchDescriptor<MerchantClassification>()),
                aliases: try modelContext.fetch(FetchDescriptor<MerchantAlias>()),
                templates: try modelContext.fetch(FetchDescriptor<ColumnMappingTemplate>()),
                reviewRules: try modelContext.fetch(FetchDescriptor<SubscriptionReviewRule>()),
                corrections: try modelContext.fetch(FetchDescriptor<MerchantCorrection>()),
                matchRules: try modelContext.fetch(FetchDescriptor<SubscriptionMatchRule>())
            ))
            exportDocument = AppDataExportDocument(data: data)
            isExporting = true
        } catch {
            exportErrorMessage = error.localizedDescription
        }
    }

    private func wipeAllData() async {
        do {
            let summary = try appModel.clearLibrary(
                in: modelContext,
                includeTemplates: true
            )
            refreshLibraryCounts()
            dataOperationMessage = summary.fullLibraryMessage
        } catch {
            dataOperationMessage = error.localizedDescription
        }
    }

    private func refreshSubscriptionAnalysis() async {
        await appModel.refreshSubscriptionAnalysis(in: modelContext)
        refreshLibraryCounts()
    }

    private func syncCalendar() async {
        guard !isSyncingCalendar else { return }

        isSyncingCalendar = true
        defer {
            isSyncingCalendar = false
            refreshCalendarAuthorizationStatus()
        }

        do {
            let summary = try await calendarService.syncRenewals(
                for: subscriptions,
                context: modelContext
            )
            calendarOperationMessage = summary.message
        } catch {
            calendarOperationMessage = error.localizedDescription
        }
    }

    private func removeSyncedCalendarEvents() {
        do {
            try calendarService.clearSyncedEvents(
                for: subscriptions,
                context: modelContext
            )
            refreshCalendarAuthorizationStatus()
            calendarOperationMessage = "Removed Tally calendar events from synced subscriptions."
        } catch {
            calendarOperationMessage = error.localizedDescription
        }
    }

    private func refreshCalendarAuthorizationStatus() {
        calendarAuthorizationStatus = calendarService.authorizationStatus()
    }

    private func refreshLibraryCounts() {
        do {
            libraryCounts = LibraryCounts(
                imports: try modelContext.fetchCount(FetchDescriptor<ImportRecord>()),
                subscriptions: try modelContext.fetchCount(FetchDescriptor<Subscription>()),
                transactions: try modelContext.fetchCount(FetchDescriptor<NormalizedTransaction>()),
                reviewRules: try modelContext.fetchCount(FetchDescriptor<SubscriptionReviewRule>())
            )
        } catch {
            dataOperationMessage = "Tally couldn't read the library totals. \(error.localizedDescription)"
        }
    }

    private var calendarPermissionTitle: String {
        switch calendarAuthorizationStatus {
        case .fullAccess:
            return "Full access"
        case .writeOnly:
            return "Write-only"
        case .notDetermined:
            return "Not requested"
        case .denied:
            return "Denied"
        case .restricted:
            return "Restricted"
        @unknown default:
            return "Unknown"
        }
    }

    private var calendarPermissionDetail: String {
        switch calendarAuthorizationStatus {
        case .fullAccess:
            return "Ready to create, update, and remove renewal events in the Tally calendar."
        case .writeOnly:
            return "Tally needs full calendar access to update and remove synced renewal events. Change this in System Settings."
        case .notDetermined:
            return "Sync now will ask macOS for calendar access."
        case .denied:
            return "Open System Settings and allow Tally full calendar access to sync renewals."
        case .restricted:
            return "Calendar access is restricted on this Mac."
        @unknown default:
            return "Calendar permission state is unavailable."
        }
    }

    private var calendarPermissionTone: PreferenceTone {
        switch calendarAuthorizationStatus {
        case .fullAccess:
            return .positive
        case .notDetermined:
            return .secondary
        case .writeOnly, .denied, .restricted:
            return .warning
        @unknown default:
            return .secondary
        }
    }
}

private struct GemmaStatusPanel: View {
    let gemmaStatus: GemmaModelStatusSnapshot
    let isDownloading: Bool
    let downloadProgress: Double?
    let downloadMessage: String?
    let isSelectedProvider: Bool
    let onAdopt: () -> Void
    let onDownload: () -> Void
    let onRemove: () -> Void

    private var showsDownloadProgress: Bool {
        isDownloading && gemmaStatus.kind == .downloading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local Gemma")
                        .font(Theme.Typography.headline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(isSelectedProvider ? "Selected for live classification and copilot responses." : "Available as the managed local provider on this Mac.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textTertiary)
                }

                Spacer()

                Text(statusBadgeTitle)
                    .font(Theme.Typography.caption)
                    .foregroundStyle(statusTone.color)
            }

            Text(gemmaStatus.detail)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)

            if let modelURL = gemmaStatus.modelURL {
                PreferenceValueRow(
                    title: "Managed model",
                    value: modelURL.path,
                    detail: "Stored inside the app support library.",
                    tone: .secondary,
                    isPathValue: true
                )
            }

            if let adoptableURL = gemmaStatus.adoptableSourceURL,
               gemmaStatus.health == .adoptable || gemmaStatus.health == .invalid || gemmaStatus.health == .failed {
                PreferenceValueRow(
                    title: "Adoptable source",
                    value: adoptableURL.path,
                    detail: "A compatible model already exists elsewhere on this Mac.",
                    tone: .secondary,
                    isPathValue: true
                )
            }

            if showsDownloadProgress {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    if let downloadProgress {
                        ProgressView(value: downloadProgress, total: 1)
                            .tint(Theme.Colors.accent)
                    } else {
                        ProgressView()
                            .tint(Theme.Colors.accent)
                    }

                    Text(downloadMessage ?? "Downloading the local Gemma model...")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: Theme.Spacing.lg) {
                    actionButtons
                }

                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    actionButtons
                }
            }
        }
        .featureCard()
    }

    @ViewBuilder
    private var actionButtons: some View {
        if gemmaStatus.health == .missing || gemmaStatus.health == .adoptable || gemmaStatus.health == .invalid || gemmaStatus.health == .failed {
            if gemmaStatus.adoptableSourceURL != nil {
                PreferenceTextAction(
                    title: gemmaStatus.health == .invalid ? "Repair with existing model" : "Use existing model",
                    tone: .accent,
                    action: onAdopt
                )
            }

            PreferenceTextAction(
                title: showsDownloadProgress ? "Downloading..." : (gemmaStatus.health == .invalid ? "Download a fresh copy" : "Download model"),
                tone: .accent,
                isDisabled: showsDownloadProgress,
                action: onDownload
            )
        }

        if gemmaStatus.health == .ready || gemmaStatus.health == .invalid || gemmaStatus.health == .failed {
            PreferenceTextAction(title: "Remove model", tone: .destructive, action: onRemove)
        }
    }

    private var statusTone: PreferenceTone {
        switch gemmaStatus.health {
        case .ready:
            return .positive
        case .downloading:
            return .accent
        case .invalid, .failed:
            return .warning
        case .adoptable:
            return .accent
        case .missing:
            return .secondary
        }
    }

    private var statusBadgeTitle: String {
        switch gemmaStatus.health {
        case .ready:
            return "Ready"
        case .downloading:
            return "Downloading"
        case .invalid:
            return "Needs attention"
        case .failed:
            return "Unavailable"
        case .adoptable:
            return "Ready to adopt"
        case .missing:
            return "Setup needed"
        }
    }
}

private struct PreferenceSelectionRow: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(isSelected ? Theme.Colors.accent : Theme.Colors.borderActive)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .buttonStyle(.plain)
    }
}

private struct PreferenceValueRow: View {
    let title: String
    let value: String
    var detail: String?
    var tone: PreferenceTone = .primary
    var isPathValue = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                Spacer()
                valueLabel
            }

            if let detail {
                Text(detail)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
        }
        .padding(.vertical, Theme.Spacing.md)
    }

    @ViewBuilder
    private var valueLabel: some View {
        if isPathValue {
            Text(value)
                .font(Theme.Typography.footnote)
                .foregroundStyle(tone.color)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } else {
            Text(value)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(tone.color)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct PreferenceActionRow: View {
    let title: String
    let detail: String
    let tone: PreferenceTone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(title)
                        .font(Theme.Typography.subheadline)
                        .foregroundStyle(tone.color)
                    Text(detail)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: tone == .destructive ? "trash" : "arrow.up.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            .padding(.vertical, Theme.Spacing.md)
        }
        .buttonStyle(.plain)
    }
}

private struct PreferenceTextAction: View {
    let title: String
    let tone: PreferenceTone
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.Typography.callout)
                .foregroundStyle(tone.color.opacity(isDisabled ? 0.45 : 1))
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

private enum PreferenceTone: Equatable {
    case primary
    case secondary
    case accent
    case positive
    case warning
    case destructive

    var color: Color {
        switch self {
        case .primary:
            return Theme.Colors.textPrimary
        case .secondary:
            return Theme.Colors.textSecondary
        case .accent:
            return Theme.Colors.accent
        case .positive:
            return Theme.Colors.positive
        case .warning:
            return Theme.Colors.warning
        case .destructive:
            return Theme.Colors.destructive
        }
    }
}

private struct LibraryCounts {
    var imports: Int = 0
    var subscriptions: Int = 0
    var transactions: Int = 0
    var reviewRules: Int = 0
}
