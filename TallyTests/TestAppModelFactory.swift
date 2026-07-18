import Foundation
import SwiftData
@testable import Tally

extension AppModel {
    @MainActor
    static func testing(
        selectedProviderKind: AIProviderKind = .gemmaLocal,
        gemmaModelManager: GemmaModelManager? = nil,
        libraryResetService: LibraryResetService = LibraryResetService(),
        dashboardMetricsProvider: DashboardMetricsProvider? = nil,
        calendarEventCleaner: @escaping ([String]) throws -> Void = { _ in },
        calendarEventCleanupFailureRecorder: @escaping ([String]) -> Void = { _ in },
        csvImporter: CSVTransactionImporter = CSVTransactionImporter(),
        xlsxImporter: XLSXTransactionImporter = XLSXTransactionImporter(),
        xlsImporter: XLSBinaryTransactionImporter = XLSBinaryTransactionImporter()
    ) -> AppModel {
        let suiteName = "TallyTests.AppModel.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.selectedKind = selectedProviderKind
        preferences.isAIGenerationDisabled = true

        return AppModel(
            aiProviderPreferences: preferences,
            gemmaModelManager: gemmaModelManager ?? Self.emptyGemmaModelManager(),
            libraryResetService: libraryResetService,
            dashboardMetricsProvider: dashboardMetricsProvider,
            calendarEventCleaner: calendarEventCleaner,
            calendarEventCleanupFailureRecorder: calendarEventCleanupFailureRecorder,
            csvImporter: csvImporter,
            xlsxImporter: xlsxImporter,
            xlsImporter: xlsImporter
        )
    }

    private static func emptyGemmaModelManager() -> GemmaModelManager {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TallyTests-\(UUID().uuidString)", directoryHint: .isDirectory)

        return GemmaModelManager(
            appSupportDirectory: directory,
            adoptableSourceURLs: []
        )
    }
}
