import SwiftData
import SwiftUI

struct ImportsView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \ImportRecord.importedAt, order: .reverse) private var imports: [ImportRecord]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    EditorialPageHeader(
                        eyebrow: "\(imports.count) statement runs",
                        title: "Imports",
                        subtitle: "A provenance trail for every statement file that shaped the subscription library."
                    )
                        .padding(.bottom, Theme.Spacing.xxl)

                    if imports.isEmpty {
                        VStack(spacing: Theme.Spacing.md) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.Colors.textTertiary)
                            Text("No imports yet")
                                .font(Theme.Typography.callout)
                                .foregroundStyle(Theme.Colors.textSecondary)
                            Text("Imported CSV, Excel, OFX, and QFX files will appear here.")
                                .font(Theme.Typography.footnote)
                                .foregroundStyle(Theme.Colors.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Theme.Spacing.section)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(imports) { record in
                                HStack(alignment: .top, spacing: Theme.Spacing.md) {
                                    Image(systemName: statusSymbol(for: record.status))
                                        .font(.system(size: 14))
                                        .foregroundStyle(statusColor(for: record.status))
                                        .frame(width: 28, height: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(record.fileName)
                                            .font(Theme.Typography.subheadline)
                                            .foregroundStyle(Theme.Colors.textPrimary)
                                        HStack(spacing: Theme.Spacing.sm) {
                                            Text(record.fileFormat?.displayName ?? record.sourceType.uppercased())
                                                .font(Theme.Typography.caption)
                                                .foregroundStyle(Theme.Colors.textTertiary)
                                            Text("\(record.importedTransactionCount) rows")
                                                .font(Theme.Typography.footnote)
                                                .foregroundStyle(Theme.Colors.textTertiary)
                                            Text(record.importedAt, format: .dateTime.month(.abbreviated).day().year())
                                                .font(Theme.Typography.footnote)
                                                .foregroundStyle(Theme.Colors.textTertiary)
                                        }
                                        if let detectionSummary = detectionSummary(for: record) {
                                            Text(detectionSummary)
                                                .font(Theme.Typography.footnote)
                                                .foregroundStyle(Theme.Colors.textSecondary)
                                        }
                                        if let error = record.errorMessage, !error.isEmpty {
                                            Text(error)
                                                .font(Theme.Typography.footnote)
                                                .foregroundStyle(Theme.Colors.destructive)
                                        }
                                    }

                                    Spacer()

                                    VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
                                        Text(record.status.title)
                                            .font(Theme.Typography.caption)
                                            .foregroundStyle(statusColor(for: record.status))

                                        if record.needsReviewSubscriptionCount > 0 {
                                            Button {
                                                appModel.openSubscriptionLibrary(
                                                    state: .suggested,
                                                    importRecordID: record.id
                                                )
                                            } label: {
                                                Text("Review items")
                                                    .font(Theme.Typography.footnote)
                                                    .foregroundStyle(Theme.Colors.accent)
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                }
                                .padding(.vertical, Theme.Spacing.sm)

                                if record.id != imports.last?.id {
                                    HairlineDivider()
                                        .padding(.leading, 40)
                                }
                            }
                        }
                        .featureCard()
                    }
                }
                .editorialPage()
            }
            .background(Theme.Colors.bg)
        }
    }

    private func statusSymbol(for status: ImportStatus) -> String {
        switch status {
        case .analyzed: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .needsMapping: "slider.horizontal.3"
        case .parsing: "doc.text.magnifyingglass"
        case .classifying: "sparkles"
        case .queued: "clock"
        }
    }

    private func statusColor(for status: ImportStatus) -> Color {
        switch status {
        case .analyzed: Theme.Colors.positive
        case .failed: Theme.Colors.destructive
        case .needsMapping: Theme.Colors.warning
        case .parsing, .classifying: Theme.Colors.accent
        case .queued: Theme.Colors.textTertiary
        }
    }

    private func detectionSummary(for record: ImportRecord) -> String? {
        let parts = [
            record.detectedSubscriptionCount > 0 ? "\(record.detectedSubscriptionCount) detected" : nil,
            record.needsReviewSubscriptionCount > 0 ? "\(record.needsReviewSubscriptionCount) review" : nil,
            record.recoveredRecurringCandidateCount > 0 ? "\(record.recoveredRecurringCandidateCount) recovered" : nil,
            record.suppressedRecurringCandidateCount > 0 ? "\(record.suppressedRecurringCandidateCount) suppressed" : nil
        ].compactMap { $0 }

        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
