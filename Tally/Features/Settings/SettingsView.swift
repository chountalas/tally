import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appearanceMode") private var appearanceMode: String = "system"
    @State private var isConfirmingReset = false
    @State private var exportDocument: AppDataExportDocument?
    @State private var isExporting = false
    @State private var exportErrorMessage: String?
    @State private var dataOperationMessage: String?
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
                        isSelected: appearanceMode == option.rawValue
                    ) {
                        withAnimation(Theme.Animation.quickSmooth) {
                            appearanceMode = option.rawValue
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

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            sectionHeading(title: "Data", subtitle: "Export the library before making broader structural changes.")

            VStack(spacing: 0) {
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
                reviewRules: try modelContext.fetch(FetchDescriptor<SubscriptionReviewRule>())
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

    private func refreshLibraryCounts() {
        libraryCounts = LibraryCounts(
            imports: (try? modelContext.fetchCount(FetchDescriptor<ImportRecord>())) ?? 0,
            subscriptions: (try? modelContext.fetchCount(FetchDescriptor<Subscription>())) ?? 0,
            transactions: (try? modelContext.fetchCount(FetchDescriptor<NormalizedTransaction>())) ?? 0,
            reviewRules: (try? modelContext.fetchCount(FetchDescriptor<SubscriptionReviewRule>())) ?? 0
        )
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

private enum AppearanceOption: String, CaseIterable, Identifiable {
    case light
    case system
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light:
            return "Light"
        case .system:
            return "System"
        case .dark:
            return "Dark"
        }
    }

    var detail: String {
        switch self {
        case .light:
            return "Warm linen surfaces and editorial contrast."
        case .system:
            return "Follow the Mac appearance automatically."
        case .dark:
            return "Warm charcoal surfaces for lower-light work."
        }
    }
}

private struct LibraryCounts {
    var imports: Int = 0
    var subscriptions: Int = 0
    var transactions: Int = 0
    var reviewRules: Int = 0
}
