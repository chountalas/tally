import SwiftData
import XCTest
@testable import Tally

extension CSVTransactionImporterTests {
    @MainActor
    func testAppModelImportsOFXThroughSourceAdapterPath() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ofx")
        let text = """
        <OFX>
        <CURDEF>USD
        <BANKACCTFROM>
        <ACCTID>checking-1
        </BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260314000000
        <TRNAMT>-20.00
        <FITID>ofx-1
        <NAME>STRIPE* OPENAI
        <MEMO>ChatGPT Plus
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260414000000
        <TRNAMT>-20.00
        <FITID>ofx-2
        <NAME>STRIPE* OPENAI
        <MEMO>ChatGPT Plus
        </STMTTRN>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260514000000
        <TRNAMT>-20.00
        <FITID>ofx-3
        <NAME>STRIPE* OPENAI
        <MEMO>ChatGPT Plus
        </STMTTRN>
        </BANKTRANLIST>
        </OFX>
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        appModel.prepareImport(from: url, into: context)
        try await waitForImportPreparation(toFinish: appModel)

        let imports = try context.fetch(FetchDescriptor<ImportRecord>())
        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        let identities = try context.fetch(FetchDescriptor<SourceTransactionIdentity>())

        XCTAssertNil(appModel.importDraft)
        XCTAssertNil(appModel.importErrorMessage)
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(imports.first?.status, .analyzed)
        XCTAssertEqual(imports.first?.sourceType, "ofx")
        XCTAssertEqual(imports.first?.mappingSignature, "ofx_adapter")
        XCTAssertEqual(imports.first?.importedTransactionCount, 3)
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(identities.count, 3)
        XCTAssertTrue(identities.allSatisfy { $0.source == .ofx })
        XCTAssertEqual(Set(identities.compactMap(\.externalAccountID)), ["checking-1"])
    }

    @MainActor
    func testEmptyOFXImportFailsInsteadOfReportingSuccess() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ofx")
        let text = """
        <OFX>
        <BANKTRANLIST>
        </BANKTRANLIST>
        </OFX>
        """
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        appModel.prepareImport(from: url, into: context)
        try await waitForImportPreparation(toFinish: appModel)

        let imports = try context.fetch(FetchDescriptor<ImportRecord>())
        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())

        XCTAssertNil(appModel.importDraft)
        XCTAssertEqual(imports.count, 1)
        XCTAssertEqual(imports.first?.status, .failed)
        XCTAssertEqual(imports.first?.sourceType, "ofx")
        XCTAssertTrue(transactions.isEmpty)
        XCTAssertTrue(
            appModel.importErrorMessage?.localizedCaseInsensitiveContains("usable transactions") == true
        )
    }

    @MainActor
    func testAppModelImportsWindows1252OFXBeforeUTF16Fallbacks() async throws {
        let container = try ModelContainerFactory.makeInMemoryContainer()
        let context = container.mainContext
        let appModel = AppModel.testing()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ofx")
        let text = """
        <OFX>
        <CURDEF>USD
        <BANKACCTFROM>
        <ACCTID>checking-1
        </BANKACCTFROM>
        <BANKTRANLIST>
        <STMTTRN>
        <TRNTYPE>DEBIT
        <DTPOSTED>20260314000000
        <TRNAMT>-12.34
        <FITID>legacy-ofx-1
        <NAME>CAFÉ SERVICE
        <MEMO>Plan “Plus”
        </STMTTRN>
        </BANKTRANLIST>
        </OFX>
        """
        let data = try XCTUnwrap(text.data(using: .windowsCP1252))
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        appModel.prepareImport(from: url, into: context)
        try await waitForImportPreparation(toFinish: appModel)

        let imports = try context.fetch(FetchDescriptor<ImportRecord>())
        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())

        XCTAssertNil(appModel.importErrorMessage)
        XCTAssertEqual(imports.first?.status, .analyzed)
        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.merchantRaw, "CAFÉ SERVICE")
        XCTAssertEqual(transactions.first?.memo, "Plan “Plus”")
    }

    @MainActor
    private func waitForImportPreparation(toFinish appModel: AppModel) async throws {
        for _ in 0..<100 where appModel.isPreparingImport {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(appModel.isPreparingImport)
    }
}
