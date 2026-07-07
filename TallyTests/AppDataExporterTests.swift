import XCTest
@testable import Tally

final class AppDataExporterTests: XCTestCase {
    /// The exporter must capture learned suppressions (`MerchantCorrection`) and
    /// match rules, otherwise export → wipe → reimport silently loses everything
    /// the user taught Tally.
    func testExportIncludesCorrectionsAndMatchRules() throws {
        let source = AppDataExportSource(
            imports: [],
            subscriptions: [],
            transactions: [],
            classifications: [],
            aliases: [],
            templates: [],
            reviewRules: [],
            corrections: [MerchantCorrection(canonicalName: "Studio Cloud", isSubscription: false)],
            matchRules: [SubscriptionMatchRule(canonicalName: "Studio Cloud", isNegativeRule: true)]
        )

        let data = try AppDataExporter().exportData(from: source)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        let corrections = try XCTUnwrap(json["corrections"] as? [[String: Any]])
        XCTAssertEqual(corrections.count, 1)
        XCTAssertEqual(corrections.first?["canonicalName"] as? String, "Studio Cloud")
        XCTAssertEqual(corrections.first?["isSubscription"] as? Bool, false)

        let matchRules = try XCTUnwrap(json["matchRules"] as? [[String: Any]])
        XCTAssertEqual(matchRules.count, 1)
        XCTAssertEqual(matchRules.first?["canonicalName"] as? String, "Studio Cloud")
        XCTAssertEqual(matchRules.first?["isNegativeRule"] as? Bool, true)
    }
}
