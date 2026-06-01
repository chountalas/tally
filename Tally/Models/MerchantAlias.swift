import Foundation
import SwiftData

@Model
final class MerchantAlias {
    var rawMerchant: String = ""
    var canonicalName: String = ""
    var createdAt: Date = Date.now

    init(rawMerchant: String, canonicalName: String, createdAt: Date = Date.now) {
        self.rawMerchant = rawMerchant
        self.canonicalName = canonicalName
        self.createdAt = createdAt
    }
}
