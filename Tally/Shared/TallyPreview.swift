#if DEBUG
import Foundation
import SwiftData
import SwiftUI

/// DEBUG-only launch-argument controls for deterministic design screenshots.
/// These drive the *real* (already populated) store read-only — nothing is
/// seeded or persisted. Completely inert in release builds and unless a
/// `-PreviewScreen` argument is passed.
///
/// - `-PreviewScreen <name>`          home | subscriptions | insights | calendar | settings | detail | addsheet
/// - `-PreviewAppearance dark|light`  force a color scheme (otherwise follows system)
@MainActor
enum TallyPreview {
    static var isActive: Bool { value(for: "-PreviewScreen") != nil }

    static var forcedColorScheme: ColorScheme? {
        switch value(for: "-PreviewAppearance")?.lowercased() {
        case "dark": .dark
        case "light": .light
        default: nil
        }
    }

    /// Steer the freshly launched UI to the requested screen. Called only when
    /// `isActive`, so normal launches keep their own default tab.
    static func apply(to appModel: AppModel, container: ModelContainer?) {
        appModel.startupMessage = nil  // a clean screenshot shouldn't show the startup alert
        switch value(for: "-PreviewScreen")?.lowercased() {
        case "subscriptions": appModel.selectedTab = .subscriptions
        case "insights": appModel.selectedTab = .audit
        case "calendar": appModel.selectedTab = .calendar
        case "settings": appModel.selectedTab = .settings
        case "addsheet": appModel.addOrEditSheet = .chooser
        case "create": appModel.addOrEditSheet = .create
        case "edit":
            if let id = detailTarget(in: container) { appModel.addOrEditSheet = .edit(id) }
        case "review": appModel.openSubscriptionLibrary(state: .suggested)
        case "detail": appModel.tallySelectedSubscriptionID = detailTarget(in: container)
        default: appModel.selectedTab = .dashboard
        }
    }

    /// Prefer a subscription whose price increased (most interesting detail), else the first active one.
    private static func detailTarget(in container: ModelContainer?) -> UUID? {
        guard let container else { return nil }
        let subs = (try? container.mainContext.fetch(FetchDescriptor<Subscription>())) ?? []
        let active = subs.filter { $0.status == .active }
        let bumped = active.first { ($0.priceChangePercent ?? 0) > 0.05 }
        return (bumped ?? active.first ?? subs.first)?.id
    }

    private static func value(for flag: String) -> String? {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }
}
#endif
