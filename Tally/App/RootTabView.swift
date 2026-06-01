import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct RootTabView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]
    @State private var isPresentingPendingImporter = false

    var body: some View {
        @Bindable var appModel = appModel

        mainContent
            .sheet(item: $appModel.addOrEditSheet) { sheet in
                switch sheet {
                case .chooser:
                    AddUpdateSheet()
                case .create:
                    AddSubscriptionSheet()
                case let .edit(subscriptionID):
                    AddSubscriptionSheet(editing: subscriptions.first { $0.id == subscriptionID })
                }
            }
            .sheet(item: $appModel.importDraft) { draft in
                ImportReviewSheet(draft: draft)
            }
            .fileImporter(
                isPresented: $isPresentingPendingImporter,
                allowedContentTypes: supportedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                handlePendingImportResult(result)
            }
            .alert(
                "Library Mode",
                isPresented: Binding(
                    get: { appModel.startupMessage != nil },
                    set: { newValue in
                        if !newValue { appModel.clearStartupMessage() }
                    }
                )
            ) {
                Button("OK", role: .cancel) { appModel.clearStartupMessage() }
            } message: {
                Text(appModel.startupMessage ?? "")
            }
            .alert(
                "Import Error",
                isPresented: Binding(
                    get: { appModel.importErrorMessage != nil },
                    set: { newValue in
                        if !newValue { appModel.clearMessage() }
                    }
                )
            ) {
                Button("OK", role: .cancel) { appModel.clearMessage() }
            } message: {
                Text(appModel.importErrorMessage ?? "")
            }
            .alert(
                "Library Update",
                isPresented: Binding(
                    get: { appModel.infoMessage != nil || appModel.classificationStatusMessage != nil },
                    set: { newValue in
                        if !newValue { appModel.clearMessage() }
                    }
                )
            ) {
                Button("OK", role: .cancel) { appModel.clearMessage() }
            } message: {
                Text(
                    [appModel.infoMessage, appModel.classificationStatusMessage]
                        .compactMap { $0 }
                        .joined(separator: "\n\n")
                )
            }
            .task {
                appModel.scheduleSpotlightReindex(in: modelContext, delayNanoseconds: 2_000_000_000)
                presentPendingImporterIfNeeded()
            }
            .onChange(of: appModel.pendingImportFilePicker) { _, _ in
                presentPendingImporterIfNeeded()
            }
    }

    private var selectedSubscription: Subscription? {
        guard let id = appModel.tallySelectedSubscriptionID else { return nil }
        return subscriptions.first { $0.id == id }
    }

    private var supportedImportTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .text]
        if let xls = UTType(filenameExtension: "xls") { types.append(xls) }
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }

    private func presentPendingImporterIfNeeded() {
        guard appModel.pendingImportFilePicker else { return }
        appModel.pendingImportFilePicker = false
        Task { @MainActor in
            await Task.yield()
            isPresentingPendingImporter = true
        }
    }

    private func handlePendingImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .success(urls):
            guard let url = urls.first else { return }
            appModel.prepareImport(from: url, into: modelContext)
        case let .failure(error):
            appModel.importErrorMessage = error.localizedDescription
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(macOS)
        HStack(spacing: 0) {
            TallySidebar()
            mainPane
        }
        .background(Theme.Colors.bg)
        #else
        @Bindable var appModel = appModel
        // Detail is presented via `tallySelectedSubscriptionID` (set by rows, renewal
        // cards, insights, calendar). The macOS `mainPane` swaps to the detail; iOS must
        // do the same or taps go nowhere — present the detail over the tab content here.
        Group {
            if let sub = selectedSubscription {
                SubscriptionDetailView(subscription: sub)
                    .id("detail-\(sub.id)")
            } else {
                TabView(selection: selectedTabBinding) {
                    ForEach(SidebarTab.primary) { tab in
                        Tab(tab.title, systemImage: tab.icon, value: tab) {
                            tab.destination
                        }
                    }
                    Tab("Settings", systemImage: "gearshape", value: SidebarTab.settings) {
                        SidebarTab.settings.destination
                    }
                }
                .tint(Theme.Colors.accent)
            }
        }
        .editorialSceneTransition()
        .animation(
            Theme.Animation.whenAllowed(Theme.Animation.smooth, reduceMotion: reduceMotion),
            value: appModel.tallySelectedSubscriptionID
        )
        .fullScreenCover(isPresented: iosUtilityRouteBinding) {
            if let route = iosUtilityRoute {
                NavigationStack {
                    route.destination
                        .navigationTitle(route.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { appModel.selectedTab = .dashboard }
                            }
                        }
                }
                .tint(Theme.Colors.accent)
                // An import started from the covered Transactions screen sets
                // appModel.importDraft, but the root-level review sheet (mounted on
                // mainContent) is behind this cover and can't present over it. Mount it
                // here too so the mapping/review sheet appears over the iOS utility route.
                .sheet(item: $appModel.importDraft) { draft in
                    ImportReviewSheet(draft: draft)
                }
            }
        }
        #endif
    }

    @ViewBuilder
    private var mainPane: some View {
        ZStack {
            Theme.Colors.bg
            Group {
                if let sub = selectedSubscription {
                    SubscriptionDetailView(subscription: sub)
                        .id("detail-\(sub.id)")
                } else {
                    appModel.selectedTab.destination
                        .id(appModel.selectedTab)
                }
            }
            .editorialSceneTransition()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(
            Theme.Animation.whenAllowed(Theme.Animation.smooth, reduceMotion: reduceMotion),
            value: appModel.tallySelectedSubscriptionID
        )
    }

    private var selectedTabBinding: Binding<SidebarTab> {
        Binding(
            get: { appModel.selectedTab },
            set: { appModel.selectedTab = $0 }
        )
    }

    /// Tally keeps Transactions/Import out of the iOS tab bar (they live behind the
    /// gear), so a route that selects them has no tab to render. Surface those routes
    /// in a modal cover instead of leaving the user on a blank, unrendered tab.
    private var iosUtilityRoute: SidebarTab? {
        switch appModel.selectedTab {
        case .transactions, .imports: return appModel.selectedTab
        default: return nil
        }
    }

    private var iosUtilityRouteBinding: Binding<Bool> {
        Binding(
            get: { iosUtilityRoute != nil && selectedSubscription == nil },
            set: { isPresented in
                if !isPresented, iosUtilityRoute != nil { appModel.selectedTab = .dashboard }
            }
        )
    }
}

// MARK: - Sidebar

#if os(macOS)
private struct TallySidebar: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var navNS

    private var detailOpen: Bool { appModel.tallySelectedSubscriptionID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.bottom, 22)

            VStack(alignment: .leading, spacing: 3) {
                ForEach(SidebarTab.primary) { tab in
                    navItem(tab)
                }
            }

            Spacer(minLength: Theme.Spacing.lg)

            PrimaryGradientButton(title: "Add or update") {
                appModel.addOrEditSheet = .chooser
            }

            footer
                .padding(.top, 14)
        }
        .padding(.horizontal, 16)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(width: Theme.Layout.navigationRailWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.Colors.bgElevated)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.Colors.border).frame(width: 0.5)
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(LinearGradient(colors: [Theme.Colors.accent2, Theme.Colors.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
                .overlay(
                    Text("T").font(.system(size: 18, weight: .heavy, design: .rounded))
                        .foregroundStyle(Theme.Colors.onAccent)
                )
                .shadow(color: Theme.Colors.accent.opacity(0.4), radius: 12, x: 0, y: 5)
            VStack(alignment: .leading, spacing: 0) {
                Text("Tally").font(.system(size: 16, weight: .bold)).foregroundStyle(Theme.Colors.textPrimary)
                Text("Subscriptions").font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func navItem(_ tab: SidebarTab) -> some View {
        let isActive = appModel.selectedTab == tab && !detailOpen
        return Button {
            withAnimation(Theme.Animation.whenAllowed(Theme.Animation.quickSpring, reduceMotion: reduceMotion)) {
                appModel.tallySelectedSubscriptionID = nil
                appModel.selectedTab = tab
            }
        } label: {
            NavItemLabel(tab: tab, isActive: isActive, namespace: navNS)
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: 7) {
                LiveDot()
                Text("Saved on this Mac")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Spacer(minLength: 0)
            Menu {
                Button { appModel.openTab(.settings) } label: { Label("Settings", systemImage: "gearshape") }
                Button { appModel.openTab(.transactions) } label: { Label("Transactions", systemImage: "arrow.left.arrow.right") }
                Button { appModel.openTab(.imports) } label: { Label("Import history", systemImage: "square.and.arrow.down") }
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .padding(6)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}

private struct NavItemLabel: View {
    let tab: SidebarTab
    let isActive: Bool
    let namespace: Namespace.ID
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: tab.icon)
                .font(.system(size: 18, weight: .regular))
                .frame(width: 19, height: 19)
                .scaleEffect(hovering && !isActive && !reduceMotion ? 1.12 : 1)
            Text(tab.title)
                .font(.system(size: 14.5, weight: .semibold))
            Spacer(minLength: 0)
        }
        .foregroundStyle(isActive ? Theme.Colors.accent : (hovering ? Theme.Colors.textPrimary : Theme.Colors.textSecondary))
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Colors.accentSoft)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                            .strokeBorder(Theme.Colors.accent.opacity(0.35), lineWidth: 0.5)
                    )
                    .matchedGeometryEffect(id: "navIndicator", in: namespace)
            } else if hovering {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(Theme.Colors.textPrimary.opacity(0.05))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

#endif

// MARK: - Tabs

enum SidebarTab: String, CaseIterable, Identifiable, Hashable {
    case dashboard
    case subscriptions
    case audit
    case calendar
    case transactions
    case imports
    case settings

    /// Primary Tally navigation (Home / Subscriptions / Insights / Calendar).
    static var primary: [SidebarTab] { [.dashboard, .subscriptions, .audit, .calendar] }

    static var allCases: [SidebarTab] {
        [.dashboard, .subscriptions, .calendar, .audit, .transactions, .imports, .settings]
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .dashboard: "Home"
        case .subscriptions: "Subscriptions"
        case .audit: "Insights"
        case .calendar: "Calendar"
        case .transactions: "Transactions"
        case .imports: "Import"
        case .settings: "Settings"
        }
    }

    var supportingText: String {
        switch self {
        case .dashboard: "Spend, renewals, decisions"
        case .subscriptions: "Keep, review, archived"
        case .audit: "Patterns, savings, cleanup"
        case .calendar: "What renews next"
        case .transactions: "Every imported charge"
        case .imports: "Statements in progress"
        case .settings: "AI, reminders, data"
        }
    }

    var icon: String {
        switch self {
        case .dashboard: "house"
        case .subscriptions: "creditcard"
        case .audit: "lightbulb"
        case .calendar: "calendar"
        case .transactions: "arrow.left.arrow.right"
        case .imports: "square.and.arrow.down"
        case .settings: "gearshape"
        }
    }

    var iconFilled: String {
        switch self {
        case .dashboard: "house.fill"
        case .subscriptions: "creditcard.fill"
        case .audit: "lightbulb.fill"
        case .calendar: "calendar"
        case .transactions: "arrow.left.arrow.right"
        case .imports: "square.and.arrow.down.fill"
        case .settings: "gearshape.fill"
        }
    }

    @MainActor
    @ViewBuilder
    var destination: some View {
        switch self {
        case .dashboard: DashboardView()
        case .subscriptions: SubscriptionsView()
        case .audit: InsightsView()
        case .calendar: CalendarView()
        case .transactions: TransactionsView()
        case .imports: ImportsView()
        case .settings: SettingsView()
        }
    }
}
