import SwiftUI

// MARK: - Color Helpers

private extension Color {
    /// Creates a color that adapts between light and dark mode.
    init(lightHex: UInt, darkHex: UInt) {
        self.init(light: Color(hex: lightHex), dark: Color(hex: darkHex))
    }

    init(light: Color, dark: Color) {
        #if os(macOS)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
                ? NSColor(dark)
                : NSColor(light)
        })
        #else
        self.init(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(dark)
                : UIColor(light)
        })
        #endif
    }

    init(hex: UInt) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

extension Color {
    /// OKLCH → sRGB. The Tally design system is authored in `oklch()`; this
    /// reproduces those values exactly (and lets the monogram tiles tint by an
    /// arbitrary hue), since SwiftUI has no native OKLCH support.
    ///
    /// - Parameters:
    ///   - l: perceptual lightness, 0…1
    ///   - c: chroma (~0…0.4)
    ///   - h: hue in degrees, 0…360
    init(oklchL l: Double, c: Double, h: Double, opacity: Double = 1) {
        let hr = h * .pi / 180
        let a = c * cos(hr)
        let b = c * sin(hr)

        // OKLab → LMS (cubed)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let lc = l_ * l_ * l_
        let mc = m_ * m_ * m_
        let sc = s_ * s_ * s_

        // LMS → linear sRGB
        let r = 4.0767416621 * lc - 3.3077115913 * mc + 0.2309699292 * sc
        let g = -1.2684380046 * lc + 2.6097574011 * mc - 0.3413193965 * sc
        let bl = -0.0041960863 * lc - 0.7034186147 * mc + 1.7076147010 * sc

        func gamma(_ value: Double) -> Double {
            let v = min(max(value, 0), 1)
            return v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055
        }

        self.init(.sRGB, red: gamma(r), green: gamma(g), blue: gamma(bl), opacity: opacity)
    }

    /// Adaptive OKLCH color (light value, dark value).
    static func oklch(
        light: (l: Double, c: Double, h: Double),
        dark: (l: Double, c: Double, h: Double),
        opacity: Double = 1
    ) -> Color {
        Color(
            light: Color(oklchL: light.l, c: light.c, h: light.h, opacity: opacity),
            dark: Color(oklchL: dark.l, c: dark.c, h: dark.h, opacity: opacity)
        )
    }

    /// Warm translucent ink, used for the design's `rgba(...)` hairlines.
    fileprivate static func warmAlpha(
        lightRGB: (Double, Double, Double), lightA: Double,
        darkRGB: (Double, Double, Double), darkA: Double
    ) -> Color {
        Color(
            light: Color(.sRGB, red: lightRGB.0 / 255, green: lightRGB.1 / 255, blue: lightRGB.2 / 255, opacity: lightA),
            dark: Color(.sRGB, red: darkRGB.0 / 255, green: darkRGB.1 / 255, blue: darkRGB.2 / 255, opacity: darkA)
        )
    }
}

// MARK: - Theme — "Tally"
//
// Warm, friendly, light-and-airy subscription tracker (with an equally-polished
// dark mode). Soft direction: rounded surfaces, a coral ember accent, cozy
// density, lively-but-calm motion. Replaces the former "Obsidian Ledger" theme;
// token NAMES are preserved so shared components reskin in place.
//
enum Theme {

    // MARK: - Layout

    enum Layout {
        static let navigationRailWidth: CGFloat = 232
        static let contentMaxWidth: CGFloat = 920
        static let preferencesMaxWidth: CGFloat = 860
    }

    // MARK: - Spacing — "Breathe", cozy

    // swiftlint:disable identifier_name
    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 20
        static let xxl: CGFloat = 24
        static let section: CGFloat = 30
        static let breathe: CGFloat = 40

        /// Tally-specific tokens (cozy density).
        static let page: CGFloat = 24        // outer content padding
        static let gap: CGFloat = 18         // gap between stacked sections
        static let rowV: CGFloat = 11        // list row vertical padding
        static let cardPad: CGFloat = 22     // card inner padding
    }
    // swiftlint:enable identifier_name

    // MARK: - Corner Radius — Soft

    // swiftlint:disable identifier_name
    enum Radius {
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 28

        static let card: CGFloat = 24        // --r-card (soft)
        static let small: CGFloat = 16       // --r-sm (soft)
        static let tile: CGFloat = 13        // monogram tile (soft)
    }
    // swiftlint:enable identifier_name

    // MARK: - Animation — confident ease-out, calm springs

    enum Animation {
        static let feedback: Double = 0.16
        static let quick: Double = 0.20
        static let standard: Double = 0.40   // design --dur (.42), kept ≤ 0.40 cap
        static let entrance: Double = 0.55
        static let progress: Double = 0.80   // bar grow / fill

        /// Tally easing — cubic-bezier(.22, 1, .36, 1).
        static func tally(_ duration: Double) -> SwiftUI.Animation {
            .timingCurve(0.22, 1, 0.36, 1, duration: duration)
        }

        static var feedbackSmooth: SwiftUI.Animation { tally(feedback) }
        static var quickSmooth: SwiftUI.Animation { tally(quick) }
        static var smooth: SwiftUI.Animation { tally(standard) }
        static var entranceSmooth: SwiftUI.Animation { tally(entrance) }
        static var progressSmooth: SwiftUI.Animation { tally(progress) }

        /// Spring for interactive feedback only — critically damped, no overshoot.
        static var interactiveSpring: SwiftUI.Animation { .spring(response: 0.30, dampingFraction: 1.0) }
        static var quickSpring: SwiftUI.Animation { .spring(response: 0.22, dampingFraction: 1.0) }
        static var spring: SwiftUI.Animation { interactiveSpring }

        /// Slow ambient breath — reserved for background mesh drift only.
        static var ambient: SwiftUI.Animation { .easeInOut(duration: 6.5) }

        static func whenAllowed(
            _ animation: SwiftUI.Animation,
            reduceMotion: Bool
        ) -> SwiftUI.Animation? {
            reduceMotion ? nil : animation
        }
    }

    // MARK: - Colors — Soft / coral, warm light + dark

    // swiftlint:disable identifier_name
    enum Colors {
        // Surfaces
        static let bg = Color(lightHex: 0xFDFBF8, darkHex: 0x1D1A17)          // --window
        static let bgCard = Color(lightHex: 0xFFFFFF, darkHex: 0x25201D)       // --surface
        static let bgElevated = Color(lightHex: 0xF6F0E9, darkHex: 0x171311)   // --sidebar
        static let bgInset = Color(lightHex: 0xF8F3EC, darkHex: 0x201B18)      // --surface-2
        static let bgPressed = Color(lightHex: 0xEFE7DB, darkHex: 0x2C2622)

        static let surface = bgCard
        static let surfaceInset = bgInset

        // Text
        static let textPrimary = Color(lightHex: 0x221C16, darkHex: 0xF3ECE3)
        static let textSecondary = Color(lightHex: 0x7A6F63, darkHex: 0xA89C8F)
        static let textTertiary = Color(lightHex: 0xA89B8B, darkHex: 0x6F6357)
        static let ink = textPrimary

        // Hairlines (warm translucent — matches the design's rgba borders)
        static let border = Color.warmAlpha(
            lightRGB: (60, 40, 24), lightA: 0.10,
            darkRGB: (255, 240, 225), darkA: 0.09
        )
        static let borderStrong = Color.warmAlpha(
            lightRGB: (60, 40, 24), lightA: 0.16,
            darkRGB: (255, 240, 225), darkA: 0.16
        )
        static let borderActive = borderStrong

        // Coral ember accent
        static let accent = Color.oklch(light: (0.67, 0.16, 32), dark: (0.75, 0.14, 35))
        static let accent2 = Color.oklch(light: (0.71, 0.15, 38), dark: (0.78, 0.13, 42))
        static let accentSoft = Color.oklch(light: (0.93, 0.05, 36), dark: (0.36, 0.07, 34))
        static let accentDeep = Color.oklch(light: (0.60, 0.16, 30), dark: (0.66, 0.15, 36))
        static let accentHalo = accentSoft
        static let onAccent = Color(lightHex: 0xFFFFFF, darkHex: 0x1A120C)

        // Signal colors
        static let destructive = Color.oklch(light: (0.58, 0.18, 25), dark: (0.72, 0.16, 27))
        static let warning = Color.oklch(light: (0.62, 0.14, 55), dark: (0.82, 0.12, 60))
        static let positive = Color.oklch(light: (0.55, 0.13, 150), dark: (0.82, 0.13, 150))

        // Category tones (used for ambient backdrops / story accents)
        static let quietBlue = Color.oklch(light: (0.55, 0.12, 250), dark: (0.78, 0.10, 250))
        static let plum = Color.oklch(light: (0.55, 0.13, 320), dark: (0.80, 0.11, 320))
        static let clay = Color.oklch(light: (0.62, 0.12, 50), dark: (0.80, 0.11, 55))
        static let rose = Color.oklch(light: (0.60, 0.15, 5), dark: (0.82, 0.12, 8))
        static let moss = Color.oklch(light: (0.58, 0.11, 145), dark: (0.80, 0.10, 145))

        // Warm ambient drop shadow (matches the design's soft shadows)
        static func warmShadow(opacity: Double) -> Color {
            Color(.sRGB, red: 120 / 255, green: 70 / 255, blue: 40 / 255, opacity: opacity)
        }
    }
    // swiftlint:enable identifier_name

    // MARK: - Typography — SF Pro (sans) + SF Rounded (hero / numerals)
    //
    // Friendly, rounded numerals (≈ Nunito) for hero values; humanist sans
    // (≈ Hanken Grotesk → SF Pro) for everything else.

    enum Typography {
        /// Rounded numerals / hero — friendly geometric feel.
        static func rounded(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
            .system(size: size, weight: weight, design: .rounded)
        }
        /// Humanist sans body text.
        static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }

        // Hero / display (rounded)
        static let masthead = rounded(72, .heavy)
        static let displayLarge = rounded(40, .heavy)
        static let displayMedium = rounded(31, .heavy)

        // Headlines (sans)
        static let headline = sans(19, .bold)
        static let subheadline = sans(15, .medium)

        // Body (sans)
        static let body = sans(15, .regular)
        static let callout = sans(14, .regular)
        static let footnote = sans(13, .regular)
        static let caption = sans(11, .medium)

        // Specialized
        static let price = rounded(17, .heavy)
        static let metric = rounded(28, .heavy)
        static let ledger = sans(12, .semibold)
        static let stamp = sans(11, .bold)
    }
}

// MARK: - Surfaces

/// Tally feature card — warm surface, soft generous shadow, hairline border.
struct FeatureCard: ViewModifier {
    var padding: CGFloat = Theme.Spacing.cardPad
    var radius: CGFloat = Theme.Radius.card
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.Colors.bgCard)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Colors.border, lineWidth: 0.5)
            }
            .shadow(
                color: colorScheme == .dark
                    ? Color.black.opacity(0.55)
                    : Theme.Colors.warmShadow(opacity: 0.18),
                radius: colorScheme == .dark ? 26 : 22,
                x: 0,
                y: colorScheme == .dark ? 18 : 16
            )
    }
}

extension View {
    /// Warm card — surface fill, hairline border, soft ambient shadow.
    func featureCard(padding: CGFloat = Theme.Spacing.cardPad, radius: CGFloat = Theme.Radius.card) -> some View {
        modifier(FeatureCard(padding: padding, radius: radius))
    }

    func cardShadow() -> some View {
        shadow(color: Theme.Colors.warmShadow(opacity: 0.14), radius: 18, x: 0, y: 12)
    }

    func editorialPage(maxWidth: CGFloat = Theme.Layout.contentMaxWidth) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, Theme.Spacing.page)
            .padding(.vertical, Theme.Spacing.page)
    }
}

// MARK: - Eyebrow — accent rule + tracked uppercase label

struct TallyEyebrow: View {
    let text: String
    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Theme.Colors.accent)
                .frame(width: 16, height: 2)
            Text(text.uppercased())
                .font(.system(size: 12, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Theme.Colors.accent)
        }
    }
}

// MARK: - Page Header (kept API: eyebrow / title / subtitle / trailing)

struct EditorialPageHeader<Trailing: View>: View {
    let eyebrow: String?
    let title: String
    let subtitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        eyebrow: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: Theme.Spacing.xl) {
                titleBlock
                Spacer(minLength: Theme.Spacing.lg)
                trailing()
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                titleBlock
                trailing()
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if let eyebrow {
                TallyEyebrow(text: eyebrow)
            }
            Text(title)
                .font(Theme.Typography.displayMedium)
                .foregroundStyle(Theme.Colors.textPrimary)
                .kerning(-0.6)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.Typography.subheadline)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 720, alignment: .leading)
    }
}

extension EditorialPageHeader where Trailing == EmptyView {
    init(eyebrow: String? = nil, title: String, subtitle: String? = nil) {
        self.eyebrow = eyebrow
        self.title = title
        self.subtitle = subtitle
        self.trailing = { EmptyView() }
    }
}

// MARK: - Action Button (kept API: title / systemImage / tone)

struct EditorialActionButton: View {
    enum Tone {
        case primary, secondary, destructive

        var color: Color {
            switch self {
            case .primary: Theme.Colors.accent
            case .secondary: Theme.Colors.textSecondary
            case .destructive: Theme.Colors.destructive
            }
        }
    }

    let title: String
    var systemImage: String?
    var tone: Tone = .secondary
    var isDisabled = false
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.sm) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 14, weight: tone == .primary ? .bold : .semibold))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, tone == .primary ? Theme.Spacing.lg : Theme.Spacing.md)
            .padding(.vertical, 10)
            .background {
                if tone == .primary {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Theme.Colors.accent2, Theme.Colors.accent],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                } else {
                    Capsule(style: .continuous)
                        .strokeBorder(
                            isHovered && !isDisabled
                                ? Theme.Colors.accent.opacity(0.45)
                                : Theme.Colors.borderStrong,
                            lineWidth: 0.5
                        )
                        .background(Capsule(style: .continuous).fill(Theme.Colors.bgCard))
                }
            }
            .contentShape(Capsule())
            .offset(y: isHovered && !isDisabled ? -1 : 0)
        }
        .buttonStyle(EditorialButtonFeedbackStyle(isDisabled: isDisabled))
        .disabled(isDisabled)
        .onHover { isHovered = $0 }
        .animation(
            Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion),
            value: isHovered
        )
    }

    private var foreground: Color {
        if tone == .primary { return Theme.Colors.onAccent }
        return tone.color.opacity(isDisabled ? 0.42 : 1)
    }
}

struct EditorialButtonFeedbackStyle: ButtonStyle {
    let isDisabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed && !isDisabled ? 0.7 : 1)
            .scaleEffect(configuration.isPressed && !isDisabled ? 0.98 : 1)
            .animation(
                Theme.Animation.whenAllowed(Theme.Animation.feedbackSmooth, reduceMotion: reduceMotion),
                value: configuration.isPressed
            )
    }
}

// MARK: - Dividers

struct EditorialDivider: View {
    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            line
            Circle()
                .fill(Theme.Colors.accent)
                .frame(width: 4, height: 4)
            line
        }
        .padding(.vertical, Theme.Spacing.sm)
    }

    private var line: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [Theme.Colors.border.opacity(0), Theme.Colors.border, Theme.Colors.border.opacity(0)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 0.5)
    }
}

struct HairlineDivider: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Colors.border)
            .frame(height: 0.5)
    }
}

// MARK: - Appear / Scene Animations

struct EditorialSceneTransition: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .identity : .opacity)
    }
}

extension View {
    func editorialSceneTransition() -> some View { modifier(EditorialSceneTransition()) }
}
