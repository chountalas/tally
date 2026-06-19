import XCTest
@testable import Tally

@MainActor
final class CadenceDetectionTests: XCTestCase {
    private let service = SubscriptionDetectionService()

    func testMonthlyDetectsCalendarDateBilling() {
        let result = service.inferCadence(from: [28, 31, 30], occurrenceCount: 4)
        XCTAssertEqual(result, .monthly)
    }

    func testMonthlyDetects25DayMedian() {
        let result = service.inferCadence(from: [24, 25, 26], occurrenceCount: 4)
        XCTAssertEqual(result, .monthly)
    }

    func testMonthlyDetects36DayMedian() {
        let result = service.inferCadence(from: [35, 36, 36], occurrenceCount: 4)
        XCTAssertEqual(result, .monthly)
    }

    func testMonthlyRejects24DayMedian() {
        let result = service.inferCadence(from: [23, 24, 24], occurrenceCount: 4)
        XCTAssertNotEqual(result, .monthly)
    }

    func testMonthlyRejects37DayMedian() {
        let result = service.inferCadence(from: [37, 37, 38], occurrenceCount: 4)
        XCTAssertNotEqual(result, .monthly)
    }

    func testWeeklyDetects5To9DayRange() {
        let result = service.inferCadence(from: [5, 7, 8, 9], occurrenceCount: 5)
        XCTAssertEqual(result, .weekly)
    }

    func testAnnualDetects360DayInterval() {
        let result = service.inferCadence(from: [360], occurrenceCount: 2)
        XCTAssertEqual(result, .annual)
    }

    func testAnnualDetects370DayInterval() {
        let result = service.inferCadence(from: [370], occurrenceCount: 2)
        XCTAssertEqual(result, .annual)
    }

    func testQuarterlyDetects88To95Range() {
        let result = service.inferCadence(from: [88, 92, 95], occurrenceCount: 4)
        XCTAssertEqual(result, .quarterly)
    }

    func testConsistencyUsesWidenedMonthlyTolerance() {
        let consistency = service.recurrenceConsistency(for: [28, 31, 30, 31], cadence: .monthly)
        XCTAssertGreaterThan(consistency, 0.75)
    }

    func testAmountStabilityScoreForPriceIncrease() {
        let score = service.amountStabilityScore(for: 0.5)
        XCTAssertGreaterThan(score, 0.15)
    }

    func testAmountStabilityScoreFor20PercentVariation() {
        let score = service.amountStabilityScore(for: 0.2)
        XCTAssertGreaterThan(score, 0.6)
    }

    func testPredictNextChargeUsesCalendarMonthForMonthEndBilling() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2024-01-31T00:00:00Z")!

        let nextChargeDate = service.predictNextCharge(
            from: lastChargeDate,
            cadence: .monthly
        )

        let components = Calendar.current.dateComponents([.year, .month, .day], from: nextChargeDate!)
        XCTAssertEqual(components.year, 2024)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 29)
    }

    func testPredictNextChargeUsesCalendarYearForLeapDayBilling() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2024-02-29T00:00:00Z")!

        let nextChargeDate = service.predictNextCharge(
            from: lastChargeDate,
            cadence: .annual
        )

        let components = Calendar.current.dateComponents([.year, .month, .day], from: nextChargeDate!)
        XCTAssertEqual(components.year, 2025)
        XCTAssertEqual(components.month, 2)
        XCTAssertEqual(components.day, 28)
    }

    func testInferStatusStaysActiveThroughSecondRenewalWindow() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2026-03-09T00:00:00Z")!
        let referenceDate = formatter.date(from: "2026-05-09T18:00:00Z")!

        let status = service.inferStatus(
            lastChargeDate: lastChargeDate,
            cadence: .monthly,
            referenceDate: referenceDate
        )

        XCTAssertEqual(status, .active)
    }

    func testInferStatusTurnsFormerAfterSecondRenewalGraceExpires() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2026-03-09T00:00:00Z")!
        let referenceDate = formatter.date(from: "2026-05-15T18:00:00Z")!

        let status = service.inferStatus(
            lastChargeDate: lastChargeDate,
            cadence: .monthly,
            referenceDate: referenceDate
        )

        XCTAssertEqual(status, .former)
    }

    func testInferStatusDoesNotKeepAnnualRenewalsActiveUntilNextYear() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2025-02-11T00:00:00Z")!
        let referenceDate = formatter.date(from: "2026-06-18T18:00:00Z")!

        let status = service.inferStatus(
            lastChargeDate: lastChargeDate,
            cadence: .annual,
            referenceDate: referenceDate
        )

        XCTAssertEqual(status, .former)
    }

    func testInferStatusDoesNotKeepQuarterlyRenewalsActiveUntilNextQuarter() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2026-01-01T00:00:00Z")!
        let referenceDate = formatter.date(from: "2026-04-13T18:00:00Z")!

        let status = service.inferStatus(
            lastChargeDate: lastChargeDate,
            cadence: .quarterly,
            referenceDate: referenceDate
        )

        XCTAssertEqual(status, .former)
    }

    func testInferStatusDoesNotKeepSemiannualRenewalsActiveUntilNextCycle() {
        let formatter = ISO8601DateFormatter()
        let lastChargeDate = formatter.date(from: "2026-01-01T00:00:00Z")!
        let referenceDate = formatter.date(from: "2026-07-13T18:00:00Z")!

        let status = service.inferStatus(
            lastChargeDate: lastChargeDate,
            cadence: .semiannual,
            referenceDate: referenceDate
        )

        XCTAssertEqual(status, .former)
    }
}
