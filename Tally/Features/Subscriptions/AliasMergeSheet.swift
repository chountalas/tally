import SwiftData
import SwiftUI

struct AliasMergeSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \MerchantAlias.rawMerchant) private var allAliases: [MerchantAlias]
    @Query(sort: \NormalizedTransaction.merchantRaw) private var transactions: [NormalizedTransaction]

    let canonicalName: String
    let subscriptionID: UUID

    @State private var newAliasText = ""
    @State private var isApplyingChange = false
    @State private var actionMessage: String?

    private var linkedAliases: [MerchantAlias] {
        allAliases.filter { $0.canonicalName == canonicalName }
    }

    private var linkedRawMerchants: [String] {
        Array(Set(
            transactions.filter { $0.subscriptionID == subscriptionID }.map(\.merchantRaw)
        )).sorted()
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(linkedRawMerchants, id: \.self) { raw in
                        HStack {
                            Text(raw)
                                .font(Theme.Typography.body)
                            Spacer()
                            if linkedAliases.contains(where: { $0.rawMerchant == raw }) {
                                Text("aliased")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.accent)
                            }
                        }
                    }
                } header: {
                    Text("Raw merchant strings")
                }

                Section {
                    ForEach(linkedAliases) { alias in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(alias.rawMerchant)
                                    .font(Theme.Typography.body)
                                Text("\u{2192} \(alias.canonicalName)")
                                    .font(Theme.Typography.caption)
                                    .foregroundStyle(Theme.Colors.muted)
                            }
                            Spacer()
                        }
                    }
                    .onDelete(perform: removeAliases)
                } header: {
                    Text("Active aliases")
                }

                Section {
                    HStack {
                        TextField("Raw merchant string", text: $newAliasText)
                        Button("Add") {
                            addAlias()
                        }
                        .disabled(newAliasText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: {
                    Text("Add alias")
                }
            }
            .navigationTitle("Merchant Aliases")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if isApplyingChange {
                    ProgressView("Refreshing merchant history...")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .alert(
                "Merchant aliases",
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
        }
    }

    private func addAlias() {
        let trimmed = newAliasText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        Task {
            do {
                isApplyingChange = true
                defer { isApplyingChange = false }
                actionMessage = try await appModel.applyAliasDraft(
                    rawMerchant: trimmed,
                    canonicalName: canonicalName,
                    in: modelContext
                )
                newAliasText = ""
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }

    private func removeAliases(at offsets: IndexSet) {
        let rawMerchants = offsets.map { linkedAliases[$0].rawMerchant }
        Task {
            do {
                isApplyingChange = true
                defer { isApplyingChange = false }
                actionMessage = try await appModel.removeAliases(
                    rawMerchants: rawMerchants,
                    in: modelContext
                )
            } catch {
                actionMessage = error.localizedDescription
            }
        }
    }
}
