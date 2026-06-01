import XCTest
@testable import Tally

final class BankFeedTransactionAdapterTests: XCTestCase {
    func testOFXAdapterProducesSourceDrafts() async throws {
        let text = """
        <OFX>
        <CURDEF>USD
        <BANKACCTFROM>
        <ACCTID>checking-1
        </BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260514000000
        <TRNAMT>-20.00
        <FITID>ofx-1
        <NAME>STRIPE* OPENAI
        <MEMO>ChatGPT Plus
        </STMTTRN>
        </BANKTRANLIST>
        </OFX>
        """

        let drafts = try await OFXTransactionSourceAdapter(text: text).prepareTransactions()

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].source, .ofx)
        XCTAssertEqual(drafts[0].externalTransactionID, "ofx-1")
        XCTAssertEqual(drafts[0].externalAccountID, "checking-1")
        XCTAssertEqual(drafts[0].seed.merchantRaw, "STRIPE* OPENAI")
        XCTAssertEqual(drafts[0].seed.transactionAmount, Decimal(string: "-20.00"))
        XCTAssertEqual(drafts[0].seed.currency, "USD")
    }

    func testOFXAdapterParsesSgmlStyleTransactionsWithoutClosingStatementTags() async throws {
        let text = """
        <OFX>
        <CURDEF>USD
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260514000000
        <TRNAMT>-20.00
        <FITID>ofx-1
        <NAME>STRIPE* OPENAI
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260614000000
        <TRNAMT>-20.00
        <FITID>ofx-2
        <NAME>STRIPE* OPENAI
        </BANKTRANLIST>
        </OFX>
        """

        let drafts = try await OFXTransactionSourceAdapter(text: text).prepareTransactions()

        XCTAssertEqual(drafts.count, 2)
        XCTAssertEqual(drafts.map(\.externalTransactionID), ["ofx-1", "ofx-2"])
    }

    func testSimpleFINAdapterProducesSourceDrafts() async throws {
        let json = """
        {
          "accounts": [
            {
              "id": "acct-1",
              "name": "Visa",
              "currency": "USD",
              "transactions": [
                {
                  "id": "txn-1",
                  "posted": 1781395200,
                  "amount": "-14.99",
                  "description": "Netflix",
                  "memo": "Standard plan",
                  "pending": false
                }
              ]
            }
          ]
        }
        """

        let drafts = try await SimpleFINTransactionSourceAdapter(
            data: Data(json.utf8)
        ).prepareTransactions()

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].source, .simpleFIN)
        XCTAssertEqual(drafts[0].externalTransactionID, "txn-1")
        XCTAssertEqual(drafts[0].externalAccountID, "acct-1")
        XCTAssertEqual(drafts[0].status, .posted)
        XCTAssertEqual(drafts[0].seed.accountName, "Visa")
        XCTAssertEqual(drafts[0].seed.merchantRaw, "Netflix")
        XCTAssertEqual(drafts[0].seed.transactionAmount, Decimal(string: "-14.99"))
    }

    func testSimpleFINAdapterMarksPendingDraftsExplicitly() async throws {
        let json = """
        {
          "accounts": [
            {
              "id": "acct-1",
              "name": "Visa",
              "currency": "USD",
              "transactions": [
                {
                  "id": "pending-1",
                  "posted": 1781395200,
                  "amount": "-14.99",
                  "description": "Netflix",
                  "memo": "Standard plan",
                  "pending": true
                }
              ]
            }
          ]
        }
        """

        let drafts = try await SimpleFINTransactionSourceAdapter(
            data: Data(json.utf8)
        ).prepareTransactions()

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].status, .pending)
        XCTAssertEqual(drafts[0].pendingExternalTransactionID, "pending-1")
    }

    func testSimpleFINPendingTransactionUsesTransactedAtWhenPostedIsZero() async throws {
        let json = """
        {
          "accounts": [
            {
              "id": "acct-1",
              "name": "Visa",
              "currency": "USD",
              "transactions": [
                {
                  "id": "pending-1",
                  "posted": 0,
                  "transacted_at": 1781308800,
                  "amount": "-14.99",
                  "description": "Netflix",
                  "memo": "Standard plan",
                  "pending": true
                }
              ]
            }
          ]
        }
        """

        let drafts = try await SimpleFINTransactionSourceAdapter(
            data: Data(json.utf8)
        ).prepareTransactions()

        XCTAssertEqual(drafts.count, 1)
        XCTAssertEqual(drafts[0].status, .pending)
        XCTAssertEqual(drafts[0].seed.transactionDate, Date(timeIntervalSince1970: 1_781_308_800))
        XCTAssertNotEqual(drafts[0].seed.transactionDate, Date(timeIntervalSince1970: 0))
    }

    func testSimpleFINPendingTransactionWithZeroPostedAndNoTransactedAtIsSkipped() async throws {
        let json = """
        {
          "accounts": [
            {
              "id": "acct-1",
              "name": "Visa",
              "currency": "USD",
              "transactions": [
                {
                  "id": "pending-1",
                  "posted": 0,
                  "amount": "-14.99",
                  "description": "Netflix",
                  "memo": "Standard plan",
                  "pending": true
                }
              ]
            }
          ]
        }
        """

        let drafts = try await SimpleFINTransactionSourceAdapter(
            data: Data(json.utf8)
        ).prepareTransactions()

        XCTAssertTrue(drafts.isEmpty)
    }
}
