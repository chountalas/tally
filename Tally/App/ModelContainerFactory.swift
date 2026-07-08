import SwiftData
import Foundation

enum ModelContainerFactory {
    struct BootstrapResult {
        let container: ModelContainer?
        let startupMessage: String?
    }

    static func makeSharedContainer(inMemoryOnly: Bool = false) throws -> ModelContainer {
        do {
            return try makeContainer(
                configuration: inMemoryOnly ? inMemoryConfiguration : cloudKitConfiguration
            )
        } catch {
            if inMemoryOnly == false {
                return try makeContainer(configuration: inMemoryConfiguration)
            }
            throw error
        }
    }

    static func makePersistentSharedContainer() throws -> ModelContainer {
        try makeContainer(configuration: cloudKitConfiguration)
    }

    static func makeBootstrapResult() -> BootstrapResult {
        do {
            return BootstrapResult(
                container: try makeContainer(configuration: cloudKitConfiguration),
                startupMessage: nil
            )
        } catch {
            if isLikelySchemaMismatch(error) {
                return schemaMismatchResult()
            }
            return fallbackBootstrapResult(afterCloudKitError: error)
        }
    }

    private static func makeContainer(
        configuration: ModelConfiguration
    ) throws -> ModelContainer {
        try ModelContainer(
            for: ImportRecord.self,
            ColumnMappingTemplate.self,
            MerchantClassification.self,
            MerchantCorrection.self,
            MerchantAlias.self,
            NormalizedTransaction.self,
            Subscription.self,
            SubscriptionReviewRule.self,
            ManualSubscription.self,
            SourceTransactionIdentity.self,
            MerchantIdentity.self,
            MerchantIdentityMember.self,
            ServiceProfile.self,
            SubscriptionScheduleExpectation.self,
            SubscriptionMatchRule.self,
            SubscriptionOccurrence.self,
            SubscriptionDetectionEvidence.self,
            DetectionRun.self,
            configurations: configuration
        )
    }

    private static let cloudKitConfiguration = ModelConfiguration(cloudKitDatabase: .automatic)
    private static let localDiskConfiguration = ModelConfiguration(cloudKitDatabase: .none)
    private static let inMemoryConfiguration = ModelConfiguration(
        isStoredInMemoryOnly: true,
        cloudKitDatabase: .none
    )
    private static let schemaMismatchMessage =
        "The existing library is incompatible with this version of " +
        "Tally and could not be migrated automatically. " +
        "Open an older build to export your data or reset the local " +
        "store before relaunching."

    private static func isLikelySchemaMismatch(_ error: Error) -> Bool {
        let nsError = error as NSError
        let migrationCodes: Set<Int> = [
            134100, // NSPersistentStoreIncompatibleVersionHashError
            134110, // NSPersistentStoreIncompatibleSchemaError
            134130, // NSPersistentStoreOpenError
            134140, // NSPersistentStoreTimeoutError
            134190 // NSPersistentStoreMigrationError
        ]

        if nsError.domain == NSCocoaErrorDomain, migrationCodes.contains(nsError.code) {
            return true
        }

        let description = [
            nsError.localizedDescription,
            nsError.localizedFailureReason ?? "",
            nsError.localizedRecoverySuggestion ?? ""
        ]
            .joined(separator: " ")
            .lowercased()

        return containsMigrationSignal(in: description)
    }

    private static func containsMigrationSignal(in description: String) -> Bool {
        description.localizedStandardContains("migration") ||
            description.localizedStandardContains("model version") ||
            description.localizedStandardContains("incompatible") ||
            description.localizedStandardContains("version hash") ||
            description.localizedStandardContains("schema")
    }

    private static func fallbackBootstrapResult(
        afterCloudKitError error: Error
    ) -> BootstrapResult {
        do {
            return BootstrapResult(
                container: try makeContainer(configuration: localDiskConfiguration),
                startupMessage:
                    "iCloud sync could not start, so the app opened in local-only " +
                    "mode. \(error.localizedDescription)"
            )
        } catch {
            if isLikelySchemaMismatch(error) {
                return schemaMismatchResult()
            }
            return inMemoryBootstrapResult(afterPersistentStoreError: error)
        }
    }

    private static func inMemoryBootstrapResult(
        afterPersistentStoreError error: Error
    ) -> BootstrapResult {
        do {
            return BootstrapResult(
                container: try makeContainer(configuration: inMemoryConfiguration),
                startupMessage:
                    "The persistent library could not be opened, so the app " +
                    "opened with an in-memory library for this session only. " +
                    "\(error.localizedDescription)"
            )
        } catch {
            return BootstrapResult(
                container: nil,
                startupMessage: """
                Tally could not open any data store.
                \(error.localizedDescription)
                """
            )
        }
    }

    private static func schemaMismatchResult() -> BootstrapResult {
        BootstrapResult(container: nil, startupMessage: schemaMismatchMessage)
    }
}
