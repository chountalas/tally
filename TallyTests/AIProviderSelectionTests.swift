import Foundation
import Testing
@testable import Tally

@Suite("AI provider selection")
struct AIProviderSelectionTests {
    @Test func macOSDefaultsToGemma() {
        let defaults = UserDefaults(suiteName: "AIProviderSelectionTests.default")!
        defaults.removePersistentDomain(forName: "AIProviderSelectionTests.default")
        let preferences = AIProviderPreferences(userDefaults: defaults)

        #expect(preferences.selectedKind == .gemmaLocal)
    }

    @Test func explicitSelectionPersists() {
        let defaults = UserDefaults(suiteName: "AIProviderSelectionTests.persist")!
        defaults.removePersistentDomain(forName: "AIProviderSelectionTests.persist")

        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.selectedKind = .appleIntelligence

        let reloaded = AIProviderPreferences(userDefaults: defaults)
        #expect(reloaded.selectedKind == .appleIntelligence)
    }

    @Test func importClassificationFallsBackToHeuristicsWhenGemmaIsSelected() {
        let defaults = UserDefaults(suiteName: "AIProviderSelectionTests.importGemma")!
        defaults.removePersistentDomain(forName: "AIProviderSelectionTests.importGemma")
        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.selectedKind = .gemmaLocal

        let engine = MerchantClassificationEngine(preferences: preferences)

        #expect(engine.importStrategy(forUniqueMerchantCount: 3) == .heuristicOnly)
        #expect(engine.importStrategy(forUniqueMerchantCount: 300) == .heuristicOnly)
    }

    @Test func detectionServiceDisablesBackgroundAIWhenGemmaIsSelected() async {
        let defaults = UserDefaults(suiteName: "AIProviderSelectionTests.detectionGemma")!
        defaults.removePersistentDomain(forName: "AIProviderSelectionTests.detectionGemma")
        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.selectedKind = .gemmaLocal

        let capabilities = await MainActor.run {
            let service = SubscriptionDetectionService(
                intelligence: SubscriptionIntelligenceService(
                    usage: .backgroundAutomation,
                    preferences: preferences
                )
            )

            return (
                service.automaticRecurringClusterEvaluationEnabled,
                service.automaticSingleChargeEvaluationEnabled
            )
        }

        #expect(capabilities.0 == false)
        #expect(capabilities.1 == false)
    }

    @Test @MainActor
    func appModelRefreshesImportStrategyAfterProviderSwitch() {
        let defaults = UserDefaults(suiteName: "AIProviderSelectionTests.runtimeSwitch")!
        defaults.removePersistentDomain(forName: "AIProviderSelectionTests.runtimeSwitch")
        let preferences = AIProviderPreferences(userDefaults: defaults)
        preferences.selectedKind = .gemmaLocal

        let appModel = AppModel(aiProviderPreferences: preferences)

        #expect(appModel.classifier.importStrategy(forUniqueMerchantCount: 300) == .heuristicOnly)

        appModel.selectIntelligenceProvider(.appleIntelligence)

        #expect(appModel.classifier.importStrategy(forUniqueMerchantCount: 300) == .providerBatch)
    }

    @Test func adoptsCompatibleExistingModelIntoManagedPath() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory.appending(path: "Managed", directoryHint: .isDirectory)
        let existingDirectory = rootDirectory.appending(path: "Existing", directoryHint: .isDirectory)
        let existingModelURL = existingDirectory.appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)

        try fileManager.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: existingModelURL)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [existingModelURL],
            minimumValidModelSizeBytes: 32
        )

        let managedURL = try #require(try manager.prepareManagedModelIfNeeded())
        #expect(fileManager.fileExists(atPath: managedURL.path))
        #expect((try managedURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

    @Test func gemmaRegistryUsesProvidedRuntimeStatusSnapshot() {
        let downloadingSnapshot = GemmaModelStatusSnapshot(
            kind: .downloading,
            health: .downloading,
            title: "Downloading Gemma",
            detail: "The local model is in flight.",
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            adoptableSourceURL: nil
        )

        let status = AIProviderRegistry.statusSnapshot(
            for: .gemmaLocal,
            gemmaStatusSnapshot: downloadingSnapshot
        )

        #expect(status.isReady == false)
        #expect(status.health == .downloading)
        #expect(status.fallbackState == .degraded)
        #expect(status.title == "Downloading Gemma")
        #expect(status.detail == "The local model is in flight.")
    }

    @Test func gemmaRuntimeUnavailableSurfacesExplicitHealthAndFallbackExposure() {
        let status = AIProviderRegistry.statusSnapshot(
            for: .gemmaLocal,
            isGemmaRuntimeAvailable: false
        )

        #expect(status.isReady == false)
        #expect(status.health == .runtimeUnavailable)
        #expect(status.fallbackState == .degraded)
        #expect(status.title == "Gemma runtime is unavailable")
        #expect(status.detail.localizedCaseInsensitiveContains("fallback"))
    }

    @Test func readyManagedModelWinsOverStaleSetupError() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.modelsDirectoryURL, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: manager.managedModelURL)

        let status = manager.statusSnapshot(errorMessage: "Gemma setup failed yesterday")

        #expect(status.kind == .ready)
        #expect(status.health == .ready)
        #expect(status.title == "Gemma is ready")
        #expect(status.modelURL == manager.managedModelURL)
        #expect(status.detail.contains("available for classification"))

        let providerStatus = AIProviderRegistry.statusSnapshot(
            for: .gemmaLocal,
            gemmaStatusSnapshot: status
        )
        #expect(providerStatus.health == .ready)
        #expect(providerStatus.fallbackState == .none)
    }

    @Test func readyManagedModelWinsOverStaleDownloadingState() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.modelsDirectoryURL, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: manager.managedModelURL)

        let status = manager.statusSnapshot(
            isDownloading: true,
            errorMessage: "Still downloading"
        )

        #expect(status.kind == .ready)
        #expect(status.health == .ready)
        #expect(status.title == "Gemma is ready")
        #expect(status.modelURL == manager.managedModelURL)

        let providerStatus = AIProviderRegistry.statusSnapshot(
            for: .gemmaLocal,
            gemmaStatusSnapshot: status
        )
        #expect(providerStatus.health == .ready)
        #expect(providerStatus.fallbackState == .none)
    }

    @Test func managedModelInsideDirectoryWithSpacesStillResolvesReady() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
            .appending(path: "Application Support", directoryHint: .isDirectory)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: rootDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.modelsDirectoryURL, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: manager.managedModelURL)

        let status = manager.statusSnapshot()

        #expect(status.kind == .ready)
        #expect(status.health == .ready)
        #expect(status.modelURL == manager.managedModelURL)
    }

    @Test func managedGemmaModelCanClassifyMerchantWithRealRuntime() async throws {
        #if os(macOS)
        guard ProcessInfo.processInfo.environment["CI"] != "true" else {
            return
        }

        #expect(GemmaRuntime.isAvailable)

        let baseDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let manager = GemmaModelManager(
            appSupportDirectory: baseDirectory.appending(
                path: Bundle.main.bundleIdentifier ?? "Tally",
                directoryHint: .isDirectory
            ),
            adoptableSourceURLs: []
        )
        guard let modelURL = manager.managedModelIfReady() else {
            return
        }

        let generator = GemmaLocalIntelligenceGenerator(modelURL: modelURL)
        let result = try await generator.classifyMerchant(
            rawMerchant: "NETFLIX.COM",
            memo: "NETFLIX.COM 408-540-3700 CA",
            category: "Entertainment",
            amount: 15.49
        )
        await GemmaRuntime.shared.unloadModelForTesting()

        #expect(result.canonicalName.isEmpty == false)
        #expect(result.canonicalName.localizedCaseInsensitiveContains("netflix"))
        #expect(result.serviceCategory.isEmpty == false)
        #expect(result.serviceCategory.localizedCaseInsensitiveContains("stream"))
        #expect((0...1).contains(result.subscriptionAffinity))
        #expect((0...1).contains(result.confidence))
        #expect([MerchantKind.mediaStreaming, .subscriptionService].contains(result.merchantKind))
        #endif
    }

    @Test func brokenManagedSymlinkSurfacesRepairStateWithoutMutatingStatusRead() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory
        let currentSourceDirectory = rootDirectory.appending(path: "Current", directoryHint: .isDirectory)
        let legacySourceDirectory = rootDirectory.appending(path: "Legacy", directoryHint: .isDirectory)
        let currentSourceURL = currentSourceDirectory.appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)
        let legacySourceURL = legacySourceDirectory.appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)

        try fileManager.createDirectory(at: currentSourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: legacySourceDirectory, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: currentSourceURL)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: legacySourceURL)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [currentSourceURL],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.managedModelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: manager.managedModelURL, withDestinationURL: legacySourceURL)
        try fileManager.removeItem(at: legacySourceURL)

        let status = manager.statusSnapshot()

        #expect(status.kind == .failed)
        #expect(status.health == .invalid)
        #expect(status.title == "Gemma model is invalid")
        #expect(status.adoptableSourceURL == currentSourceURL)
        #expect(status.modelURL == manager.managedModelURL)
        #expect(fileManager.fileExists(atPath: manager.managedModelURL.path) == false)
        #expect((try manager.managedModelURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)

        let providerStatus = AIProviderRegistry.statusSnapshot(
            for: .gemmaLocal,
            gemmaStatusSnapshot: status
        )
        #expect(providerStatus.health == .invalid)
        #expect(providerStatus.fallbackState == .degraded)
    }

    @Test func preparingManagedModelRepairsBrokenSymlinkAndAdoptsCurrentSource() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory
        let sourceDirectory = rootDirectory.appending(path: "Source", directoryHint: .isDirectory)
        let sourceURL = sourceDirectory.appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)
        let staleTargetURL = rootDirectory
            .appending(path: "Stale", directoryHint: .isDirectory)
            .appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)

        try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: staleTargetURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: sourceURL)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [sourceURL],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.managedModelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: manager.managedModelURL, withDestinationURL: staleTargetURL)

        let managedURL = try #require(try manager.prepareManagedModelIfNeeded())

        #expect(managedURL == manager.managedModelURL)
        #expect(fileManager.fileExists(atPath: managedURL.path) == true)
        #expect((try managedURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true)
    }

    @Test func installingDownloadedModelReplacesBrokenManagedPathEntry() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory
        let downloadDirectory = rootDirectory.appending(path: "Download", directoryHint: .isDirectory)
        let temporaryDownloadURL = downloadDirectory.appending(path: "CFNetworkDownload.tmp", directoryHint: .notDirectory)
        let staleTargetURL = rootDirectory
            .appending(path: "Missing", directoryHint: .isDirectory)
            .appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: manager.managedModelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: temporaryDownloadURL)
        try fileManager.createSymbolicLink(at: manager.managedModelURL, withDestinationURL: staleTargetURL)

        let installedURL = try manager.installDownloadedModel(from: temporaryDownloadURL)
        let installedData = try Data(contentsOf: installedURL)

        #expect(installedURL == manager.managedModelURL)
        #expect(installedData == Self.makeValidGGUFModel(totalBytes: 64))
        #expect((try installedURL.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == false)
    }

    @Test func adoptableSourceReportsRichHealthState() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let managedDirectory = rootDirectory.appending(path: "Managed", directoryHint: .isDirectory)
        let existingDirectory = rootDirectory.appending(path: "Existing", directoryHint: .isDirectory)
        let existingModelURL = existingDirectory.appending(path: GemmaModelManager.managedModelFileName, directoryHint: .notDirectory)

        try fileManager.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        try Self.makeValidGGUFModel(totalBytes: 64).write(to: existingModelURL)

        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: managedDirectory,
            adoptableSourceURLs: [existingModelURL],
            minimumValidModelSizeBytes: 32
        )

        let status = manager.statusSnapshot()

        #expect(status.kind == .missing)
        #expect(status.health == .adoptable)
        #expect(status.title == "Gemma can be adopted")
        #expect(status.adoptableSourceURL == existingModelURL)
    }

    @Test func corruptManagedModelReportsInvalidHealthState() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: rootDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )

        try fileManager.createDirectory(at: manager.modelsDirectoryURL, withIntermediateDirectories: true)
        try Self.makeInvalidGGUFModel(totalBytes: 64).write(to: manager.managedModelURL)

        let status = manager.statusSnapshot()

        #expect(status.kind == .failed)
        #expect(status.health == .invalid)
        #expect(status.title == "Gemma model is invalid")
        #expect(status.detail.localizedCaseInsensitiveContains("GGUF"))
        #expect(status.modelURL == manager.managedModelURL)
    }

    @Test func invalidDownloadedModelIsRejectedBeforeInstall() throws {
        let fileManager = FileManager.default
        let rootDirectory = fileManager.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let manager = GemmaModelManager(
            fileManager: fileManager,
            appSupportDirectory: rootDirectory,
            adoptableSourceURLs: [],
            minimumValidModelSizeBytes: 32
        )
        let downloadDirectory = rootDirectory.appending(path: "Download", directoryHint: .isDirectory)
        let temporaryDownloadURL = downloadDirectory.appending(path: "CFNetworkDownload.tmp", directoryHint: .notDirectory)

        try fileManager.createDirectory(at: downloadDirectory, withIntermediateDirectories: true)
        try Data("GGUF".utf8).write(to: temporaryDownloadURL)

        do {
            _ = try manager.installDownloadedModel(from: temporaryDownloadURL)
            Issue.record("Expected corrupt download to be rejected")
        } catch {
            #expect(fileManager.fileExists(atPath: manager.managedModelURL.path) == false)
        }
    }

    @Test func duplicateBatchOutputPrefersHighestConfidenceResult() async throws {
        let runtime = MockGemmaRuntime(
            output: """
            {
              "classifications": [
                {
                  "rawMerchant": "SPOTIFY",
                  "canonicalName": "Spotify AB",
                  "serviceCategory": "Streaming",
                  "merchantKind": "media_streaming",
                  "subscriptionAffinity": 0.81,
                  "confidence": 0.42
                },
                {
                  "rawMerchant": "SPOTIFY",
                  "canonicalName": "Spotify",
                  "serviceCategory": "Streaming",
                  "merchantKind": "media_streaming",
                  "subscriptionAffinity": 0.96,
                  "confidence": 0.91
                }
              ]
            }
            """
        )
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let results = try await generator.classifyMerchantsBatch([
            MerchantClassificationRequest(rawMerchant: "SPOTIFY", memo: nil, category: nil, amount: 9.99)
        ])
        let spotify = try #require(results["SPOTIFY"])

        #expect(results.count == 1)
        #expect(spotify.canonicalName == "Spotify")
        #expect(spotify.confidence == 0.91)
    }

    @Test func partialBatchOutputBackfillsMissingMerchantsWithExplicitFallback() async throws {
        let runtime = MockGemmaRuntime(
            output: """
            {
              "classifications": [
                {
                  "rawMerchant": "SPOTIFY",
                  "canonicalName": "Spotify",
                  "serviceCategory": "Streaming",
                  "merchantKind": "media_streaming",
                  "subscriptionAffinity": 0.94,
                  "confidence": 0.88
                }
              ]
            }
            """
        )
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let results = try await generator.classifyMerchantsBatch([
            MerchantClassificationRequest(rawMerchant: "SPOTIFY", memo: nil, category: nil, amount: 9.99),
            MerchantClassificationRequest(rawMerchant: "NETFLIX.COM", memo: nil, category: nil, amount: 15.49)
        ])

        let missing = try #require(results["NETFLIX.COM"])

        #expect(results.count == 2)
        #expect(missing.canonicalName == "NETFLIX.COM")
        #expect(missing.serviceCategory == "Uncategorized")
        #expect(missing.merchantKind == .unknown)
        #expect(missing.confidence == 0)
    }

    @Test func largeGemmaBatchIsSplitIntoMultipleRuntimeCalls() async throws {
        let runtime = RecordingBatchGemmaRuntime()
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let requests = (0..<9).map { index in
            MerchantClassificationRequest(
                rawMerchant: "Merchant \(index)",
                memo: "Monthly plan \(index)",
                category: "Software",
                amount: Decimal(string: "\(index + 1).99") ?? 0
            )
        }

        let results = try await generator.classifyMerchantsBatch(requests)

        #expect(results.count == 9)
        #expect(await runtime.callCount == 2)
    }

    @Test func promptTooLargeBatchFallsBackToSmallerChunks() async throws {
        let runtime = RecordingBatchGemmaRuntime(maximumMerchantsPerPrompt: 1)
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let requests = [
            MerchantClassificationRequest(rawMerchant: "Netflix", memo: "Plan", category: "Streaming", amount: 15.49),
            MerchantClassificationRequest(rawMerchant: "Spotify", memo: "Plan", category: "Streaming", amount: 11.99)
        ]

        let results = try await generator.classifyMerchantsBatch(requests)

        #expect(results.count == 2)
        #expect(results["Netflix"]?.canonicalName == "Netflix")
        #expect(results["Spotify"]?.canonicalName == "Spotify")
        #expect(await runtime.callCount == 3)
    }

    @Test func merchantClassificationToleratesTrailingNonJSONOutput() async throws {
        let runtime = MockGemmaRuntime(
            output: """
            {
              "canonicalName": "Netflix",
              "serviceCategory": "Streaming",
              "merchantKind": "media_streaming",
              "subscriptionAffinity": 0.97,
              "confidence": 0.93
            }
            <end_of_turn>
            """
        )
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let result = try await generator.classifyMerchant(
            rawMerchant: "NETFLIX.COM",
            memo: "NETFLIX.COM 408-540-3700 CA",
            category: "Entertainment",
            amount: 15.49
        )

        #expect(result.canonicalName == "Netflix")
        #expect(result.serviceCategory == "Streaming")
        #expect(result.merchantKind == .mediaStreaming)
        #expect(result.subscriptionAffinity == 0.97)
        #expect(result.confidence == 0.93)
    }

    @Test func merchantClassificationUsesDecodableJSONCandidateWhenMultipleObjectsAppear() async throws {
        let runtime = MockGemmaRuntime(
            output: """
            {
              "headline": "Ignore this schema example",
              "summary": "This is not the merchant payload",
              "followUps": ["Nope"]
            }
            {
              "canonicalName": "Netflix",
              "serviceCategory": "Streaming",
              "merchantKind": "media_streaming",
              "subscriptionAffinity": 0.97,
              "confidence": 0.93
            }
            """
        )
        let generator = GemmaLocalIntelligenceGenerator(
            modelURL: URL(fileURLWithPath: "/tmp/gemma.gguf"),
            runtime: runtime
        )

        let result = try await generator.classifyMerchant(
            rawMerchant: "NETFLIX.COM",
            memo: "NETFLIX.COM 408-540-3700 CA",
            category: "Entertainment",
            amount: 15.49
        )

        #expect(result.canonicalName == "Netflix")
        #expect(result.serviceCategory == "Streaming")
        #expect(result.merchantKind == .mediaStreaming)
        #expect(result.subscriptionAffinity == 0.97)
        #expect(result.confidence == 0.93)
    }

    private static func makeValidGGUFModel(totalBytes: Int) -> Data {
        var data = Data("GGUF".utf8)
        if totalBytes > data.count {
            data.append(Data(repeating: 0x41, count: totalBytes - data.count))
        }
        return data
    }

    private static func makeInvalidGGUFModel(totalBytes: Int) -> Data {
        var data = Data("NOTG".utf8)
        if totalBytes > data.count {
            data.append(Data(repeating: 0x58, count: totalBytes - data.count))
        }
        return data
    }
}

private struct MockGemmaRuntime: GemmaTextGeneratingRuntime {
    let output: String

    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        output
    }
}

private actor RecordingBatchGemmaRuntime: GemmaTextGeneratingRuntime {
    private(set) var callCount = 0
    private let maximumMerchantsPerPrompt: Int?

    init(maximumMerchantsPerPrompt: Int? = nil) {
        self.maximumMerchantsPerPrompt = maximumMerchantsPerPrompt
    }

    func generateText(
        modelURL: URL,
        systemPrompt: String,
        userPrompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        callCount += 1
        let merchants = Self.extractMerchants(from: userPrompt)

        if let maximumMerchantsPerPrompt, merchants.count > maximumMerchantsPerPrompt {
            throw GemmaRuntimeError.promptExceedsContextWindow(
                tokenCount: merchants.count * 100,
                maxSupported: maximumMerchantsPerPrompt * 100
            )
        }

        let items = merchants.map { merchant in
            """
            {
              "rawMerchant": "\(merchant)",
              "canonicalName": "\(merchant)",
              "serviceCategory": "Software",
              "merchantKind": "software_or_saas",
              "subscriptionAffinity": 0.88,
              "confidence": 0.91
            }
            """
        }.joined(separator: ",")

        return """
        {
          "classifications": [\(items)]
        }
        """
    }

    private static func extractMerchants(from userPrompt: String) -> [String] {
        let requestPayload = String(requestSection(in: userPrompt))
        let pattern = #""rawMerchant":\s*"([^"]+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsRange = NSRange(requestPayload.startIndex..<requestPayload.endIndex, in: requestPayload)
        return regex.matches(in: requestPayload, range: nsRange).compactMap { match in
            guard match.numberOfRanges > 1,
                  let range = Range(match.range(at: 1), in: requestPayload)
            else {
                return nil
            }
            return String(requestPayload[range])
        }
    }

    private static func requestSection(in userPrompt: String) -> Substring {
        guard let requestsMarker = userPrompt.range(of: "Requests:") else {
            return userPrompt[...]
        }

        return userPrompt[requestsMarker.upperBound...]
    }
}
