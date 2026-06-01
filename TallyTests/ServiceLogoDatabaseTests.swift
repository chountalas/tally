import Testing
@testable import Tally

@Suite("Service logo database")
struct ServiceLogoDatabaseTests {
    @Test func matchesKnownServiceByDisplayName() {
        #expect(
            ServiceLogoDatabase.assetName(displayName: "Netflix", canonicalName: nil) == "brand-netflix"
        )
    }

    @Test func matchesKnownServiceByCanonicalNameWhenDisplayNameChanges() {
        #expect(
            ServiceLogoDatabase.assetName(
                displayName: "Family Streaming",
                canonicalName: "spotify"
            ) == "brand-spotify"
        )
    }

    @Test func matchesAliasesWithPunctuationAndSuffixes() {
        #expect(
            ServiceLogoDatabase.assetName(
                displayName: "YouTube Premium Family",
                canonicalName: nil
            ) == "brand-youtube"
        )
        #expect(
            ServiceLogoDatabase.assetName(
                displayName: "HBO Max",
                canonicalName: nil
            ) == "brand-hbomax"
        )
    }

    @Test func matchesOpenAIAndChatGPTAliases() {
        #expect(
            ServiceLogoDatabase.assetName(
                displayName: "OpenAI",
                canonicalName: nil
            ) == "brand-openai"
        )
        #expect(
            ServiceLogoDatabase.assetName(
                displayName: "ChatGPT Plus",
                canonicalName: nil
            ) == "brand-openai"
        )
    }

    @Test func prefersExplicitServiceIdentifierAndSurfacesSuggestions() {
        #expect(
            ServiceLogoDatabase.assetName(
                serviceIdentifier: "brand-netflix",
                displayName: "Family Streaming",
                canonicalName: nil
            ) == "brand-netflix"
        )

        let suggestions = ServiceLogoDatabase.searchOptions(matching: "netflix")
        #expect(suggestions.contains(where: { $0.assetName == "brand-netflix" }))
    }

    @Test func suggestedIdentifierUsesResolvedBrandAsset() {
        #expect(
            ServiceLogoDatabase.suggestedIdentifier(
                displayName: "ChatGPT Plus",
                canonicalName: "ChatGPT"
            ) == "brand-openai"
        )
    }

    @Test func returnsNilForUnknownService() {
        #expect(
            ServiceLogoDatabase.assetName(displayName: "Neighborhood Gym", canonicalName: nil) == nil
        )
    }
}
