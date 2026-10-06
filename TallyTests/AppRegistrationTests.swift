import Foundation
import Testing

struct AppRegistrationTests {
    @Test
    func hostAppRegistersTallyURLScheme() throws {
        #expect(Bundle.main.bundleURL.pathExtension == "app")
        let registrations = try #require(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        )
        #expect(registrations.contains { registration in
            (registration["CFBundleURLSchemes"] as? [String])?.contains("tally") == true
        })
    }
}
