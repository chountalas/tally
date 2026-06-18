import SwiftData
import SwiftUI

@main
struct TallyApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var appModel = AppModel()
    @State private var bootstrap: ModelContainerFactory.BootstrapResult?
    @AppStorage("appearanceMode") private var appearanceMode: AppearanceOption = .system

    var body: some Scene {
        #if os(macOS)
        Window("Tally", id: "main") {
            rootView
        }
        .defaultSize(width: 1320, height: 880)
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            appModel.refreshIntelligenceProviderState()
        }
        #else
        WindowGroup {
            rootView
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            appModel.refreshIntelligenceProviderState()
        }
        #endif
    }

    private var resolvedColorScheme: ColorScheme? {
        #if DEBUG
        if let forced = TallyPreview.forcedColorScheme { return forced }
        #endif
        switch appearanceMode {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    @ViewBuilder
    private var rootView: some View {
        if let bootstrap {
            if let sharedModelContainer = bootstrap.container {
                RootTabView()
                    .environment(appModel)
                    .modelContainer(sharedModelContainer)
                    .preferredColorScheme(resolvedColorScheme)
                    .onOpenURL { url in
                        appModel.handleIncomingURL(url)
                    }
            } else {
                StartupFailureView(message: bootstrap.startupMessage ?? "Tally could not start.")
                    .preferredColorScheme(resolvedColorScheme)
            }
        } else {
            StartupLoadingView()
                .preferredColorScheme(resolvedColorScheme)
                .task {
                    guard bootstrap == nil else {
                        return
                    }

                    let result = ModelContainerFactory.makeBootstrapResult()
                    bootstrap = result
                    appModel.startupMessage = result.startupMessage

                    #if DEBUG
                    if TallyPreview.isActive {
                        TallyPreview.apply(to: appModel, container: result.container)
                    }
                    #endif
                }
        }
    }
}

private struct StartupLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening your library...")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

private struct StartupFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "Startup Failed",
            systemImage: "externaldrive.badge.xmark",
            description: Text(message)
        )
        .padding()
    }
}
