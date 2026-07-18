import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct ServiceLogoBadge: View {
    let displayName: String
    let canonicalName: String?
    let serviceIdentifier: String?
    let size: CGFloat
    let cornerRadius: CGFloat

    init(
        displayName: String,
        canonicalName: String?,
        serviceIdentifier: String? = nil,
        size: CGFloat,
        cornerRadius: CGFloat
    ) {
        self.displayName = displayName
        self.canonicalName = canonicalName
        self.serviceIdentifier = serviceIdentifier
        self.size = size
        self.cornerRadius = cornerRadius
    }

    private var assetName: String? {
        ServiceLogoDatabase.assetName(
            serviceIdentifier: serviceIdentifier,
            displayName: displayName,
            canonicalName: canonicalName
        )
    }

    private var monogram: String {
        String(displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }

    private var fallbackColor: Color {
        let seed = canonicalName?.isEmpty == false ? canonicalName ?? displayName : displayName
        let hash = abs(seed.hashValue)
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.15, brightness: 0.92)
    }

    var body: some View {
        Group {
            if let assetName {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.Colors.bgCard)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(Theme.Colors.border, lineWidth: 0.5)
                    }
                    .overlay {
                        Image(assetName)
                            .resizable()
                            .scaledToFit()
                            .padding(size * 0.18)
                    }
                    .frame(width: size, height: size)
            } else {
                Text(monogram.isEmpty ? "?" : monogram)
                    .font(.system(size: size * 0.4, weight: .semibold, design: .default))
                    .foregroundStyle(Theme.Colors.textPrimary.opacity(0.5))
                    .frame(width: size, height: size)
                    .background(
                        fallbackColor,
                        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    )
            }
        }
        .accessibilityLabel(Text(displayName))
    }
}

enum ServiceLogoDatabase {
    struct Entry {
        let assetName: String
        let aliases: [String]
    }

    static func assetName(
        serviceIdentifier: String? = nil,
        displayName: String,
        canonicalName: String?
    ) -> String? {
        resolver.assetName(
            serviceIdentifier: serviceIdentifier,
            displayName: displayName,
            canonicalName: canonicalName
        )
    }

    static func suggestedIdentifier(
        displayName: String,
        canonicalName: String?
    ) -> String? {
        assetName(
            serviceIdentifier: nil,
            displayName: displayName,
            canonicalName: canonicalName
        )
    }

    static func option(for serviceIdentifier: String?) -> ServiceIdentityOption? {
        guard let serviceIdentifier = serviceIdentifier?.nilIfBlank,
              let assetName = assetName(
                  serviceIdentifier: serviceIdentifier,
                  displayName: serviceIdentifier,
                  canonicalName: nil
              ) else {
            return nil
        }

        return ServiceIdentityOption(
            id: assetName,
            assetName: assetName,
            title: title(for: assetName)
        )
    }

    static func searchOptions(matching query: String, limit: Int = 6) -> [ServiceIdentityOption] {
        let normalizedQuery = normalize(query)
        guard normalizedQuery.isEmpty == false else {
            return []
        }

        var seen = Set<String>()

        return entries
            .compactMap { entry -> (Int, ServiceIdentityOption)? in
                guard let score = matchScore(for: entry, query: normalizedQuery) else {
                    return nil
                }

                guard seen.insert(entry.assetName).inserted else {
                    return nil
                }

                return (
                    score,
                    ServiceIdentityOption(
                        id: entry.assetName,
                        assetName: entry.assetName,
                        title: title(for: entry.assetName)
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.0 == rhs.0 {
                    return lhs.1.title < rhs.1.title
                }
                return lhs.0 < rhs.0
            }
            .prefix(limit)
            .map(\.1)
    }

    private static func platformAssetExists(named name: String) -> Bool {
        #if os(iOS)
        UIImage(named: name) != nil
        #elseif os(macOS)
        NSImage(named: NSImage.Name(name)) != nil
        #else
        false
        #endif
    }

    private static let entries: [Entry] = GeneratedServiceLogoManifest.entries
    private static let resolver = ServiceLogoResolver(
        entries: entries,
        assetExists: platformAssetExists
    )

    private static func matchScore(for entry: Entry, query: String) -> Int? {
        let aliases = entry.aliases
        if aliases.contains(query) {
            return 0
        }

        let prefixDistance = aliases
            .filter { $0.hasPrefix(query) }
            .map { $0.count - query.count }
            .min()
        if let prefixDistance {
            return 1_000 + prefixDistance
        }

        let containmentDistance = aliases
            .filter { $0.contains(query) || query.contains($0) }
            .map { abs($0.count - query.count) }
            .min()
        if let containmentDistance {
            return 2_000 + containmentDistance
        }
        if title(for: entry.assetName).lowercased().contains(query) {
            return 3_000
        }
        return nil
    }

    private static func title(for assetName: String) -> String {
        assetName
            .replacingOccurrences(of: "brand-", with: "")
            .split(separator: "-")
            .map { $0.capitalized }
            .joined(separator: " ")
    }

    static func normalize(_ rawValue: String) -> String {
        rawValue
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "",
                options: .regularExpression
            )
    }
}

final class ServiceLogoResolver: @unchecked Sendable {
    private struct ResolutionKey: Hashable {
        let serviceIdentifier: String?
        let displayName: String
        let canonicalName: String?
    }

    private enum CachedResolution {
        case found(String)
        case missing

        var assetName: String? {
            switch self {
            case let .found(assetName): assetName
            case .missing: nil
            }
        }
    }

    private let entries: [ServiceLogoDatabase.Entry]
    private let lookup: [String: String]
    private let assetExistsProbe: (String) -> Bool
    private let lock = NSLock()
    private var resolutionCache: [ResolutionKey: CachedResolution] = [:]
    private var assetExistenceCache: [String: Bool] = [:]

    init(
        entries: [ServiceLogoDatabase.Entry],
        assetExists: @escaping (String) -> Bool
    ) {
        self.entries = entries
        assetExistsProbe = assetExists

        var lookup: [String: String] = [:]
        for entry in entries {
            for alias in entry.aliases {
                lookup[alias] = entry.assetName
            }
        }
        self.lookup = lookup
    }

    func assetName(
        serviceIdentifier: String? = nil,
        displayName: String,
        canonicalName: String?
    ) -> String? {
        let key = ResolutionKey(
            serviceIdentifier: serviceIdentifier,
            displayName: displayName,
            canonicalName: canonicalName
        )

        lock.lock()
        let cached = resolutionCache[key]
        lock.unlock()
        if let cached {
            return cached.assetName
        }

        let resolved = resolveAssetName(
            serviceIdentifier: serviceIdentifier,
            displayName: displayName,
            canonicalName: canonicalName
        )

        lock.lock()
        resolutionCache[key] = resolved.map(CachedResolution.found) ?? .missing
        lock.unlock()
        return resolved
    }

    func assetExists(named name: String) -> Bool {
        lock.lock()
        let cached = assetExistenceCache[name]
        lock.unlock()
        if let cached {
            return cached
        }

        let exists = assetExistsProbe(name)
        lock.lock()
        assetExistenceCache[name] = exists
        lock.unlock()
        return exists
    }

    private func resolveAssetName(
        serviceIdentifier: String?,
        displayName: String,
        canonicalName: String?
    ) -> String? {
        if let serviceIdentifier = serviceIdentifier?.nilIfBlank {
            if let exact = lookup[serviceIdentifier] {
                return exact
            }
            if assetExists(named: serviceIdentifier) {
                return serviceIdentifier
            }
        }

        let candidates = [serviceIdentifier, canonicalName, displayName]
            .compactMap { $0 }
            .map(ServiceLogoDatabase.normalize)
            .filter { $0.isEmpty == false }

        for candidate in candidates {
            if let exact = lookup[candidate] {
                return exact
            }
        }

        for candidate in candidates {
            var bestMatch: ServiceLogoDatabase.Entry?
            var bestAliasLength = 0

            for entry in entries {
                let matchingAliasLength = entry.aliases
                    .filter { alias in
                        candidate.hasPrefix(alias) || candidate.hasSuffix(alias)
                    }
                    .map(\.count)
                    .max() ?? 0

                if matchingAliasLength > bestAliasLength {
                    bestMatch = entry
                    bestAliasLength = matchingAliasLength
                }
            }

            if let bestMatch {
                return bestMatch.assetName
            }
        }

        return nil
    }
}

struct ServiceIdentityOption: Identifiable, Hashable {
    let id: String
    let assetName: String
    let title: String
}

struct ServiceIdentityField: View {
    let title: String
    let displayName: String
    @Binding var serviceIdentifier: String
    @State private var searchText = ""

    private var selectedOption: ServiceIdentityOption? {
        ServiceLogoDatabase.option(for: serviceIdentifier)
    }

    private var customIdentifier: String? {
        let trimmedIdentifier = serviceIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedIdentifier.isEmpty == false, selectedOption == nil else {
            return nil
        }
        return trimmedIdentifier
    }

    private var searchQuery: String {
        searchText.nilIfBlank ?? displayName
    }

    private var suggestions: [ServiceIdentityOption] {
        guard selectedOption == nil, searchQuery.nilIfBlank != nil else {
            return []
        }
        return ServiceLogoDatabase.searchOptions(matching: searchQuery)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text(title)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Colors.textSecondary)

            if let selectedOption {
                HStack(spacing: Theme.Spacing.md) {
                    ServiceLogoBadge(
                        displayName: selectedOption.title,
                        canonicalName: nil,
                        serviceIdentifier: selectedOption.id,
                        size: 28,
                        cornerRadius: Theme.Radius.xs
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedOption.title)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text("Linked logo identity")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }

                    Spacer()

                    Button("Clear") {
                        serviceIdentifier = ""
                    }
                    .buttonStyle(.plain)
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.accent)
                }
                .padding(.vertical, Theme.Spacing.sm)
            } else if let customIdentifier {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    TextField("Search services or type a custom identity", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    HStack(spacing: Theme.Spacing.md) {
                        ServiceLogoBadge(
                            displayName: customIdentifier,
                            canonicalName: nil,
                            serviceIdentifier: customIdentifier,
                            size: 28,
                            cornerRadius: Theme.Radius.xs
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(customIdentifier)
                                .font(Theme.Typography.subheadline)
                                .foregroundStyle(Theme.Colors.textPrimary)
                            Text("Custom identity")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        Spacer()

                        Button("Clear") {
                            serviceIdentifier = ""
                            searchText = ""
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.accent)
                    }
                }
            } else if suggestions.isEmpty == false {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    TextField("Search services or type a custom identity", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Text("Match the service to a known identity for logos and cleaner grouping.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textTertiary)

                    ForEach(suggestions) { option in
                        Button {
                            serviceIdentifier = option.id
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                ServiceLogoBadge(
                                    displayName: option.title,
                                    canonicalName: nil,
                                    serviceIdentifier: option.id,
                                    size: 24,
                                    cornerRadius: Theme.Radius.xs
                                )
                                Text(option.title)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Spacer()
                            }
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.plain)
                    }

                    if let trimmedQuery = searchText.nilIfBlank,
                       suggestions.contains(where: {
                           $0.title.localizedCaseInsensitiveCompare(trimmedQuery) == .orderedSame
                       }) == false {
                        Button {
                            serviceIdentifier = trimmedQuery
                        } label: {
                            HStack(spacing: Theme.Spacing.md) {
                                ServiceLogoBadge(
                                    displayName: trimmedQuery,
                                    canonicalName: nil,
                                    serviceIdentifier: trimmedQuery,
                                    size: 24,
                                    cornerRadius: Theme.Radius.xs
                                )
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(trimmedQuery)
                                        .font(Theme.Typography.callout)
                                        .foregroundStyle(Theme.Colors.textPrimary)
                                    Text("Use typed identity")
                                        .font(Theme.Typography.footnote)
                                        .foregroundStyle(Theme.Colors.textTertiary)
                                }
                                Spacer()
                            }
                            .padding(.vertical, Theme.Spacing.xs)
                        }
                        .buttonStyle(.plain)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    TextField("Search services or type a custom identity", text: $searchText)
                        .textFieldStyle(.roundedBorder)

                    Text("The display name will be used directly if no known service match is selected.")
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textTertiary)

                    if let trimmedQuery = searchText.nilIfBlank {
                        Button {
                            serviceIdentifier = trimmedQuery
                        } label: {
                            Text("Use typed identity")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Colors.accent)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .onAppear {
            if searchText.isEmpty, let customIdentifier {
                searchText = customIdentifier
            }
        }
    }
}
