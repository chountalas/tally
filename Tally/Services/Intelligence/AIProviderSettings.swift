import Foundation
import FoundationModels
import OSLog

private let aiProviderLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "Tally",
    category: "AIProvider"
)

@available(iOS 26.0, macOS 26.0, *)
private extension SystemLanguageModel.Availability.UnavailableReason {
    var description: String {
        switch self {
        case .deviceNotEligible:
            return "device not eligible"
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is not enabled"
        case .modelNotReady:
            return "model assets are not ready"
        @unknown default:
            return "unknown availability reason"
        }
    }
}

enum AIProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case gemmaLocal = "gemma_local"
    case appleIntelligence = "apple_intelligence"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemmaLocal:
            return "Gemma"
        case .appleIntelligence:
            return "Apple Intelligence"
        }
    }

    var detail: String {
        switch self {
        case .gemmaLocal:
            return "Runs locally with the managed on-device Gemma model."
        case .appleIntelligence:
            return "Uses the system model Apple exposes on this Mac."
        }
    }
}

struct AIProviderPreferences {
    static let selectedProviderDefaultsKey = "intelligence_provider_kind"
    static let aiGenerationDisabledDefaultsKey = "intelligence_generation_disabled"

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var selectedKind: AIProviderKind {
        get {
            guard
                let rawValue = userDefaults.string(forKey: Self.selectedProviderDefaultsKey),
                let storedKind = AIProviderKind(rawValue: rawValue)
            else {
                return Self.defaultKind
            }

            return storedKind
        }
        nonmutating set {
            userDefaults.set(newValue.rawValue, forKey: Self.selectedProviderDefaultsKey)
        }
    }

    var isAIGenerationDisabled: Bool {
        get {
            userDefaults.bool(forKey: Self.aiGenerationDisabledDefaultsKey)
        }
        nonmutating set {
            userDefaults.set(newValue, forKey: Self.aiGenerationDisabledDefaultsKey)
        }
    }

    static var defaultKind: AIProviderKind {
        #if os(macOS)
        return .gemmaLocal
        #else
        return .appleIntelligence
        #endif
    }
}

struct AIProviderStatusSnapshot: Equatable, Sendable {
    let health: AIProviderHealth
    let fallbackState: AIProviderFallbackState
    let isReady: Bool
    let title: String
    let detail: String
}

enum AIProviderHealth: Equatable, Sendable {
    case ready
    case downloading
    case missing
    case adoptable
    case invalid
    case failed
    case runtimeUnavailable
    case unavailable
}

enum AIProviderFallbackState: Equatable, Sendable {
    case none
    case degraded
}

private extension AIProviderStatusSnapshot {
    static func gemma(
        health: AIProviderHealth,
        isReady: Bool,
        title: String,
        detail: String,
        fallbackState: AIProviderFallbackState
    ) -> AIProviderStatusSnapshot {
        AIProviderStatusSnapshot(
            health: health,
            fallbackState: fallbackState,
            isReady: isReady,
            title: title,
            detail: detail
        )
    }
}

enum AIProviderRegistry {
    static func defaultGenerator(
        preferences: AIProviderPreferences = AIProviderPreferences(),
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        allowsModelAdoption: Bool = true
    ) -> (any SubscriptionIntelligenceGenerating)? {
        guard preferences.isAIGenerationDisabled == false else {
            return nil
        }

        let selectedKind = preferences.selectedKind
        if let generator = makeGenerator(
            for: selectedKind,
            gemmaModelManager: gemmaModelManager,
            allowsModelAdoption: allowsModelAdoption
        ) {
            return generator
        }

        // The selected provider can't run right now (model not downloaded,
        // OS too old, runtime missing). Detection quality degrades sharply
        // without a model, so fall back to the other provider when it is
        // ready — without adoption side effects the user didn't opt into.
        let fallbackKind: AIProviderKind = selectedKind == .gemmaLocal ? .appleIntelligence : .gemmaLocal
        return makeGenerator(
            for: fallbackKind,
            gemmaModelManager: gemmaModelManager,
            allowsModelAdoption: false
        )
    }

    private static func makeGenerator(
        for kind: AIProviderKind,
        gemmaModelManager: GemmaModelManager,
        allowsModelAdoption: Bool
    ) -> (any SubscriptionIntelligenceGenerating)? {
        switch kind {
        case .gemmaLocal:
            #if os(macOS)
            guard GemmaRuntime.isAvailable else {
                return nil
            }

            do {
                let modelURL = allowsModelAdoption
                    ? try gemmaModelManager.prepareManagedModelIfNeeded()
                    : gemmaModelManager.managedModelIfReady()
                guard let modelURL else {
                    return nil
                }

                return GemmaLocalIntelligenceGenerator(modelURL: modelURL)
            } catch {
                return nil
            }
            #else
            return nil
            #endif
        case .appleIntelligence:
            let model = SystemLanguageModel(useCase: .general)
            guard model.isAvailable else { return nil }
            return FoundationModelsIntelligenceGenerator()
        }
    }

    static func statusSnapshot(
        for kind: AIProviderKind,
        gemmaModelManager: GemmaModelManager = GemmaModelManager(),
        gemmaStatusSnapshot: GemmaModelStatusSnapshot? = nil,
        isGemmaRuntimeAvailable: Bool = GemmaRuntime.isAvailable
    ) -> AIProviderStatusSnapshot {
        switch kind {
        case .gemmaLocal:
            #if os(macOS)
            if let snapshot = gemmaStatusSnapshot {
                let fallbackState: AIProviderFallbackState = snapshot.kind == .ready ? .none : .degraded
                let providerSnapshot = AIProviderStatusSnapshot.gemma(
                    health: mappedHealth(from: snapshot.health),
                    isReady: snapshot.kind == .ready,
                    title: snapshot.title,
                    detail: snapshot.detail,
                    fallbackState: fallbackState
                )
                aiProviderLogger.notice(
                    "Resolved Gemma provider health from snapshot: \(String(describing: providerSnapshot.health), privacy: .public) fallback=\(String(describing: providerSnapshot.fallbackState), privacy: .public)"
                )
                return providerSnapshot
            }

            guard isGemmaRuntimeAvailable else {
                let snapshot = AIProviderStatusSnapshot.gemma(
                    health: .runtimeUnavailable,
                    isReady: false,
                    title: "Gemma runtime is unavailable",
                    detail: """
                    This build does not include the local llama runtime needed to run Gemma. \
                    Subscription detection and summaries will continue in degraded fallback mode.
                    """,
                    fallbackState: .degraded
                )
                aiProviderLogger.notice(
                    "Resolved Gemma provider health: \(String(describing: snapshot.health), privacy: .public) fallback=\(String(describing: snapshot.fallbackState), privacy: .public)"
                )
                return snapshot
            }

            let snapshot = gemmaModelManager.statusSnapshot()
            let fallbackState: AIProviderFallbackState = snapshot.kind == .ready ? .none : .degraded
            let providerSnapshot = AIProviderStatusSnapshot.gemma(
                health: mappedHealth(from: snapshot.health),
                isReady: snapshot.kind == .ready,
                title: snapshot.title,
                detail: snapshot.detail,
                fallbackState: fallbackState
            )
            aiProviderLogger.notice(
                "Resolved Gemma provider health: \(String(describing: providerSnapshot.health), privacy: .public) fallback=\(String(describing: providerSnapshot.fallbackState), privacy: .public)"
            )
            return providerSnapshot
            #else
            return AIProviderStatusSnapshot(
                health: .unavailable,
                fallbackState: .degraded,
                isReady: false,
                title: "Gemma is unavailable",
                detail: "The local Gemma runtime currently ships on macOS only. Fallback classification remains available."
            )
            #endif
        case .appleIntelligence:
            let model = SystemLanguageModel(useCase: .contentTagging)
            switch model.availability {
            case .available:
                return AIProviderStatusSnapshot(
                    health: .ready,
                    fallbackState: .none,
                    isReady: true,
                    title: "Apple Intelligence is ready",
                    detail: "The system language model is available on this Mac."
                )
            case let .unavailable(reason):
                return AIProviderStatusSnapshot(
                    health: .unavailable,
                    fallbackState: .degraded,
                    isReady: false,
                    title: "Apple Intelligence is unavailable",
                    detail: "\(reason.description) Subscription detection and summaries will continue with fallback generation."
                )
            }
        }
    }

    private static func mappedHealth(from health: GemmaModelHealth) -> AIProviderHealth {
        switch health {
        case .ready:
            return .ready
        case .missing:
            return .missing
        case .adoptable:
            return .adoptable
        case .downloading:
            return .downloading
        case .invalid:
            return .invalid
        case .failed:
            return .failed
        }
    }
}
