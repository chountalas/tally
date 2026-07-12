import XCTest
@testable import Tally

final class ServiceLogoResolverTests: XCTestCase {
    func testRepeatedExplicitAssetResolutionProbesCatalogOnce() {
        var probeCount = 0
        let resolver = ServiceLogoResolver(
            entries: [],
            assetExists: { _ in
                probeCount += 1
                return true
            }
        )

        let first = resolver.assetName(
            serviceIdentifier: "brand-custom",
            displayName: "Custom",
            canonicalName: nil
        )
        let second = resolver.assetName(
            serviceIdentifier: "brand-custom",
            displayName: "Custom",
            canonicalName: nil
        )

        XCTAssertEqual(first, "brand-custom")
        XCTAssertEqual(second, "brand-custom")
        XCTAssertEqual(probeCount, 1)
    }
}
