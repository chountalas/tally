import XCTest
@testable import Tally

final class PaymentProcessorUnmaskerTests: XCTestCase {
    private let unmasker = PaymentProcessorUnmasker()

    func testAppleBillWithICloudInMemo() {
        let result = unmasker.unmask(
            rawMerchant: "APPLE.COM/BILL",
            memo: "iCloud+ 200GB",
            category: nil
        )
        XCTAssertEqual(result.unmaskedMerchant, "iCloud")
        XCTAssertEqual(result.subscriptionHint, "iCloud+")
    }

    func testAppleBillWithAppleMusicInMemo() {
        let result = unmasker.unmask(
            rawMerchant: "APPLE.COM/BILL",
            memo: "Apple Music Family",
            category: nil
        )
        XCTAssertEqual(result.unmaskedMerchant, "Apple Music")
    }

    func testAppleBillWithNoHint() {
        let result = unmasker.unmask(rawMerchant: "APPLE.COM/BILL", memo: nil, category: nil)
        XCTAssertEqual(result.unmaskedMerchant, "Apple")
        XCTAssertTrue(result.isPaymentProcessor)
    }

    func testStripePrefix() {
        let result = unmasker.unmask(rawMerchant: "STRIPE* ACME FITNESS", memo: nil, category: nil)
        XCTAssertEqual(result.unmaskedMerchant, "Acme Fitness")
        XCTAssertTrue(result.isPaymentProcessor)
        XCTAssertTrue(result.boostSubscriptionAffinity)
    }

    func testPayPalPrefix() {
        let result = unmasker.unmask(rawMerchant: "PAYPAL *NETFLIX", memo: nil, category: nil)
        XCTAssertEqual(result.unmaskedMerchant, "Netflix")
    }

    func testGooglePrefix() {
        let result = unmasker.unmask(rawMerchant: "GOOGLE *YouTube Premium", memo: nil, category: nil)
        XCTAssertEqual(result.unmaskedMerchant, "YouTube Premium")
    }

    func testNonProcessorPassthrough() {
        let result = unmasker.unmask(rawMerchant: "NETFLIX INC", memo: nil, category: nil)
        XCTAssertNil(result.unmaskedMerchant)
        XCTAssertFalse(result.isPaymentProcessor)
    }
}
