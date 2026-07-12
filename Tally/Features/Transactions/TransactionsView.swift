import SwiftData
import SwiftUI
import UniformTypeIdentifiers

struct TransactionsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.modelContext) private var modelContext

    @State private var isPresentingImporter = false
    @State private var searchText = ""
    @State private var effectiveSearchText = ""
    @State private var visibleLimit = 100
    @State private var transactions: [NormalizedTransaction] = []
    @State private var totalTransactionCount = 0
    @State private var matchedTransactionCount = 0
    @State private var isLoadingTransactions = true
    @State private var transactionLoadError: String?
    @State private var isShowingCopilot = false
    @State private var isConfirmingDataClear = false
    @State private var dataOperationMessage: String?

    private let pageSize = 100

    private var pageRequest: TransactionPageRequest {
        TransactionPageRequest(
            searchText: effectiveSearchText,
            limit: visibleLimit,
            libraryGeneration: appModel.libraryRevision.generation
        )
    }

    var body: some View {
        @Bindable var appModel = appModel
        let remainingTransactionCount = max(0, matchedTransactionCount - transactions.count)

        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialPageHeader(
                        eyebrow: "\(totalTransactionCount) imported",
                        title: "Transactions",
                        subtitle: "The raw statement layer behind every detected subscription and merchant decision."
                    ) {
                        HStack(spacing: Theme.Spacing.lg) {
                            EditorialActionButton(title: "Sample", systemImage: "shippingbox") {
                                Task { await appModel.seedSampleDataIfNeeded(context: modelContext) }
                            }

                            EditorialActionButton(
                                title: "Import",
                                systemImage: "tray.and.arrow.down",
                                tone: .primary,
                                isDisabled: appModel.isPreparingImport
                            ) {
                                isPresentingImporter = true
                            }

                            EditorialActionButton(
                                title: "Clear",
                                systemImage: "trash",
                                tone: .destructive,
                                isDisabled: totalTransactionCount == 0 || appModel.isPreparingImport
                            ) {
                                isConfirmingDataClear = true
                            }

                            EditorialActionButton(title: "Ask", systemImage: "sparkle.magnifyingglass") {
                                isShowingCopilot = true
                            }
                        }
                    }
                    .padding(.bottom, Theme.Spacing.xxl)

                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(Theme.Colors.textTertiary)
                        TextField("Search merchants, categories, or notes", text: $searchText)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.callout)
                    }
                    .padding(Theme.Spacing.md)
                    .background(Theme.Colors.bgInset, in: RoundedRectangle(cornerRadius: Theme.Radius.md))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.md)
                            .stroke(Theme.Colors.border, lineWidth: 0.5)
                    )
                    .padding(.bottom, Theme.Spacing.xxl)

                    // Content
                    if isLoadingTransactions, transactions.isEmpty {
                        ProgressView("Loading transactions…")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.section)
                    } else if transactions.isEmpty {
                        VStack(spacing: Theme.Spacing.md) {
                            Image(systemName: effectiveSearchText.isEmpty ? "tray.full" : "magnifyingglass")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text(effectiveSearchText.isEmpty ? "No imported transactions" : "No matching transactions")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text(
                                effectiveSearchText.isEmpty
                                    ? "Import a CSV, Excel, OFX, or QFX file, or load sample data."
                                    : "Try a different merchant, category, or note."
                            )
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.section)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(transactions) { transaction in
                                NavigationLink {
                                    MerchantTransactionsView(
                                        merchantName: transaction.merchantNormalized
                                    )
                                } label: {
                                    TransactionRow(transaction: transaction)
                                }
                                .buttonStyle(.plain)

                                if transaction.id != transactions.last?.id {
                                    HairlineDivider()
                                        .padding(.leading, Theme.Spacing.md)
                                }
                            }

                            if remainingTransactionCount > 0 {
                                Button {
                                    visibleLimit += pageSize
                                } label: {
                                    HStack {
                                        Text("Show \(min(pageSize, remainingTransactionCount)) more")
                                            .font(Theme.Typography.footnote)
                                            .foregroundStyle(Theme.Colors.accent)
                                        Spacer()
                                        Text("\(remainingTransactionCount) remaining")
                                            .font(Theme.Typography.footnote)
                                            .foregroundStyle(Theme.Colors.textTertiary)
                                    }
                                    .padding(Theme.Spacing.md)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .featureCard()
                    }
                }
                .editorialPage()
            }
            .background(Theme.Colors.bg)
            .task(id: searchText) {
                let nextSearchText = searchText
                try? await Task.sleep(nanoseconds: 180_000_000)
                guard Task.isCancelled == false else { return }
                effectiveSearchText = nextSearchText
                visibleLimit = pageSize
            }
            .task(id: pageRequest) {
                loadTransactionPage()
            }
            .overlay {
                if appModel.isPreparingImport {
                    ProgressView("Preparing import...")
                        .padding(.horizontal, Theme.Spacing.xl)
                        .padding(.vertical, Theme.Spacing.lg)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.lg))
                }
            }
            .fileImporter(
                isPresented: $isPresentingImporter,
                allowedContentTypes: supportedImportTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    appModel.prepareImport(from: url, into: modelContext)
                case let .failure(error):
                    appModel.importErrorMessage = error.localizedDescription
                }
            }
            .sheet(isPresented: $isShowingCopilot) {
                SubscriptionCopilotSheet(
                    title: "Ask from Transactions",
                    seedQuery: searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? nil
                        : IntelligenceQuery(
                            kind: .merchantFix,
                            prompt: "Fix this merchant / create alias",
                            merchantName: searchText,
                            rawMerchant: searchText
                        )
                )
            }
            .alert("Clear imported data?", isPresented: $isConfirmingDataClear) {
                Button("Clear data", role: .destructive) {
                    Task {
                        await clearImportedData()
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    """
                    This removes the imported transactions, subscriptions,
                    aliases, and review rules for the current library so you
                    can import a fresh statement file.
                    """
                )
            }
            .alert(
                "Library reset",
                isPresented: Binding(
                    get: { dataOperationMessage != nil },
                    set: { newValue in
                        if !newValue { dataOperationMessage = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) { dataOperationMessage = nil }
            } message: {
                Text(dataOperationMessage ?? "")
            }
            .alert(
                "Couldn’t load transactions",
                isPresented: Binding(
                    get: { transactionLoadError != nil },
                    set: { isPresented in
                        if isPresented == false { transactionLoadError = nil }
                    }
                )
            ) {
                Button("OK", role: .cancel) { transactionLoadError = nil }
            } message: {
                Text(transactionLoadError ?? "")
            }
        }
    }

    private var supportedImportTypes: [UTType] {
        var types: [UTType] = [.commaSeparatedText, .text]
        if let xls = UTType(filenameExtension: "xls") { types.append(xls) }
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let ofx = UTType(filenameExtension: "ofx") { types.append(ofx) }
        if let qfx = UTType(filenameExtension: "qfx") { types.append(qfx) }
        return types
    }

    private func clearImportedData() async {
        do {
            let summary = try appModel.clearImportedLibrary(in: modelContext)
            dataOperationMessage = summary.importedDataMessage
        } catch {
            dataOperationMessage = error.localizedDescription
        }
    }

    private func loadTransactionPage() {
        isLoadingTransactions = true
        transactionLoadError = nil
        do {
            let page = try TransactionPageLoader().load(
                in: modelContext,
                searchText: effectiveSearchText,
                limit: visibleLimit
            )
            transactions = page.transactions
            totalTransactionCount = page.totalCount
            matchedTransactionCount = page.matchedCount
        } catch {
            transactionLoadError = error.localizedDescription
        }
        isLoadingTransactions = false
    }

}

private struct TransactionPageRequest: Hashable {
    let searchText: String
    let limit: Int
    let libraryGeneration: UInt64
}

private struct MerchantTransactionsView: View {
    let merchantName: String
    @Query private var transactions: [NormalizedTransaction]
    @State private var isShowingCopilot = false

    init(merchantName: String) {
        self.merchantName = merchantName
        let targetMerchantName = merchantName
        _transactions = Query(
            filter: #Predicate<NormalizedTransaction> { transaction in
                transaction.merchantNormalized == targetMerchantName
            },
            sort: \.transactionDate,
            order: .reverse
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                HStack(alignment: .firstTextBaseline) {
                    Text(merchantName)
                        .font(Theme.Typography.displayMedium)
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Spacer()
                    Button("Ask") {
                        isShowingCopilot = true
                    }
                    .font(Theme.Typography.callout)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .buttonStyle(.plain)
                }

                if transactions.isEmpty {
                    VStack(spacing: Theme.Spacing.md) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(Theme.Colors.textTertiary)
                        Text("No transactions for this merchant")
                            .font(Theme.Typography.callout)
                            .foregroundStyle(Theme.Colors.textSecondary)
                        Text("Charges from \(merchantName) will appear here once they're imported.")
                            .font(Theme.Typography.footnote)
                            .foregroundStyle(Theme.Colors.textTertiary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Theme.Spacing.section)
                } else {
                    VStack(spacing: 0) {
                        ForEach(transactions) { transaction in
                            TransactionRow(transaction: transaction)
                            if transaction.id != transactions.last?.id {
                                HairlineDivider()
                            }
                        }
                    }
                    .featureCard()
                }
            }
            .padding(.horizontal, Theme.Spacing.xxl)
            .padding(.vertical, Theme.Spacing.xl)
        }
        .background(Theme.Colors.bg)
        .navigationTitle(merchantName)
        .sheet(isPresented: $isShowingCopilot) {
            SubscriptionCopilotSheet(
                title: "Fix \(merchantName)",
                seedQuery: IntelligenceQuery(
                    kind: .merchantFix,
                    prompt: "Fix this merchant / create alias",
                    merchantName: merchantName,
                    rawMerchant: transactions.first?.merchantRaw ?? merchantName
                )
            )
        }
    }
}

private struct TransactionRow: View {
    let transaction: NormalizedTransaction

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(transaction.merchantNormalized)
                .font(Theme.Typography.subheadline)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.md)
            Text(transaction.transactionAmount, format: .currency(code: transaction.currency ?? "USD"))
                .font(Theme.Typography.price)
                .foregroundStyle(Theme.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(transaction.transactionDate.shortDateString)
                .font(Theme.Typography.footnote)
                .foregroundStyle(Theme.Colors.textTertiary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, Theme.Spacing.sm)
    }
}
