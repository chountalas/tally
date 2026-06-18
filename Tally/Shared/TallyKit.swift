import SwiftUI

// MARK: - Per-service hue
//
// Deterministic 0…360 hue from a service name (stable across launches, unlike
// `String.hashValue`). Feeds the OKLCH monogram tiles.

func tallyHue(for seed: String) -> Double {
    var hash: UInt64 = 5381
    for byte in seed.lowercased().unicodeScalars.flatMap({ Array(String($0).utf8) }) {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return Double(hash % 360)
}

// MARK: - Monogram Tile
//
// Colored-initial tile (no real brand logo) — matches the Tally design exactly.
// Background/foreground are OKLCH-tinted by the service hue.

struct MonogramTile: View {
    let name: String
    var size: CGFloat = 42
    var cornerRadius: CGFloat?
    @Environment(\.colorScheme) private var scheme

    private var hue: Double { tallyHue(for: name) }

    private var letter: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(1)).uppercased()
    }

    var body: some View {
        let radius = cornerRadius ?? size * 0.30
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(scheme == .dark
                ? Color(oklchL: 0.32, c: 0.07, h: hue)
                : Color(oklchL: 0.95, c: 0.05, h: hue))
            .frame(width: size, height: size)
            .overlay {
                Text(letter)
                    .font(.system(size: size * 0.43, weight: .heavy, design: .rounded))
                    .foregroundStyle(scheme == .dark
                        ? Color(oklchL: 0.82, c: 0.13, h: hue)
                        : Color(oklchL: 0.50, c: 0.16, h: hue))
            }
    }
}

// MARK: - Section header (title + optional trailing link)

struct SectionHead<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    init(_ title: String, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
            Spacer(minLength: Theme.Spacing.md)
            trailing()
        }
    }
}

extension SectionHead where Trailing == EmptyView {
    init(_ title: String) {
        self.title = title
        self.trailing = { EmptyView() }
    }
}

/// "See all →" style text link with a hover nudge.
struct LinkButton: View {
    let title: String
    var systemImage: String = "arrow.right"
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: hovering && !reduceMotion ? 7 : 4) {
                Text(title)
                Image(systemName: systemImage).font(.system(size: 12, weight: .bold))
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(Theme.Colors.accent)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

// MARK: - Filter chip

struct TallyChip: View {
    let label: String
    var count: Int?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                if let count {
                    Text("\(count)")
                        .fontWeight(.bold)
                        .opacity(0.65)
                }
            }
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(isSelected ? Theme.Colors.onAccent : (hovering ? Theme.Colors.textPrimary : Theme.Colors.textSecondary))
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .background {
                if isSelected {
                    Capsule(style: .continuous).fill(Theme.Colors.accent)
                } else {
                    Capsule(style: .continuous).strokeBorder(Theme.Colors.borderStrong, lineWidth: 0.5)
                }
            }
            .offset(y: hovering && !isSelected && !reduceMotion ? -1 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.quickSmooth, reduceMotion: reduceMotion), value: isSelected)
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

// MARK: - Badge

enum TallyBadgeKind {
    case soon, ended, yearly, priceUp

    var background: Color {
        switch self {
        case .soon: Theme.Colors.accentSoft
        case .ended: Theme.Colors.textPrimary.opacity(0.08)
        case .yearly: Theme.Colors.quietBlue.opacity(0.16)
        case .priceUp: Theme.Colors.warning.opacity(0.18)
        }
    }

    var foreground: Color {
        switch self {
        case .soon: Theme.Colors.accent
        case .ended: Theme.Colors.textSecondary
        case .yearly: Theme.Colors.quietBlue
        case .priceUp: Theme.Colors.warning
        }
    }
}

struct TallyBadge: View {
    let text: String
    let kind: TallyBadgeKind

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(Capsule(style: .continuous).fill(kind.background))
    }
}

// MARK: - Buttons

/// Full-width coral gradient button (sidebar "Add or update").
struct PrimaryGradientButton: View {
    let title: String
    var systemImage: String = "plus"
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: systemImage).font(.system(size: 15, weight: .bold))
                Text(title).font(.system(size: 14, weight: .bold))
            }
            .foregroundStyle(Theme.Colors.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.Colors.accent2, Theme.Colors.accent], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
            .shadow(color: Theme.Colors.accent.opacity(hovering && !reduceMotion ? 0.5 : 0.35),
                    radius: hovering && !reduceMotion ? 14 : 9, x: 0, y: hovering && !reduceMotion ? 8 : 5)
            .offset(y: hovering && !reduceMotion ? -2 : 0)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

/// Compact solid coral capsule (header / nudge primary).
struct SolidAccentButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 16, weight: .bold)) }
                Text(title).font(.system(size: 13.5, weight: .bold))
            }
            .foregroundStyle(Theme.Colors.onAccent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Capsule(style: .continuous).fill(Theme.Colors.accent))
            .brightness(hovering && !reduceMotion ? 0.05 : 0)
            .offset(y: hovering && !reduceMotion ? -1 : 0)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }
}

/// Pill action button for the detail view (Remind / Edit / Mark cancelled).
struct TallyActionButton: View {
    enum Kind { case primary, normal, danger }
    let title: String
    var systemImage: String?
    var kind: Kind = .normal
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 14, weight: .semibold)) }
                Text(title).font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .background {
                if kind == .primary {
                    Capsule(style: .continuous).fill(Theme.Colors.accent)
                } else {
                    Capsule(style: .continuous).fill(Theme.Colors.bgCard)
                        .overlay(Capsule(style: .continuous).strokeBorder(
                            hovering && !reduceMotion ? Theme.Colors.accent.opacity(0.4) : Theme.Colors.borderStrong,
                            lineWidth: 0.5))
                }
            }
            .offset(y: hovering && !reduceMotion ? -2 : 0)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering = $0 }
        .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: Theme.Colors.onAccent
        case .normal: Theme.Colors.textPrimary
        case .danger: Theme.Colors.destructive
        }
    }
}

/// Opacity + scale press feedback.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion), value: configuration.isPressed)
    }
}

// MARK: - Hover lift (cards)

struct HoverLift: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering && !reduceMotion ? 1.012 : 1)
            .offset(y: hovering && !reduceMotion ? -4 : 0)
            .shadow(color: hovering && !reduceMotion ? Theme.Colors.warmShadow(opacity: 0.18) : .clear,
                    radius: 18, x: 0, y: 14)
            .onHover { hovering = $0 }
            .animation(Theme.Animation.whenAllowed(Theme.Animation.smooth, reduceMotion: reduceMotion), value: hovering)
    }
}

extension View {
    func hoverLift() -> some View { modifier(HoverLift()) }
}

// MARK: - Live dot (footer "Saved on this Mac")
//
// Static green core + soft halo. Deliberately not a repeating pulse — keeps the
// chrome calm, consistent with the project's anti-perpetual-motion calibration.

struct LiveDot: View {
    var color: Color = Theme.Colors.positive
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().fill(color.opacity(0.28)).frame(width: size * 2.2, height: size * 2.2))
    }
}

// MARK: - Growing / countdown bars

/// Vertical bar that grows from 0 to `fraction` of the track height on appear.
struct GrowingBar: View {
    let fraction: CGFloat
    let isHighlighted: Bool
    var delay: Double = 0
    @State private var grown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack { Spacer(minLength: 0) }
                .frame(maxWidth: .infinity)
                .frame(height: max(2, geo.size.height * (grown || reduceMotion ? max(0.02, fraction) : 0)))
                .background(
                    LinearGradient(colors: [Theme.Colors.accent2, Theme.Colors.accent], startPoint: .top, endPoint: .bottom)
                )
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 7, bottomLeadingRadius: 4, bottomTrailingRadius: 4, topTrailingRadius: 7, style: .continuous))
                .opacity(isHighlighted ? 1 : 0.55)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .onAppear {
            guard !reduceMotion else { grown = true; return }
            withAnimation(Theme.Animation.progressSmooth.delay(delay)) { grown = true }
        }
    }
}

// MARK: - Formatting helpers

extension Decimal {
    /// "$124.62" (cents) or "$1,495" (whole).
    func tallyMoney(code: String = "USD", showCents: Bool = true) -> String {
        formatted(.currency(code: code).precision(.fractionLength(showCents ? 2 : 0)))
    }
}

extension Date {
    /// "3 days ago" / "yesterday" / "today" / "tomorrow" / "in 3 days".
    var tallyRelativeDay: String {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: self)).day ?? 0
        switch days {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case let d where d > 1: return "in \(d) days"
        default: return "\(-days) days ago"
        }
    }

    /// Whole-day distance from today (negative = past).
    var tallyDaysFromNow: Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: .now), to: cal.startOfDay(for: self)).day ?? 0
    }

    /// "Jun 1".
    var tallyShortDate: String { formatted(.dateTime.month(.abbreviated).day()) }

    /// "Jun 2016".
    var tallyMonthYear: String { formatted(.dateTime.month(.abbreviated).year()) }

    /// "June".
    var tallyMonthName: String { formatted(.dateTime.month(.wide)) }
}

/// "9 years, 11 months" / "5 months" / "less than a month".
func tallyTenureLabel(months: Int) -> String {
    let m = max(0, months)
    if m < 1 { return "less than a month" }
    if m < 12 { return "\(m) \(m == 1 ? "month" : "months")" }
    let years = m / 12
    let rem = m % 12
    let ys = "\(years) \(years == 1 ? "year" : "years")"
    return rem == 0 ? ys : "\(ys), \(rem) \(rem == 1 ? "month" : "months")"
}

// MARK: - Subscription view conveniences
//
// Tally-prefixed to avoid colliding with existing `extension Subscription`.

extension Subscription {
    var tallyName: String { displayName.isEmpty ? canonicalName : displayName }

    var tallyMonthly: Decimal { normalizedMonthlyAmount }

    var tallyIsYearly: Bool { cadence == .annual }

    var tallyIsActive: Bool { status == .active }

    var tallyPriceWentUp: Bool { (priceChangePercent ?? 0) > 0.05 }

    /// Whole-day distance to the next predicted charge (nil if unknown).
    var tallyDaysUntilRenewal: Int? { predictedNextChargeDate?.tallyDaysFromNow }

    var tallyRenewsSoon: Bool {
        guard let days = tallyDaysUntilRenewal else { return false }
        return days >= 0 && days <= 7
    }

    /// Raw price label, e.g. "$22.99 / month" or "$139 / year".
    var tallyPriceLabel: String {
        "\(priceAmount.tallyMoney(code: priceCurrency)) / \(cadence.tallyBillingUnit)"
    }

    var tallyCategory: String {
        let trimmed = (serviceCategory ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Other" : trimmed
    }

    /// Months held — from `tenureMonths` if present, else derived from `firstChargeDate`.
    var tallyTenureMonths: Int? {
        if let t = tenureMonths, t > 0 { return t }
        guard let start = firstChargeDate else { return nil }
        let end = status == .active ? Date.now : (lastChargeDate ?? .now)
        let comps = Calendar.current.dateComponents([.month], from: start, to: end)
        return max(0, comps.month ?? 0)
    }
}

extension SubscriptionCadence {
    var tallyBillingUnit: String {
        switch self {
        case .weekly: "week"
        case .biweekly: "2 weeks"
        case .monthly, .unknown: "month"
        case .quarterly: "quarter"
        case .semiannual: "6 months"
        case .annual: "year"
        }
    }

    var tallyBillingSummary: String {
        switch self {
        case .weekly: "Every week"
        case .biweekly: "Every 2 weeks"
        case .monthly, .unknown: "Every month"
        case .quarterly: "Every 3 months"
        case .semiannual: "Every 6 months"
        case .annual: "Once a year"
        }
    }

    var tallyBillingPhrase: String {
        switch self {
        case .weekly: "a week"
        case .biweekly: "every 2 weeks"
        case .monthly, .unknown: "every month"
        case .quarterly: "every 3 months"
        case .semiannual: "every 6 months"
        case .annual: "a year"
        }
    }

    var tallyPlanLabel: String {
        switch self {
        case .weekly: "Weekly"
        case .biweekly: "Biweekly"
        case .monthly, .unknown: "Monthly"
        case .quarterly: "Quarterly"
        case .semiannual: "Semiannual"
        case .annual: "Yearly"
        }
    }

    func tallyAdvanced(_ date: Date, by periods: Int, using calendar: Calendar = .current) -> Date? {
        switch self {
        case .weekly:
            return calendar.date(byAdding: .day, value: 7 * periods, to: date)
        case .biweekly:
            return calendar.date(byAdding: .day, value: 14 * periods, to: date)
        case .monthly, .unknown:
            return calendar.date(byAdding: .month, value: periods, to: date)
        case .quarterly:
            return calendar.date(byAdding: .month, value: 3 * periods, to: date)
        case .semiannual:
            return calendar.date(byAdding: .month, value: 6 * periods, to: date)
        case .annual:
            return calendar.date(byAdding: .year, value: periods, to: date)
        }
    }
}
