import XCTest
@testable import Tally

final class FormattingTests: XCTestCase {
    // Regression guard: `currencyString` must use each currency's DEFAULT fraction
    // digits, not a forced 2. A DRY refactor once routed it through `tallyMoney`
    // (which forces 2-or-0 digits), turning JPY "¥1,234" into "¥1,234.00" in renewal
    // notifications and summaries. Compare formatter outputs rather than literal
    // strings so the assertions stay locale-independent.
    func testCurrencyStringUsesCurrencyDefaultPrecision() {
        let amount: Decimal = 1234
        // JPY has 0 minor-unit digits; USD has 2. currencyString must track both.
        XCTAssertEqual(amount.currencyString(code: "JPY"), amount.formatted(.currency(code: "JPY")))
        XCTAssertEqual(amount.currencyString(code: "USD"), amount.formatted(.currency(code: "USD")))
    }

    // `currencyString` (currency-default precision) and `tallyMoney` (forced display
    // precision) are intentionally different policies and must not be collapsed.
    func testCurrencyStringDivergesFromForcedDisplayPrecisionForZeroDecimalCurrency() {
        let amount: Decimal = 1234
        XCTAssertNotEqual(
            amount.currencyString(code: "JPY"),
            amount.tallyMoney(code: "JPY"),
            "JPY has no minor unit; currencyString must not force 2 fraction digits the way tallyMoney does."
        )
    }
}
