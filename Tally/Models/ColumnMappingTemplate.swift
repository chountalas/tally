import Foundation
import SwiftData

@Model
final class ColumnMappingTemplate {
    var signature: String = ""
    var dateColumn: String = ""
    var descriptionColumn: String?
    var amountColumn: String = ""
    var merchantColumn: String?
    var categoryColumn: String?
    var accountColumn: String?
    var currencyColumn: String?
    var debitSignConventionRawValue: String = DebitSign.negative.rawValue
    var createdAt: Date = Date.now

    init(config: ColumnMappingConfig, createdAt: Date = Date.now) {
        signature = config.signature
        dateColumn = config.dateColumn
        descriptionColumn = config.descriptionColumn
        amountColumn = config.amountColumn
        merchantColumn = config.merchantColumn
        categoryColumn = config.categoryColumn
        accountColumn = config.accountColumn
        currencyColumn = config.currencyColumn
        debitSignConventionRawValue = config.debitSignConvention.rawValue
        self.createdAt = createdAt
    }

    var config: ColumnMappingConfig {
        ColumnMappingConfig(
            dateColumn: dateColumn,
            descriptionColumn: descriptionColumn,
            amountColumn: amountColumn,
            merchantColumn: merchantColumn,
            categoryColumn: categoryColumn,
            accountColumn: accountColumn,
            currencyColumn: currencyColumn,
            debitSignConvention: DebitSign(rawValue: debitSignConventionRawValue) ?? .negative
        )
    }
}
