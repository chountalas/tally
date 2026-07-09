import SwiftUI
import SwiftData

struct ImportReviewSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let draft: TransactionImportDraft
    @State private var mapping: ColumnMappingConfig
    @State private var isImporting = false

    init(draft: TransactionImportDraft) {
        self.draft = draft
        _mapping = State(initialValue: draft.suggestedMapping)
    }

    private var validation: ImportMappingValidationSummary {
        TabularTransactionDraftBuilder().previewValidation(for: draft, mapping: mapping)
    }

    private var importBlockReason: String? {
        if validation.sampleRowCount == 0 {
            return "This file does not contain any rows to import."
        }
        if validation.parseableRowCount == 0 {
            return "Choose date and amount columns that produce parseable rows."
        }
        if validation.usableMerchantRowCount == 0 {
            return "Choose a merchant or description column so imported rows can be named."
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Suggested Mapping") {
                    Picker("Date Column", selection: $mapping.dateColumn) {
                        ForEach(draft.headers, id: \.self) { header in
                            Text(header).tag(header)
                        }
                    }

                    Picker("Amount Column", selection: $mapping.amountColumn) {
                        ForEach(draft.headers, id: \.self) { header in
                            Text(header).tag(header)
                        }
                    }

                    optionalPicker("Merchant Column", selection: $mapping.merchantColumn)
                    optionalPicker("Description Column", selection: $mapping.descriptionColumn)
                    optionalPicker("Category Column", selection: $mapping.categoryColumn)
                    optionalPicker("Account Column", selection: $mapping.accountColumn)
                    optionalPicker("Currency Column", selection: $mapping.currencyColumn)

                    Picker("Debit Sign", selection: $mapping.debitSignConvention) {
                        ForEach(DebitSign.allCases) { sign in
                            Text(sign.rawValue.capitalized).tag(sign)
                        }
                    }
                }

                Section("Preview") {
                    LabeledContent(
                        "Mapping Confidence",
                        value: draft.confidence.percentString
                    )
                    LabeledContent("Sampled Rows", value: "\(validation.sampleRowCount)")
                    LabeledContent("Parseable Rows", value: "\(validation.parseableRowCount)")
                    LabeledContent("Usable Merchant Rows", value: "\(validation.usableMerchantRowCount)")
                    LabeledContent("Debit Rows", value: "\(validation.debitRowCount)")
                    if validation.missingMerchantRowCount > 0 {
                        LabeledContent("Missing Merchant Rows", value: "\(validation.missingMerchantRowCount)")
                    }

                    if let importBlockReason {
                        Label {
                            Text(importBlockReason)
                                .foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }

                    if validation.warnings.isEmpty == false {
                        ForEach(validation.warnings, id: \.self) { warning in
                            Label {
                                Text(warning)
                                    .foregroundStyle(.secondary)
                            } icon: {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    ForEach(draft.previewRows) { row in
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(draft.headers, id: \.self) { header in
                                HStack(alignment: .top) {
                                    Text(header)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Text(row.values[header] ?? "—")
                                        .multilineTextAlignment(.trailing)
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .navigationTitle(draft.fileName)
            .overlay {
                if isImporting {
                    ProgressView("Importing...")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .interactiveDismissDisabled(isImporting)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        appModel.dismissImport(into: modelContext)
                        dismiss()
                    }
                    .disabled(isImporting)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Import") {
                        Task {
                            await importDraft()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isImporting || importBlockReason != nil)
                }
            }
        }
    }

    @ViewBuilder
    private func optionalPicker(_ title: String, selection: Binding<String?>) -> some View {
        Picker(title, selection: selection) {
            Text("None").tag(Optional<String>.none)
            ForEach(draft.headers, id: \.self) { header in
                Text(header).tag(Optional(header))
            }
        }
    }

    private func importDraft() async {
        guard !isImporting else {
            return
        }

        isImporting = true
        defer { isImporting = false }

        await appModel.commitImport(using: mapping, into: modelContext)
        if appModel.importDraft == nil {
            dismiss()
        }
    }
}
