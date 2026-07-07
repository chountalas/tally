import SwiftData
import SwiftUI

extension SubscriptionCopilotSheet {
    var tooling: LocalSubscriptionIntelligenceTooling {
        LocalSubscriptionIntelligenceTooling(
            subscriptions: subscriptions,
            transactions: transactions,
            aliases: aliases,
            classifications: classifications
        )
    }

    var availableSuggestions: [IntelligenceQuery] {
        if let seedQuery {
            return [seedQuery] + suggestionQueries.filter { $0.prompt != seedQuery.prompt }
        }
        return suggestionQueries
    }

    var headerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text("Local subscription copilot")
                .font(Theme.Typography.displayMedium)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(
                """
                Answers stay grounded in your on-device SwiftData library and propose only
                deterministic, confirmable actions.
                """
            )
            .font(Theme.Typography.callout)
            .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    var composerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            TextEditor(text: $promptText)
                .font(Theme.Typography.body)
                .frame(minHeight: 96)
                .padding(Theme.Spacing.sm)
                .background(Theme.Colors.bgCard, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .stroke(Theme.Colors.border, lineWidth: 0.5)
                )

            HStack {
                Text(
                    "Try questions about renewals, cancellations, price changes, or merchant cleanup."
                )
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Colors.textTertiary)

                Spacer()

                Button(isLoading ? "Thinking..." : "Ask") {
                    Task {
                        await run(
                            query: IntelligenceQuery(
                                kind: .custom,
                                prompt: promptText.trimmingCharacters(in: .whitespacesAndNewlines),
                                subscriptionID: seedQuery?.subscriptionID,
                                merchantName: seedQuery?.merchantName,
                                rawMerchant: seedQuery?.rawMerchant
                            )
                        )
                    }
                }
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.accent)
                .buttonStyle(.plain)
                .disabled(
                    isLoading ||
                        promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
    }

    var loadingSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ProgressView()
            Text("Inspecting the local library and building a grounded answer.")
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
        .featureCard()
    }

    var suggestionsSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Starter prompts")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(availableSuggestions.enumerated()), id: \.element.id) { index, query in
                    Button {
                        promptText = query.prompt
                        Task {
                            await run(query: query)
                        }
                    } label: {
                        HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                                Text(query.prompt)
                                    .font(Theme.Typography.callout)
                                    .foregroundStyle(Theme.Colors.textPrimary)
                                Text(query.kind.rawValue.replacingOccurrences(of: "([A-Z])", with: " $1", options: .regularExpression).capitalized)
                                    .font(Theme.Typography.footnote)
                                    .foregroundStyle(Theme.Colors.textTertiary)
                            }

                            Spacer()

                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .padding(.vertical, Theme.Spacing.md)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)

                    if index < availableSuggestions.count - 1 {
                        HairlineDivider()
                    }
                }
            }
        }
        .featureCard()
    }

    var emptyState: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Text("Ask a question to inspect your library.")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(
                """
                The copilot will cite local subscriptions and transactions and only
                suggest actions it can apply deterministically after confirmation.
                """
            )
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Colors.textTertiary)
        }
        .featureCard()
    }

    func responseSection(_ response: IntelligenceResponse) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
            responseHeader(for: response)

            if response.evidence.isEmpty == false {
                evidenceSection(response.evidence)
            }

            if response.actions.isEmpty == false {
                actionsSection(response.actions)
            }

            if response.followUps.isEmpty == false {
                followUpsSection(response.followUps)
            }

            confidenceSection(for: response)
        }
        .featureCard()
    }

    func responseHeader(for response: IntelligenceResponse) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(response.headline)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Text(response.summary)
                .font(Theme.Typography.callout)
                .foregroundStyle(Theme.Colors.textSecondary)
        }
    }

    func evidenceSection(_ evidence: [EvidenceReference]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Evidence")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)

            ForEach(evidence) { entry in
                HStack(alignment: .top, spacing: Theme.Spacing.sm) {
                    Image(systemName: icon(for: entry.kind))
                        .foregroundStyle(Theme.Colors.textTertiary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.label)
                            .font(Theme.Typography.subheadline)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Text(entry.snippet)
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Colors.textTertiary)
                    }
                }
            }
        }
    }

    func actionsSection(_ actions: [IntelligenceActionSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Suggested actions")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)

            ForEach(actions) { action in
                Button {
                    if action.requiresConfirmation {
                        pendingAction = action
                    } else {
                        apply(action: action)
                    }
                } label: {
                    HStack {
                        Text(action.title)
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.textPrimary)
                        Spacer()
                        Image(
                            systemName: action.requiresConfirmation
                                ? "checkmark.shield"
                                : "arrow.right"
                        )
                        .foregroundStyle(Theme.Colors.textTertiary)
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .buttonStyle(.plain)
            }
        }
    }

    func followUpsSection(_ prompts: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("Follow-ups")
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)

            VStack(spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    Button {
                        promptText = prompt
                        Task {
                            await run(
                                query: IntelligenceQuery(
                                    kind: .custom,
                                    prompt: prompt,
                                    subscriptionID: seedQuery?.subscriptionID,
                                    merchantName: seedQuery?.merchantName,
                                    rawMerchant: seedQuery?.rawMerchant
                                )
                            )
                        }
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            Text(prompt)
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Colors.accent)
                                .multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .padding(.vertical, Theme.Spacing.sm)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)

                    if index < prompts.count - 1 {
                        HairlineDivider()
                    }
                }
            }
        }
    }

    func confidenceSection(for response: IntelligenceResponse) -> some View {
        Text("Confidence \(Int(response.confidence * 100))%")
            .font(Theme.Typography.footnote)
            .foregroundStyle(Theme.Colors.textTertiary)
    }

    func run(query: IntelligenceQuery) async {
        guard let resolvedQuery = resolvedQuery(from: query) else {
            return
        }

        let queryKey = normalizedQueryKey(for: resolvedQuery)
        guard isLoading == false, activeQueryKey != queryKey else {
            return
        }

        activeQueryKey = queryKey
        isLoading = true
        defer {
            isLoading = false
            activeQueryKey = nil
        }

        let intelligence = await intelligenceTask.value
        response = await intelligence.respond(to: resolvedQuery, using: tooling)
    }

    func resolvedQuery(from query: IntelligenceQuery) -> IntelligenceQuery? {
        let trimmedPrompt = query.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.isEmpty == false else {
            return nil
        }

        return IntelligenceQuery(
            kind: query.kind,
            prompt: trimmedPrompt,
            subscriptionID: query.subscriptionID,
            merchantName: query.merchantName,
            rawMerchant: query.rawMerchant,
            days: query.days
        )
    }

    func normalizedQueryKey(for query: IntelligenceQuery) -> String {
        [
            query.kind.rawValue,
            query.prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            query.subscriptionID?.uuidString ?? "none",
            query.merchantName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "none",
            query.rawMerchant?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "none",
            "\(query.days ?? 0)"
        ].joined(separator: "|")
    }

    func apply(action: IntelligenceActionSuggestion) {
        defer { pendingAction = nil }

        switch action.kind {
        case .openSubscription:
            guard let rawID = action.payload["subscriptionID"],
                  let subscriptionID = UUID(uuidString: rawID) else {
                actionMessage = "The suggested subscription could not be opened."
                return
            }
            appModel.openSubscription(subscriptionID)
            dismiss()
        case .openTab:
            guard let routeRawValue = action.payload["route"],
                  let route = IntelligenceNavigationRoute(rawValue: routeRawValue) else {
                actionMessage = "The suggested screen could not be opened."
                return
            }
            appModel.openRoute(route)
            dismiss()
        case .createAliasDraft:
            guard let rawMerchant = action.payload["rawMerchant"]?.nilIfBlank,
                  let canonicalName = action.payload["canonicalName"]?.nilIfBlank else {
                actionMessage = "The alias suggestion was incomplete."
                return
            }
            applyAlias(rawMerchant: rawMerchant, canonicalName: canonicalName)
        case .draftReviewUpdate:
            guard let rawID = action.payload["subscriptionID"],
                  let subscriptionID = UUID(uuidString: rawID) else {
                actionMessage = "The review update was incomplete."
                return
            }
            applyReviewUpdate(subscriptionID: subscriptionID, fields: action.payload)
        }
    }

    func applyAlias(rawMerchant: String, canonicalName: String) {
        Task {
            do {
                actionMessage = try await appModel.applyAliasDraft(
                    rawMerchant: rawMerchant,
                    canonicalName: canonicalName,
                    in: modelContext
                )
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func applyReviewUpdate(subscriptionID: UUID, fields: [String: String]) {
        Task {
            do {
                actionMessage = try await appModel.applyReviewUpdate(
                    subscriptionID: subscriptionID,
                    fields: fields,
                    in: modelContext
                )
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    func icon(for kind: IntelligenceEvidenceKind) -> String {
        switch kind {
        case .subscription:
            return "creditcard"
        case .transaction:
            return "arrow.left.arrow.right"
        case .merchant:
            return "tag"
        case .renewal:
            return "calendar"
        case .overlap:
            return "square.stack.3d.up"
        }
    }

    static let defaultSuggestions: [IntelligenceQuery] = [
        IntelligenceQuery(kind: .savingsReview, prompt: "What can I cancel?"),
        IntelligenceQuery(
            kind: .upcomingRenewals,
            prompt: "What renews in the next 30 days?",
            days: 30
        ),
        IntelligenceQuery(
            kind: .priceChangeExplanation,
            prompt: "Why did this subscription change?"
        ),
        IntelligenceQuery(
            kind: .merchantFix,
            prompt: "Fix this merchant / create alias"
        )
    ]
}

struct FlexibleChipLayout<Item, Content>: View where Item: Hashable, Content: View {
    let items: [Item]
    let itemTitle: (Item) -> String
    @ViewBuilder let content: (Item) -> Content

    var body: some View {
        let rows = buildRows()

        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: Theme.Spacing.sm) {
                    ForEach(row, id: \.self) { item in
                        content(item)
                    }
                }
            }
        }
    }

    private func buildRows() -> [[Item]] {
        var rows: [[Item]] = [[]]
        var currentCharacterCount = 0

        for item in items {
            let itemLength = itemTitle(item).count
            if currentCharacterCount + itemLength > 34 {
                rows.append([item])
                currentCharacterCount = itemLength
            } else {
                rows[rows.count - 1].append(item)
                currentCharacterCount += itemLength
            }
        }

        return rows.filter { $0.isEmpty == false }
    }
}
