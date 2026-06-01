import SwiftData
import SwiftUI

struct AddSubscriptionSheet: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Subscription.displayName) private var subscriptions: [Subscription]

    /// When non-nil the sheet edits this subscription in place; otherwise it
    /// creates a new one.
    private let editing: Subscription?

    @State private var displayName = ""
    @State private var priceText = ""
    @State private var priceCurrency = "USD"
    @State private var selectedCadence: SubscriptionCadence = .monthly
    @State private var selectedStatus: SubscriptionStatus = .active
    @State private var lastChargeDate = Date.now
    @State private var serviceIdentifier = ""
    @State private var paymentMethodName = ""
    @State private var websiteURL = ""
    @State private var selectedReminderLeadDays: Int? = nil
    @State private var replacementSubscriptionID: UUID? = nil
    @State private var category = ""
    @State private var notes = ""
    @State private var errorMessage: String?
    @State private var suggestionSummary: String?
    @State private var isSuggestingDetails = false

    private let draftAdvisor = ManualSubscriptionDraftAdvisor()

    init(editing: Subscription? = nil) {
        self.editing = editing
        guard let editing else { return }
        _displayName = State(initialValue: editing.displayName)
        _priceText = State(initialValue: NSDecimalNumber(decimal: editing.priceAmount).stringValue)
        _priceCurrency = State(initialValue: editing.priceCurrency)
        _selectedCadence = State(initialValue: editing.cadence)
        _selectedStatus = State(initialValue: editing.status)
        _lastChargeDate = State(initialValue: editing.lastChargeDate ?? .now)
        _serviceIdentifier = State(initialValue: editing.serviceIdentifier ?? "")
        _paymentMethodName = State(initialValue: editing.paymentMethodName ?? "")
        _websiteURL = State(initialValue: editing.websiteURL ?? "")
        _selectedReminderLeadDays = State(initialValue: editing.reminderDaysBefore)
        // Never seed the editor with a self-referential replacement (possible in
        // legacy data); it would otherwise pass straight through to save.
        _replacementSubscriptionID = State(initialValue: editing.replacementSubscriptionID == editing.id ? nil : editing.replacementSubscriptionID)
        _category = State(initialValue: editing.serviceCategory ?? "")
        _notes = State(initialValue: editing.notes ?? "")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
                        Text(editing == nil ? "Add subscription" : "Edit subscription")
                            .font(Theme.Typography.displayMedium)
                            .foregroundStyle(Theme.Colors.textPrimary)

                        Spacer()

                        Button(isSuggestingDetails ? "Thinking..." : "Suggest details") {
                            suggestDetails()
                        }
                        .buttonStyle(.plain)
                        .font(Theme.Typography.callout)
                        .foregroundStyle(Theme.Colors.accent)
                        .disabled(isSuggestingDetails)
                    }

                    VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                        labeledField("Display name") {
                            TextField("Netflix", text: $displayName)
                                .textFieldStyle(.roundedBorder)
                        }

                        Text(
                            "Start with the service name and price, then let the app prefill the clean identity, category, and reminder timing."
                        )
                        .font(Theme.Typography.footnote)
                        .foregroundStyle(Theme.Colors.textTertiary)

                        ServiceIdentityField(
                            title: "Service identity",
                            displayName: displayName,
                            serviceIdentifier: $serviceIdentifier
                        )

                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            labeledField("Price") {
                                TextField("15.99", text: $priceText)
                                    .textFieldStyle(.roundedBorder)
                            }

                            labeledField("Currency") {
                                TextField("USD", text: $priceCurrency)
                                    .textFieldStyle(.roundedBorder)
                            }

                            labeledField("Cadence") {
                                Picker("Cadence", selection: $selectedCadence) {
                                    ForEach(SubscriptionCadence.allCases) { cadence in
                                        Text(cadence.rawValue.capitalized).tag(cadence)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }

                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            labeledField("Status") {
                                Picker("Status", selection: $selectedStatus) {
                                    ForEach(SubscriptionStatus.allCases) { status in
                                        Text(status.title).tag(status)
                                    }
                                }
                                .pickerStyle(.segmented)
                            }

                            labeledField("Category") {
                                TextField("Streaming", text: $category)
                                    .textFieldStyle(.roundedBorder)
                            }
                        }

                        if selectedStatus == .former, replacementOptions.isEmpty == false {
                            labeledField("Replacement") {
                                Picker("Replacement", selection: $replacementSubscriptionID) {
                                    Text("No linked replacement").tag(Optional<UUID>.none)
                                    ForEach(replacementOptions) { option in
                                        Text(option.displayName).tag(Optional(option.id))
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            Text("Link the active service that replaced this subscription so savings and lifecycle changes stay grounded.")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        labeledField("Last charged on") {
                            DatePicker(
                                "Last charged on",
                                selection: $lastChargeDate,
                                displayedComponents: .date
                            )
                            .labelsHidden()
                                .datePickerStyle(.compact)
                        }

                        HStack(alignment: .top, spacing: Theme.Spacing.md) {
                            labeledField("Payment method") {
                                TextField("Test Rewards Card", text: $paymentMethodName)
                                    .textFieldStyle(.roundedBorder)
                            }

                            labeledField("Renewal alert") {
                                Picker("Renewal alert", selection: $selectedReminderLeadDays) {
                                    Text("Default (7 days)").tag(Optional<Int>.none)
                                    Text("Same day").tag(Optional(0))
                                    Text("1 day before").tag(Optional(1))
                                    Text("3 days before").tag(Optional(3))
                                    Text("7 days before").tag(Optional(7))
                                    Text("14 days before").tag(Optional(14))
                                    Text("30 days before").tag(Optional(30))
                                }
                                .pickerStyle(.menu)
                            }
                        }

                        labeledField("Website") {
                            TextField("https://openai.com/chatgpt", text: $websiteURL)
                                .textFieldStyle(.roundedBorder)
                        }

                        if let nextChargeDate = predictedNextChargeDate {
                            Text("Next renewal preview: \(nextChargeDate.shortDateString)")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }

                        labeledField("Notes") {
                            TextEditor(text: $notes)
                                .font(Theme.Typography.body)
                                .frame(minHeight: 96)
                                .padding(Theme.Spacing.sm)
                                .background(
                                    Theme.Colors.bg,
                                    in: RoundedRectangle(cornerRadius: Theme.Radius.md)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: Theme.Radius.md)
                                        .stroke(Theme.Colors.border, lineWidth: 0.5)
                                )
                        }

                        if let suggestionSummary = suggestionSummary {
                            Text(suggestionSummary)
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textSecondary)
                        }
                    }
                    .featureCard()

                    Text(
                        "Subscriptions you add by hand live beside imported ones, so calendar, insights, and reminders stay aligned."
                    )
                    .font(Theme.Typography.footnote)
                    .foregroundStyle(Theme.Colors.textTertiary)
                }
                .padding(Theme.Spacing.xxl)
            }
            .frame(minWidth: 520, minHeight: 420)
            .background(Theme.Colors.bg)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { saveSubscription() }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.Colors.accent)
                }
            }
            .alert(
                "Add subscription",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { newValue in if !newValue { errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: selectedStatus) { _, newStatus in
                if newStatus != .former {
                    replacementSubscriptionID = nil
                }
            }
        }
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Text(title)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Colors.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func saveSubscription() {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCurrency = priceCurrency.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPaymentMethod = paymentMethodName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebsiteURL = websiteURL.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedDisplayName.isEmpty else {
            errorMessage = "Enter a display name for the subscription."
            return
        }

        guard let parsedPrice = priceText.parsedAsPrice(), parsedPrice > 0 else {
            errorMessage = "Enter a valid price greater than zero."
            return
        }

        guard trimmedCurrency.count == 3 else {
            errorMessage = "Use a three-letter currency code like USD."
            return
        }

        if trimmedWebsiteURL.isEmpty == false,
           URL(string: trimmedWebsiteURL)?.scheme?.nilIfBlank == nil {
            errorMessage = "Enter a full website URL including https://."
            return
        }

        let loweredName = trimmedDisplayName.localizedLowercase
        let editingID = editing?.id
        guard subscriptions.contains(where: {
            $0.id != editingID &&
                ($0.displayName.localizedLowercase == loweredName ||
                    $0.canonicalName.localizedLowercase == loweredName)
        }) == false else {
            errorMessage = "A subscription named \(trimmedDisplayName) already exists."
            return
        }

        let input = AppModel.ManualSubscriptionInput(
            displayName: trimmedDisplayName,
            priceAmount: parsedPrice,
            priceCurrency: trimmedCurrency,
            cadence: selectedCadence,
            status: selectedStatus,
            lastChargeDate: lastChargeDate,
            serviceIdentifier: serviceIdentifier.nilIfBlank,
            paymentMethodName: trimmedPaymentMethod.nilIfBlank,
            websiteURL: trimmedWebsiteURL.nilIfBlank,
            reminderDaysBefore: selectedReminderLeadDays,
            replacementSubscriptionID: (selectedStatus == .former && replacementSubscriptionID != editing?.id) ? replacementSubscriptionID : nil,
            category: trimmedCategory.nilIfBlank,
            notes: trimmedNotes.nilIfBlank
        )

        Task {
            do {
                if let editingID {
                    _ = try appModel.updateManualSubscription(id: editingID, input, in: modelContext)
                } else {
                    _ = try appModel.createManualSubscription(input, in: modelContext)
                }
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func suggestDetails() {
        let trimmedDisplayName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDisplayName.isEmpty == false else {
            errorMessage = "Enter a service name before asking for suggestions."
            return
        }

        isSuggestingDetails = true
        suggestionSummary = nil
        let draftInput = ManualSubscriptionDraftInput(
            displayName: trimmedDisplayName,
            priceAmount: priceText.parsedAsPrice(),
            cadence: selectedCadence,
            status: selectedStatus,
            category: category.nilIfBlank,
            notes: notes.nilIfBlank,
            websiteURL: websiteURL.nilIfBlank,
            reminderDaysBefore: selectedReminderLeadDays,
            replacementSubscriptionID: replacementSubscriptionID
        )
        let subscriptionsSnapshot = subscriptions

        Task {
            let suggestion = await draftAdvisor.suggest(
                for: draftInput,
                existingSubscriptions: subscriptionsSnapshot
            )

            await MainActor.run {
                isSuggestingDetails = false

                guard let suggestion else {
                    suggestionSummary = "No strong suggestions yet. Add a bit more detail and try again."
                    return
                }

                if serviceIdentifier.nilIfBlank == nil,
                   let serviceIdentifier = suggestion.serviceIdentifier {
                    self.serviceIdentifier = serviceIdentifier
                }

                if category.nilIfBlank == nil,
                   let category = suggestion.category {
                    self.category = category
                }

                if websiteURL.nilIfBlank == nil,
                   let websiteURL = suggestion.websiteURL {
                    self.websiteURL = websiteURL
                }

                if selectedReminderLeadDays == nil {
                    selectedReminderLeadDays = suggestion.reminderDaysBefore
                }

                if selectedStatus == .former,
                   replacementSubscriptionID == nil,
                   suggestion.replacementSubscriptionID != editing?.id {
                    replacementSubscriptionID = suggestion.replacementSubscriptionID
                }

                suggestionSummary = suggestion.summary
            }
        }
    }


    private var predictedNextChargeDate: Date? {
        selectedCadence.advance(lastChargeDate)
    }

    private var replacementOptions: [Subscription] {
        subscriptions
            .filter { candidate in
                candidate.status == .active && candidate.id != editing?.id
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }
}

struct ManualSubscriptionDraftInput: Sendable {
    let displayName: String
    let priceAmount: Decimal?
    let cadence: SubscriptionCadence
    let status: SubscriptionStatus
    let category: String?
    let notes: String?
    let websiteURL: String?
    let reminderDaysBefore: Int?
    let replacementSubscriptionID: UUID?
}

struct ManualSubscriptionDraftSuggestion: Sendable {
    let serviceIdentifier: String?
    let category: String?
    let websiteURL: String?
    let reminderDaysBefore: Int?
    let replacementSubscriptionID: UUID?
    let modelSource: String?
    let summary: String
}

@MainActor
struct ManualSubscriptionDraftAdvisor: Sendable {
    private let engine = MerchantClassificationEngine()
    private let intelligence = SubscriptionIntelligenceService()

    func suggest(
        for input: ManualSubscriptionDraftInput,
        existingSubscriptions: [Subscription]
    ) async -> ManualSubscriptionDraftSuggestion? {
        let trimmedDisplayName = input.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedDisplayName.isEmpty == false else {
            return nil
        }

        let aiClassification = await intelligence.classifyMerchant(
            rawMerchant: trimmedDisplayName,
            memo: input.notes?.nilIfBlank,
            category: input.category?.nilIfBlank,
            amount: input.priceAmount ?? .zero
        )
        let classification = if let aiClassification {
            aiClassification
        } else {
            await engine.classify(
                rawMerchant: trimmedDisplayName,
                memo: input.notes?.nilIfBlank,
                category: input.category?.nilIfBlank,
                amount: input.priceAmount ?? .zero
            )
        }

        let matchedServiceIdentifier = matchedServiceIdentifier(
            displayName: trimmedDisplayName,
            canonicalName: classification.canonicalName
        )
        let relatedSubscriptions = relatedSubscriptions(
            for: trimmedDisplayName,
            serviceIdentifier: matchedServiceIdentifier,
            existingSubscriptions: existingSubscriptions
        )

        let suggestedCategory = suggestedCategory(
            status: input.status,
            inputCategory: input.category,
            classification: classification,
            relatedSubscriptions: relatedSubscriptions,
            existingSubscriptions: existingSubscriptions
        )
        let suggestedReminderLead = suggestedReminderLead(
            inputReminderLead: input.reminderDaysBefore,
            cadence: input.cadence
        )
        let suggestedWebsite = suggestedWebsite(
            inputWebsite: input.websiteURL,
            relatedSubscriptions: relatedSubscriptions
        )
        let suggestedReplacement = suggestedReplacement(
            inputReplacementSubscriptionID: input.replacementSubscriptionID,
            status: input.status,
            category: suggestedCategory,
            existingSubscriptions: existingSubscriptions
        )

        let summary = summary(
            matchedServiceIdentifier: matchedServiceIdentifier,
            category: suggestedCategory,
            reminderDaysBefore: suggestedReminderLead,
            replacementSubscriptionID: suggestedReplacement,
            existingSubscriptions: existingSubscriptions,
            modelSource: aiClassification == nil ? nil : "Gemma"
        )

        guard matchedServiceIdentifier != nil ||
            suggestedCategory != nil ||
            suggestedWebsite != nil ||
            suggestedReminderLead != nil ||
            suggestedReplacement != nil else {
            return nil
        }

        return ManualSubscriptionDraftSuggestion(
            serviceIdentifier: matchedServiceIdentifier,
            category: suggestedCategory,
            websiteURL: suggestedWebsite,
            reminderDaysBefore: suggestedReminderLead,
            replacementSubscriptionID: suggestedReplacement,
            modelSource: aiClassification == nil ? nil : "Gemma",
            summary: summary
        )
    }

    private func matchedServiceIdentifier(
        displayName: String,
        canonicalName: String
    ) -> String? {
        if let exact = ServiceLogoDatabase.suggestedIdentifier(
            displayName: displayName,
            canonicalName: canonicalName
        ) {
            return exact
        }

        for seed in [canonicalName, displayName] {
            if let option = ServiceLogoDatabase.searchOptions(matching: seed, limit: 1).first {
                return option.id
            }
        }

        return nil
    }

    private func relatedSubscriptions(
        for displayName: String,
        serviceIdentifier: String?,
        existingSubscriptions: [Subscription]
    ) -> [Subscription] {
        let normalizedDisplayName = normalized(displayName)

        return existingSubscriptions.filter { subscription in
            if let serviceIdentifier,
               subscription.serviceIdentifier == serviceIdentifier {
                return true
            }

            return normalized(subscription.displayName) == normalizedDisplayName ||
                normalized(subscription.canonicalName) == normalizedDisplayName
        }
    }

    private func suggestedCategory(
        status: SubscriptionStatus,
        inputCategory: String?,
        classification: MerchantClassificationResult,
        relatedSubscriptions: [Subscription],
        existingSubscriptions: [Subscription]
    ) -> String? {
        if let inputCategory = inputCategory?.nilIfBlank {
            return inputCategory
        }

        if status == .former {
            let activeCategories = Array(
                Set(
                    existingSubscriptions
                        .lazy
                        .filter { $0.status == .active }
                        .compactMap { $0.serviceCategory?.nilIfBlank }
                )
            )
            .sorted()
            if activeCategories.count == 1 {
                return activeCategories.first
            }
        }

        if let relatedCategory = relatedSubscriptions.lazy.compactMap(\.serviceCategory).first(where: {
            $0.nilIfBlank != nil
        }) {
            return relatedCategory
        }

        return classification.serviceCategory.nilIfBlank
    }

    private func suggestedReminderLead(
        inputReminderLead: Int?,
        cadence: SubscriptionCadence
    ) -> Int? {
        guard inputReminderLead == nil else {
            return inputReminderLead
        }

        switch cadence {
        case .annual:
            return 30
        case .semiannual, .quarterly:
            return 14
        case .biweekly:
            return 1
        case .weekly:
            return 0
        case .monthly, .unknown:
            return nil
        }
    }

    private func suggestedWebsite(
        inputWebsite: String?,
        relatedSubscriptions: [Subscription]
    ) -> String? {
        if let inputWebsite = inputWebsite?.nilIfBlank {
            return inputWebsite
        }

        return relatedSubscriptions.lazy.compactMap(\.websiteURL).first(where: {
            $0.nilIfBlank != nil
        })
    }

    private func suggestedReplacement(
        inputReplacementSubscriptionID: UUID?,
        status: SubscriptionStatus,
        category: String?,
        existingSubscriptions: [Subscription]
    ) -> UUID? {
        guard inputReplacementSubscriptionID == nil,
              status == .former,
              let category = category?.nilIfBlank else {
            return inputReplacementSubscriptionID
        }

        let candidates = existingSubscriptions.filter {
            $0.status == .active && $0.serviceCategory == category
        }

        guard candidates.count == 1 else {
            return nil
        }

        return candidates.first?.id
    }

    private func summary(
        matchedServiceIdentifier: String?,
        category: String?,
        reminderDaysBefore: Int?,
        replacementSubscriptionID: UUID?,
        existingSubscriptions: [Subscription],
        modelSource: String?
    ) -> String {
        var parts: [String] = []

        if let modelSource {
            parts.append("\(modelSource) drafted the service match")
        }

        if let matchedServiceIdentifier,
           let option = ServiceLogoDatabase.option(for: matchedServiceIdentifier) {
            parts.append("Matched \(option.title)")
        }

        if let category {
            parts.append("set category to \(category)")
        }

        if let reminderDaysBefore {
            let reminderCopy: String
            switch reminderDaysBefore {
            case 0:
                reminderCopy = "same-day reminder"
            case 1:
                reminderCopy = "1-day reminder"
            default:
                reminderCopy = "\(reminderDaysBefore)-day reminder"
            }
            parts.append("applied a \(reminderCopy)")
        }

        if let replacementSubscriptionID,
           let replacement = existingSubscriptions.first(where: { $0.id == replacementSubscriptionID }) {
            parts.append("linked \(replacement.displayName) as the replacement")
        }

        if parts.isEmpty {
            return "No strong suggestions yet."
        }

        return parts.capitalizedSentence() + "."
    }

    private func normalized(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9]+",
                with: "",
                options: .regularExpression
            )
    }
}

private extension Array where Element == String {
    func capitalizedSentence() -> String {
        let combined = joined(separator: ", ")
        guard let first = combined.first else {
            return combined
        }
        return String(first).uppercased() + combined.dropFirst()
    }
}
