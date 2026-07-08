import Foundation
import OSLog

private let aiProviderStateLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Tally",
    category: "AIProviderState"
)

extension AppModel {
    func selectIntelligenceProvider(_ providerKind: AIProviderKind) {
        let previousProviderKind = intelligenceProviderKind
        aiProviderPreferences.selectedKind = providerKind
        intelligenceProviderKind = providerKind
        if previousProviderKind != providerKind {
            aiProviderStateLogger.notice(
                "Selected intelligence provider changed from \(previousProviderKind.rawValue, privacy: .public) to \(providerKind.rawValue, privacy: .public)"
            )
        }
        refreshIntelligenceProviderState()
    }

    func refreshIntelligenceProviderState() {
        let previousStatus = intelligenceProviderStatus
        let resolution = aiProviderStateResolver.resolve(
            providerKind: intelligenceProviderKind,
            isDownloading: isDownloadingGemmaModel,
            errorMessage: gemmaSetupErrorMessage
        )
        gemmaModelStatus = resolution.gemmaModelStatus
        intelligenceProviderStatus = resolution.providerStatus

        if resolution.gemmaModelStatus.kind == .ready {
            gemmaSetupErrorMessage = nil
            gemmaDownloadProgress = nil
            gemmaDownloadStatusMessage = nil
        }

        if previousStatus.health != resolution.providerStatus.health ||
            previousStatus.fallbackState != resolution.providerStatus.fallbackState ||
            previousStatus.title != resolution.providerStatus.title {
            aiProviderStateLogger.notice(
                """
                Intelligence provider state transitioned provider=\(self.intelligenceProviderKind.rawValue, privacy: .public) \
                health=\(String(describing: previousStatus.health), privacy: .public)->\(String(describing: resolution.providerStatus.health), privacy: .public) \
                fallback=\(String(describing: previousStatus.fallbackState), privacy: .public)->\(String(describing: resolution.providerStatus.fallbackState), privacy: .public)
                """
            )
        }
    }

    func adoptGemmaModelIfNeeded() {
        aiProviderStateLogger.notice("Attempting Gemma model adoption")
        gemmaSetupErrorMessage = nil
        gemmaDownloadProgress = nil
        gemmaDownloadStatusMessage = nil

        do {
            if gemmaModelManager.managedModelIfReady() != nil {
                infoMessage = "Gemma is already installed and ready on this Mac."
            } else if let adoptableSourceURL = gemmaModelManager.firstAdoptableSourceURL() {
                _ = try gemmaModelManager.adoptExistingModel(from: adoptableSourceURL)
                infoMessage = "Gemma is ready for local classification and copilot responses."
            } else {
                gemmaSetupErrorMessage = "No compatible local Gemma model was found to adopt."
            }
        } catch {
            aiProviderStateLogger.error(
                "Gemma model adoption failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            gemmaSetupErrorMessage = error.localizedDescription
        }

        refreshIntelligenceProviderState()
    }

    func downloadGemmaModel() async {
        guard isDownloadingGemmaModel == false else {
            return
        }

        aiProviderStateLogger.notice("Starting Gemma model download")

        gemmaSetupErrorMessage = nil
        gemmaDownloadProgress = nil
        gemmaDownloadStatusMessage = nil

        if gemmaModelManager.managedModelIfReady() != nil {
            infoMessage = "Gemma is already installed and ready on this Mac."
            refreshIntelligenceProviderState()
            return
        }

        isDownloadingGemmaModel = true
        gemmaDownloadProgress = 0
        gemmaDownloadStatusMessage = "Starting 5.0 GB model download…"
        refreshIntelligenceProviderState()

        defer {
            isDownloadingGemmaModel = false
            refreshIntelligenceProviderState()
        }

        do {
            let progressDelegate = GemmaModelDownloadDelegate { [weak self] snapshot in
                guard let self else { return }
                self.gemmaDownloadProgress = snapshot.fractionCompleted
                self.gemmaDownloadStatusMessage = snapshot.message
            }
            let (temporaryURL, _) = try await URLSession.shared.download(
                for: gemmaModelManager.downloadRequest(),
                delegate: progressDelegate
            )
            gemmaDownloadStatusMessage = "Verifying Gemma model…"
            let gemmaModelManager = gemmaModelManager
            _ = try await Task.detached(priority: .utility) {
                try gemmaModelManager.installDownloadedModel(from: temporaryURL)
            }.value
            gemmaSetupErrorMessage = nil
            gemmaDownloadProgress = 1
            gemmaDownloadStatusMessage = "Gemma model download complete."
            infoMessage = "Gemma is ready for local classification and copilot responses."
        } catch {
            aiProviderStateLogger.error(
                "Gemma model download failed error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            gemmaSetupErrorMessage = error.localizedDescription
            gemmaDownloadStatusMessage = nil
        }
    }

    func removeGemmaModel() {
        do {
            try gemmaModelManager.removeManagedModel()
            aiProviderStateLogger.notice("Removed managed Gemma model")
            gemmaSetupErrorMessage = nil
            infoMessage = "The managed Gemma model was removed from this Mac."
            gemmaDownloadProgress = nil
            gemmaDownloadStatusMessage = nil
        } catch {
            aiProviderStateLogger.error(
                "Failed to remove managed Gemma model error_type=\(String(describing: type(of: error)), privacy: .public)"
            )
            gemmaSetupErrorMessage = error.localizedDescription
        }

        refreshIntelligenceProviderState()
    }
}

private struct GemmaDownloadProgressSnapshot: Sendable {
    let fractionCompleted: Double?
    let message: String
}

private final class GemmaModelDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    private let progressHandler: @MainActor (GemmaDownloadProgressSnapshot) -> Void

    init(progressHandler: @escaping @MainActor (GemmaDownloadProgressSnapshot) -> Void) {
        self.progressHandler = progressHandler
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        let snapshot = makeSnapshot(
            totalBytesWritten: totalBytesWritten,
            totalBytesExpectedToWrite: totalBytesExpectedToWrite
        )

        Task { @MainActor in
            progressHandler(snapshot)
        }
    }

    private func makeSnapshot(
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) -> GemmaDownloadProgressSnapshot {
        let downloaded = Self.formatByteCount(totalBytesWritten)

        guard totalBytesExpectedToWrite > 0 else {
            return GemmaDownloadProgressSnapshot(
                fractionCompleted: nil,
                message: "Downloading Gemma model… \(downloaded) received"
            )
        }

        let expected = Self.formatByteCount(totalBytesExpectedToWrite)
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let percent = Int(progress * 100)

        return GemmaDownloadProgressSnapshot(
            fractionCompleted: progress,
            message: "Downloading Gemma model… \(downloaded) of \(expected) (\(percent)%)"
        )
    }

    private static func formatByteCount(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }
}
