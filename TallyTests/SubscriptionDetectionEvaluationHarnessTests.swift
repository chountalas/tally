import XCTest
@testable import Tally

final class SubscriptionDetectionEvaluationHarnessTests: XCTestCase {
    @MainActor
    func testFixtureHarnessProducesDeterministicMetrics() async throws {
        let metrics = try await SubscriptionDetectionFixtureHarness.evaluateFixtureSuite()

        XCTAssertEqual(metrics.totalCases, SubscriptionDetectionFixtureHarness.fixtures.count)
        XCTAssertEqual(metrics.totalCases, 20)
        XCTAssertEqual(metrics.positiveCases, 15)
        XCTAssertEqual(metrics.outcomeCounts[.confirmedPositive] ?? 0, 14)
        XCTAssertEqual(metrics.outcomeCounts[.reviewPositive] ?? 0, 1)
        XCTAssertEqual(metrics.outcomeCounts[.negative] ?? 0, 5)
        XCTAssertEqual(metrics.falsePositives, 0)
        XCTAssertEqual(metrics.falseNegatives, 0)
        XCTAssertEqual(metrics.reviewOverflowCount, 0)
        XCTAssertEqual(metrics.identityMismatchCount, 0)
        XCTAssertEqual(metrics.labelCoverage["merchant_variation"], 1)
        XCTAssertEqual(metrics.labelCoverage["price_change"], 1)
        XCTAssertEqual(metrics.labelCoverage["refund_reversal"], 1)
        XCTAssertEqual(metrics.labelCoverage["multi_subscription_vendor"], 1)
        XCTAssertEqual(metrics.labelCoverage["leap_year"], 1)
        XCTAssertEqual(metrics.labelCoverage["quarterly"], 1)
        XCTAssertGreaterThanOrEqual(metrics.precision, 0.95)
        XCTAssertGreaterThanOrEqual(metrics.recall, 0.95)

        print("")
        print("=== Subscription detection fixture metrics ===")
        print("total_cases=\(metrics.totalCases)")
        print("positive_cases=\(metrics.positiveCases)")
        print("surfaced_cases=\(metrics.surfacedCases)")
        print("true_positives=\(metrics.truePositives)")
        print("false_positives=\(metrics.falsePositives)")
        print("false_negatives=\(metrics.falseNegatives)")
        print("review_overflow=\(metrics.reviewOverflowCount)")
        print("identity_mismatches=\(metrics.identityMismatchCount)")
        print("precision=\(String(format: "%.4f", metrics.precision))")
        print("recall=\(String(format: "%.4f", metrics.recall))")
        print("labels=\(metrics.labelCoverage.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ","))")

        for result in metrics.caseResults {
            print(
                [
                    result.fixture.id,
                    "labels=\(result.fixture.labels.joined(separator: ","))",
                    "expected=\(result.fixture.expectedOutcome.rawValue)",
                    "actual=\(result.actualOutcome.rawValue)",
                    "true_positive=\(result.isTruePositive)",
                    "identity_match=\(result.matchedExpectedIdentity)",
                    "canonical=\(result.matchedCanonicalName ?? "none")",
                    "all=\(result.surfacedCanonicalNames.joined(separator: ","))",
                    "missing=\(result.missingExpectedCanonicalNames.joined(separator: ","))",
                    "unexpected=\(result.unexpectedCanonicalNames.joined(separator: ","))"
                ].joined(separator: " | ")
            )
        }
    }
}
