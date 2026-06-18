import SwiftUI

/// The friendly "Add or update" chooser — the one task a non-technical user
/// needs. Matches the Tally design's sheet: drop a statement, add by hand, or
/// refresh. Each choice routes to the corresponding real flow.
struct AddUpdateSheet: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TallyEyebrow(text: "Keep your list fresh")
                .padding(.bottom, 12)

            Text("Add or update subscriptions")
                .font(.system(size: 25, weight: .heavy, design: .rounded))
                .foregroundStyle(Theme.Colors.textPrimary)
                .kerning(-0.3)

            Text("Pick whatever feels easiest. Most people just drop in a statement and let the app do the rest — nothing leaves your Mac.")
                .font(.system(size: 14.5, weight: .medium))
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
                .padding(.bottom, 22)

            VStack(spacing: 10) {
                ForEach(SheetChoice.all) { choice in
                    ChoiceButton(choice: choice) { select(choice) }
                }
            }

            HStack {
                Spacer()
                Button("Maybe later") { appModel.addOrEditSheet = nil }
                    .buttonStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .padding(.vertical, 9)
            }
            .padding(.top, 22)
        }
        .padding(28)
        #if os(macOS)
        .frame(width: 520)
        #else
        .frame(maxWidth: 520)
        #endif
        .background(Theme.Colors.bg)
    }

    private func select(_ choice: SheetChoice) {
        switch choice.kind {
        case .statement, .refresh:
            // macOS can show the backing transactions screen for context; iOS
            // keeps that route out of the Tally tab bar, so the root view owns
            // the pending file picker request directly.
            appModel.tallySelectedSubscriptionID = nil
            #if os(macOS)
            appModel.selectedTab = .transactions
            #endif
            appModel.pendingImportFilePicker = true
            appModel.addOrEditSheet = nil
        case .manual:
            // Swap the chooser for the real add-by-hand form (same sheet host).
            appModel.addOrEditSheet = .create
        }
    }
}

private enum SheetChoiceKind { case statement, manual, refresh }

private struct SheetChoice: Identifiable {
    let kind: SheetChoiceKind
    let icon: String
    let title: String
    let subtitle: String
    let isPrimary: Bool
    var id: String { title }

    static let all: [SheetChoice] = [
        SheetChoice(kind: .statement, icon: "doc.text", title: "Drop in a statement",
                    subtitle: "Drag a bank or card export (.csv or Excel) — we'll find the subscriptions for you.", isPrimary: true),
        SheetChoice(kind: .manual, icon: "pencil", title: "Add one by hand",
                    subtitle: "Type in a subscription yourself — name, price, and how often it bills.", isPrimary: false),
        SheetChoice(kind: .refresh, icon: "arrow.clockwise", title: "Refresh my data",
                    subtitle: "Check your latest statement for new charges and price changes.", isPrimary: false)
    ]
}

private struct ChoiceButton: View {
    let choice: SheetChoice
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(choice.isPrimary ? Theme.Colors.accent : Theme.Colors.accentSoft)
                    .frame(width: 46, height: 46)
                    .overlay(
                        Image(systemName: choice.icon)
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(choice.isPrimary ? Theme.Colors.onAccent : Theme.Colors.accent)
                    )
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.title)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(Theme.Colors.textPrimary)
                    Text(choice.subtitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Colors.textSecondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Spacing.sm)
                Image(systemName: "arrow.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.Colors.accent : Theme.Colors.textTertiary)
                    .offset(x: hovering && !reduceMotion ? 4 : 0)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(choice.isPrimary ? Theme.Colors.accentSoft : Theme.Colors.bgCard)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(
                        choice.isPrimary
                            ? Theme.Colors.accent.opacity(hovering ? 0.6 : 0.4)
                            : (hovering ? Theme.Colors.accent.opacity(0.45) : Theme.Colors.border),
                        lineWidth: 0.5
                    )
            )
            .offset(y: hovering && !reduceMotion ? -2 : 0)
            .shadow(color: hovering && !reduceMotion ? Theme.Colors.warmShadow(opacity: 0.18) : .clear,
                    radius: 18, x: 0, y: 12)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}
