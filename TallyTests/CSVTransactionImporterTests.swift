import SwiftData
import XCTest
@testable import Tally

final class CSVTransactionImporterTests: XCTestCase {
    var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
    }

    func testDraftDetectionAndMaterialization() throws {
        let importer = CSVTransactionImporter()
        let csv = """
        Posted Date,Description,Amount,Account
        01/01/2025,Netflix,-15.49,Test Card B
        02/01/2025,Netflix,-15.49,Test Card B
        """

        let draft = try importer.makeDraft(fileName: "ledger.csv", csvText: csv)

        XCTAssertEqual(draft.suggestedMapping.dateColumn, "Posted Date")
        XCTAssertEqual(draft.suggestedMapping.amountColumn, "Amount")
        XCTAssertEqual(draft.suggestedMapping.descriptionColumn, "Description")
        XCTAssertEqual(draft.previewRows.count, 2)

        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first?.merchantRaw, "Netflix")
        XCTAssertEqual(transactions.first?.accountName, "Test Card B")
    }

    func testQuotedFieldsAndPositiveDebitConvention() throws {
        let importer = CSVTransactionImporter()
        let csv = """
        Date,Vendor,Charge
        2025-01-01,"Spotify, Family",10.99
        2025-02-01,"Spotify, Family",10.99
        """

        let draft = try importer.makeDraft(fileName: "quoted.csv", csvText: csv)
        var mapping = draft.suggestedMapping
        mapping.debitSignConvention = .positive

        let transactions = try importer.materializeTransactions(from: draft, mapping: mapping)

        XCTAssertEqual(transactions.first?.merchantRaw, "Spotify, Family")
        XCTAssertEqual(transactions.first?.transactionAmount, Decimal(string: "-10.99"))
    }

    func testQuotedFieldsSupportEscapedQuotesAndEmbeddedNewlines() throws {
        let importer = CSVTransactionImporter()
        let csv = #"""
        Date,Vendor,Amount,Memo
        2025-01-01,"Acme ""Pro""",-12.00,"Plan ""A""
        renewed"
        """#

        let draft = try importer.makeDraft(fileName: "escaped.csv", csvText: csv)
        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(transactions.count, 1)
        XCTAssertEqual(transactions.first?.merchantRaw, #"Acme "Pro""#)
        XCTAssertEqual(transactions.first?.memo, "Plan \"A\"\nrenewed")
    }

    func testParserSupportsCRLFAndSemicolonDelimitedFiles() throws {
        let importer = CSVTransactionImporter()
        let csv = [
            "Date;Merchant;Amount;Account",
            "2025-01-01;Netflix;-15.49;Test Card B",
            "2025-02-01;Spotify;-10.99;Test Card A"
        ].joined(separator: "\r\n") + "\r\n"

        let draft = try importer.makeDraft(fileName: "semicolon.csv", csvText: csv)
        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(draft.headers, ["Date", "Merchant", "Amount", "Account"])
        XCTAssertEqual(draft.suggestedMapping.amountColumn, "Amount")
        XCTAssertEqual(draft.suggestedMapping.merchantColumn, "Merchant")
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first?.merchantRaw, "Netflix")
    }

    func testDraftDetectionSupportsTransactionExportsWithStatementAndNotesColumns() throws {
        let importer = CSVTransactionImporter()
        let marketplaceNotes = """
        2 x Example Personal Care Item - $30.00

        https://example.test/orders/TALLY-ORDER-0001
        """
        let marketplaceRow = [
            "2026-02-27",
            "Example Marketplace",
            "Personal Care",
            "Test Rewards Card 0001",
            "EXAMPLE MARKETPLACE TEST BILL WA",
            "\"\(marketplaceNotes)\"",
            "-63.60",
            "Retail Sync",
            "Shared",
            ""
        ].joined(separator: ",")
        let csv = """
        Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags,Owner,Business Entity
        2026-03-13,Fictional Grocery Co-op,Groceries,Test Credit Card 0002,FICTIONAL GROCERY COOP,,-41.00,,Shared,
        \(marketplaceRow)
        """

        let draft = try importer.makeDraft(fileName: "Transactions.csv", csvText: csv)

        XCTAssertEqual(draft.suggestedMapping.dateColumn, "Date")
        XCTAssertEqual(draft.suggestedMapping.amountColumn, "Amount")
        XCTAssertEqual(draft.suggestedMapping.merchantColumn, "Merchant")
        XCTAssertEqual(draft.suggestedMapping.descriptionColumn, "Original Statement")
        XCTAssertEqual(draft.suggestedMapping.categoryColumn, "Category")
        XCTAssertEqual(draft.suggestedMapping.accountColumn, "Account")
        XCTAssertEqual(draft.previewRows.count, 2)

        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first?.merchantRaw, "Example Marketplace")
        XCTAssertEqual(transactions.first?.accountName, "Test Rewards Card 0001")
        XCTAssertEqual(transactions.first?.memo, "EXAMPLE MARKETPLACE TEST BILL WA")
        XCTAssertEqual(transactions.first?.transactionAmount, Decimal(string: "-63.60"))
    }

    func testDraftDetectionCanInferDateAndAmountColumnsFromValues() throws {
        let importer = CSVTransactionImporter()
        let csv = """
        Booked,Who,Spent,Wallet
        2025-01-01,Netflix,-15.49,Test Card B
        2025-02-01,Spotify,-10.99,Test Card A
        """

        let draft = try importer.makeDraft(fileName: "unknown-schema.csv", csvText: csv)
        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(draft.suggestedMapping.dateColumn, "Booked")
        XCTAssertEqual(draft.suggestedMapping.amountColumn, "Spent")
        XCTAssertEqual(draft.suggestedMapping.merchantColumn, "Who")
        XCTAssertEqual(draft.suggestedMapping.accountColumn, "Wallet")
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first?.merchantRaw, "Netflix")
    }

    func testPreviewValidationWarnsWhenDebitSignWouldHideCharges() throws {
        let importer = CSVTransactionImporter()
        let csv = """
        Date,Merchant,Amount
        2025-01-01,Netflix,15.49
        2025-02-01,Netflix,15.49
        """

        let draft = try importer.makeDraft(fileName: "positive-ledger.csv", csvText: csv)
        var mapping = draft.suggestedMapping
        mapping.debitSignConvention = .negative

        let validation = TabularTransactionDraftBuilder().previewValidation(for: draft, mapping: mapping)

        XCTAssertEqual(validation.parseableRowCount, 2)
        XCTAssertEqual(validation.usableMerchantRowCount, 2)
        XCTAssertEqual(validation.debitRowCount, 0)
        XCTAssertTrue(
            validation.warnings.contains {
                $0.localizedCaseInsensitiveContains("subscription detection will skip them")
            }
        )
    }

    @MainActor
    func testBulkImportCompletesForLargeMerchantSet() async throws {
        let importer = CSVTransactionImporter()
        let container = try ModelContainerFactory.makeSharedContainer(inMemoryOnly: true)
        let context = container.mainContext
        let appModel = AppModel()
        var preferences = AIProviderPreferences()
        let originalProvider = preferences.selectedKind
        preferences.selectedKind = .gemmaLocal
        defer { preferences.selectedKind = originalProvider }

        var csvLines = ["Date,Merchant,Category,Account,Original Statement,Notes,Amount,Tags"]
        for index in 0..<300 {
            let date = String(format: "2026-03-%02d", (index % 28) + 1)
            csvLines.append(
                "\(date),Merchant \(index),Software,Visa,Merchant \(index),,-\(index + 1).00,"
            )
        }

        let draft = try importer.makeDraft(fileName: "bulk.csv", csvText: csvLines.joined(separator: "\n"))
        appModel.importDraft = draft

        await appModel.commitImport(using: draft.suggestedMapping, into: context)

        XCTAssertNil(appModel.importErrorMessage)
        XCTAssertEqual(
            appModel.infoMessage,
            "Imported 300 transactions from bulk.csv. Found 0 subscriptions and 0 items to review."
        )
        XCTAssertEqual(
            appModel.classificationStatusMessage,
            """
            Used heuristic classification for 300 unique merchants
            to keep the import responsive.
            """
        )

        let transactions = try context.fetch(FetchDescriptor<NormalizedTransaction>())
        XCTAssertEqual(transactions.count, 300)

        let importRecords = try context.fetch(FetchDescriptor<ImportRecord>())
        XCTAssertEqual(importRecords.first?.importedTransactionCount, 300)
        XCTAssertEqual(importRecords.first?.detectedSubscriptionCount, 0)
        XCTAssertEqual(importRecords.first?.needsReviewSubscriptionCount, 0)
        XCTAssertEqual(importRecords.first?.status, .analyzed)
    }

    func testLargeMerchantSetUsesProviderBatchStrategy() {
        let engine = MerchantClassificationEngine()

        XCTAssertEqual(engine.strategy(forUniqueMerchantCount: 300), .providerBatch)
        XCTAssertEqual(engine.strategy(forUniqueMerchantCount: 10), .individual)
    }

    func testLargeGemmaBatchUsesProviderClassificationWhenAvailable() async {
        let intelligence = RecordingMerchantClassificationIntelligence()
        let engine = MerchantClassificationEngine(intelligence: intelligence)
        let requests = (0..<30).map { index in
            MerchantClassificationRequest(
                rawMerchant: "Merchant \(index)",
                memo: nil,
                category: "Software",
                amount: Decimal(index + 1)
            )
        }

        let result = await engine.classifyBatch(requests, strategy: .providerBatch)
        let recordedBatchSizes = await intelligence.batchSizes()

        XCTAssertEqual(result.strategyUsed, .providerBatch)
        XCTAssertEqual(result.results.count, requests.count)
        XCTAssertEqual(recordedBatchSizes, [20, 10])
        XCTAssertEqual(result.results["Merchant 0"]?.canonicalName, "Merchant 0")
    }

    func testXLSXDraftDetectionAndMaterialization() throws {
        let importer = XLSXTransactionImporter()
        let workbookURL = fixturesDirectory.appendingPathComponent("SampleImport.xlsx")

        let draft = try importer.makeDraft(fileName: "SampleImport.xlsx", fileURL: workbookURL)
        let transactions = try importer.materializeTransactions(from: draft, mapping: draft.suggestedMapping)

        XCTAssertEqual(draft.headers, ["Date", "Vendor", "Amount", "Category", "Account", "Memo"])
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(transactions.first?.merchantRaw, "Netflix")
        XCTAssertEqual(transactions.last?.merchantRaw, "Spotify")
    }

    func testXLSDraftDetectionAndMaterialization() throws {
        let importer = XLSBinaryTransactionImporter()
        let workbookURL = fixturesDirectory.appendingPathComponent("SampleImport.xls")

        let draft = try importer.makeDraft(fileName: "SampleImport.xls", fileURL: workbookURL)
        let transactions = try CSVTransactionImporter().materializeTransactions(
            from: draft,
            mapping: draft.suggestedMapping
        )

        XCTAssertEqual(draft.headers, ["Date", "Vendor", "Amount", "Category", "Account", "Memo"])
        XCTAssertEqual(transactions.count, 3)
        XCTAssertEqual(transactions.first?.merchantRaw, "Netflix")
        XCTAssertEqual(transactions.last?.merchantRaw, "Spotify")
    }

    func testMalformedXLSXReturnsReadableError() throws {
        let importer = XLSXTransactionImporter()
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xlsx")
        try Data("not a workbook".utf8).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: invalidURL) }

        XCTAssertThrowsError(
            try importer.makeDraft(fileName: invalidURL.lastPathComponent, fileURL: invalidURL)
        ) { error in
            XCTAssertEqual(error.localizedDescription, "The Excel workbook could not be opened.")
        }
    }

    func testMalformedXLSReturnsReadableError() throws {
        let importer = XLSBinaryTransactionImporter()
        let invalidURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("xls")
        try Data("not a workbook".utf8).write(to: invalidURL)
        defer { try? FileManager.default.removeItem(at: invalidURL) }

        XCTAssertThrowsError(
            try importer.makeDraft(fileName: invalidURL.lastPathComponent, fileURL: invalidURL)
        ) { error in
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testOversizedImportFailsBeforeParsingWithReadableError() throws {
        let oversizedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("csv")
        FileManager.default.createFile(atPath: oversizedURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: oversizedURL) }

        let handle = try FileHandle(forWritingTo: oversizedURL)
        try handle.truncate(atOffset: UInt64(ImportPreparationService.maxImportFileSizeBytes + 1))
        try handle.close()

        let outcome = ImportPreparationService.prepareDraft(from: oversizedURL)

        guard case let .failure(message) = outcome else {
            return XCTFail("Expected oversized import to fail")
        }
        XCTAssertTrue(message.localizedStandardContains("too large"))
        XCTAssertTrue(message.localizedStandardContains("under"))
    }
}

private actor RecordingMerchantClassificationIntelligence: MerchantClassificationIntelligence {
    private var recordedBatchSizes: [Int] = []

    func classifyMerchant(
        rawMerchant: String,
        memo: String?,
        category: String?,
        amount: Decimal
    ) async -> MerchantClassificationResult? {
        MerchantClassificationResult(
            canonicalName: rawMerchant,
            serviceCategory: category ?? "Uncategorized",
            merchantKind: .softwareOrSaaS,
            subscriptionAffinity: 0.8,
            confidence: 0.7
        )
    }

    func classifyMerchantsBatch(
        _ requests: [MerchantClassificationRequest]
    ) async -> [String: MerchantClassificationResult]? {
        recordedBatchSizes.append(requests.count)

        return Dictionary(uniqueKeysWithValues: requests.map { request in
            (
                request.rawMerchant,
                MerchantClassificationResult(
                    canonicalName: request.rawMerchant,
                    serviceCategory: request.category ?? "Uncategorized",
                    merchantKind: .softwareOrSaaS,
                    subscriptionAffinity: 0.8,
                    confidence: 0.7
                )
            )
        })
    }

    func batchSizes() -> [Int] {
        recordedBatchSizes
    }
}
