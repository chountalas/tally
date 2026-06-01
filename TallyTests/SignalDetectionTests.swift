import XCTest
@testable import Tally

@MainActor
final class SignalDetectionTests: XCTestCase {
    private let service = SubscriptionDetectionService()

    func testMemoDiversityIgnoresInvoiceNumbers() {
        let transactions = (1...4).map { index in
            makeTransaction(memo: "Adobe Creative Cloud INV-2024-00\(index)")
        }

        let diversity = service.memoDiversityScore(for: transactions)
        XCTAssertLessThan(diversity, 0.5)
    }

    func testMemoDiversityIgnoresDateSuffixes() {
        let transactions = [
            makeTransaction(memo: "Netflix Jan 2026"),
            makeTransaction(memo: "Netflix Feb 2026"),
            makeTransaction(memo: "Netflix Mar 2026")
        ]

        let diversity = service.memoDiversityScore(for: transactions)
        XCTAssertLessThan(diversity, 0.5)
    }

    func testAmountVariationPenaltyNotTriggeredBelow30Percent() {
        XCTAssertEqual(service.amountVariationPenalty(priceVariation: 0.25), 0)
    }

    func testAmountVariationPenaltyTriggeredAbove30Percent() {
        let penalty = service.amountVariationPenalty(priceVariation: 0.35)
        XCTAssertGreaterThan(penalty, 0)
        XCTAssertLessThanOrEqual(penalty, 0.15)
    }

    func testNewKeywordsDetected() {
        XCTAssertTrue(service.hasExplicitSubscriptionKeywords(makeTransaction(memo: "auto-renew subscription")))
        XCTAssertTrue(service.hasExplicitSubscriptionKeywords(makeTransaction(memo: "Monthly billing cycle")))
        XCTAssertTrue(service.hasExplicitSubscriptionKeywords(makeTransaction(memo: "Software license renewal")))
        XCTAssertTrue(service.hasExplicitSubscriptionKeywords(makeTransaction(memo: "Cloud storage plan")))
    }

    private func makeTransaction(memo: String) -> NormalizedTransaction {
        let transaction = NormalizedTransaction(
            transactionDate: .now,
            transactionAmount: Decimal(string: "-9.99") ?? -9.99,
            merchantRaw: "TEST MERCHANT",
            merchantNormalized: "Test Merchant",
            currency: "USD",
            category: nil,
            memo: memo,
            merchantKind: .softwareOrSaaS,
            merchantSubscriptionAffinity: 0.9
        )
        transaction.classificationConfidence = 0.9
        return transaction
    }
}
