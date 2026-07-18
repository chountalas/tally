import SwiftData
import SwiftUI

struct SubscriptionCopilotSheet: View {
    @Environment(AppModel.self) var appModel
    @Environment(\.dismiss) var dismiss
    @Environment(\.modelContext) var modelContext
    @Query(sort: \Subscription.displayName) var subscriptions: [Subscription]
    @Query(
        sort: \NormalizedTransaction.transactionDate,
        order: .reverse
    ) var transactions: [NormalizedTransaction]
    @Query var aliases: [MerchantAlias]
    @Query var classifications: [MerchantClassification]

    let seedQuery: IntelligenceQuery?
    let suggestionQueries: [IntelligenceQuery]

    @State var promptText = ""
    @State var response: IntelligenceResponse?
    @State var isLoading = false
    @State var activeQueryKey: String?
    @State var actionMessage: String?
    @State var pendingAction: IntelligenceActionSuggestion?

    let intelligenceTask: Task<SubscriptionIntelligenceService, Never>

    init(
        seedQuery: IntelligenceQuery? = nil,
        suggestionQueries: [IntelligenceQuery] = SubscriptionCopilotSheet.defaultSuggestions
    ) {
        self.seedQuery = seedQuery
        self.suggestionQueries = suggestionQueries
        intelligenceTask = Task.detached(priority: .userInitiated) {
            SubscriptionIntelligenceService()
        }
        _promptText = State(initialValue: seedQuery?.prompt ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.section) {
                    headerSection

                    composerSection

                    suggestionsSection

                    if let response {
                        responseSection(response)
                    } else if isLoading {
                        loadingSection
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: Theme.Layout.contentMaxWidth, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.xxl)
                .padding(.vertical, Theme.Spacing.xl)
            }
            .background(Theme.Colors.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert(
                "Copilot Action",
                isPresented: Binding(
                    get: { actionMessage != nil },
                    set: { newValue in
                        if !newValue {
                            actionMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    actionMessage = nil
                }
            } message: {
                Text(actionMessage ?? "")
            }
            .confirmationDialog(
                pendingAction?.title ?? "Confirm action",
                isPresented: Binding(
                    get: { pendingAction != nil },
                    set: { newValue in
                        if !newValue {
                            pendingAction = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                Button("Apply") {
                    guard let pendingAction else { return }
                    apply(action: pendingAction)
                }
                Button("Cancel", role: .cancel) {
                    pendingAction = nil
                }
            }
        }
    }
}
