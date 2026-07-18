import SwiftData
import XCTest
@testable import Tally

@MainActor
final class AppIntentSubscriptionStoreTests: XCTestCase {
    func testContainerCreationRetriesAfterFailure() throws {
        enum TestError: Error {
            case transient
        }

        let container = try ModelContainerFactory.makeInMemoryContainer()
        var attempts = 0
        AppIntentSubscriptionStore.configureForTesting {
            attempts += 1
            if attempts == 1 {
                throw TestError.transient
            }
            return container
        }
        defer {
            AppIntentSubscriptionStore.resetTestingConfiguration()
        }

        XCTAssertThrowsError(try AppIntentSubscriptionStore.subscriptions())
        XCTAssertNoThrow(try AppIntentSubscriptionStore.subscriptions())
        XCTAssertNoThrow(try AppIntentSubscriptionStore.transactions())
        XCTAssertEqual(attempts, 2)
    }
}
