import SwiftUI

// MARK: - Ember Halo Background
//
// Slow-breathing ambient gradient used behind hero metrics.
// Subtle in light mode, dramatic in dark mode.

struct EmberHaloBackground: View {
    var intensity: Double = 1.0
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? .infinity : 1.0 / 20.0)) { timeline in
            let elapsed: Double = timeline.date.timeIntervalSinceReferenceDate
            let drift: Double = reduceMotion ? 0 : sin(elapsed * 0.12)
            let drift2: Double = reduceMotion ? 0 : cos(elapsed * 0.09)

            haloLayer(drift: drift, drift2: drift2)
        }
    }

    @ViewBuilder
    private func haloLayer(drift: Double, drift2: Double) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .fill(Theme.Colors.bgCard)

            // Primary ember bloom (top-right)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.accent.opacity((colorScheme == .dark ? 0.34 : 0.12) * intensity),
                            Theme.Colors.accent.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 340
                    )
                )
                .frame(width: 680, height: 680)
                .offset(x: 220 + drift * 12, y: -180 + drift2 * 9)
                .blendMode(.plusLighter)

            // Secondary plum/clay bloom (bottom-left)
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Theme.Colors.plum.opacity((colorScheme == .dark ? 0.22 : 0.08) * intensity),
                            Theme.Colors.plum.opacity(0)
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: 300
                    )
                )
                .frame(width: 540, height: 540)
                .offset(x: -180 + drift2 * 11, y: 200 + drift * 7)
                .blendMode(.plusLighter)

            // Subtle vertical gradient overlay for depth in dark mode
            if colorScheme == .dark {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.015),
                        Color.clear,
                        Color.black.opacity(0.10)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .compositingGroup()
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.xl, style: .continuous)
                .strokeBorder(Theme.Colors.border.opacity(0.55), lineWidth: 0.5)
        }
    }
}

// MARK: - Ember Aura
//
// Soft luminous halo behind a single piece of text — used on the hero number
// so the number reads like a glowing ember on dark, a warm ink imprint on light.

struct EmberAuraText: View {
    let text: String
    let font: Font
    var color: Color = Theme.Colors.textPrimary
    var glow: Color = Theme.Colors.accent
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // Soft glow (only meaningful on dark). Hidden from the a11y tree so
            // VoiceOver reads the hero amount once, not once per blurred halo.
            if colorScheme == .dark {
                Text(text)
                    .font(font)
                    .foregroundStyle(glow.opacity(0.35))
                    .blur(radius: 18)
                    .accessibilityHidden(true)

                Text(text)
                    .font(font)
                    .foregroundStyle(glow.opacity(0.18))
                    .blur(radius: 36)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(font)
                .foregroundStyle(color)
                .kerning(-1.2)
        }
        .contentTransition(.numericText())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Spotlight Hover
//
// Tracks mouse pointer (macOS) or finger (iOS) over a view and lights a soft
// gradient under the cursor. The card itself stays still; only the light moves.

struct SpotlightHover: ViewModifier {
    var radius: CGFloat = 220
    var tint: Color = Theme.Colors.accent

    @State private var location: CGPoint = .zero
    @State private var isActive: Bool = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .background {
                GeometryReader { proxy in
                    ZStack {
                        if isActive {
                            RadialGradient(
                                colors: [
                                    tint.opacity(colorScheme == .dark ? 0.22 : 0.10),
                                    tint.opacity(0)
                                ],
                                center: UnitPoint(
                                    x: location.x / max(proxy.size.width, 1),
                                    y: location.y / max(proxy.size.height, 1)
                                ),
                                startRadius: 0,
                                endRadius: radius
                            )
                            .blendMode(colorScheme == .dark ? .plusLighter : .multiply)
                            .transition(.opacity)
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    location = point
                    if !isActive {
                        withAnimation(
                            Theme.Animation.whenAllowed(
                                .easeOut(duration: 0.25),
                                reduceMotion: reduceMotion
                            )
                        ) { isActive = true }
                    }
                case .ended:
                    withAnimation(
                        Theme.Animation.whenAllowed(
                            .easeOut(duration: 0.35),
                            reduceMotion: reduceMotion
                        )
                    ) { isActive = false }
                }
            }
    }
}

extension View {
    func spotlightHover(radius: CGFloat = 220, tint: Color = Theme.Colors.accent) -> some View {
        modifier(SpotlightHover(radius: radius, tint: tint))
    }
}

// MARK: - Kinetic Tab Indicator
//
// A glowing ember mark used in the sidebar to indicate the active tab.

struct KineticTabIndicator: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Theme.Colors.accent, Theme.Colors.accentHalo],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 3)
            // Steady glow. The active-tab rail is visible on every screen, so a
            // breathing shadow meant something always pulsing in the sidebar.
            .shadow(color: Theme.Colors.accent.opacity(0.6), radius: 5, x: 0, y: 0)
    }
}

// MARK: - Ember Pulse Dot
//
// Tiny glowing dot — used on KineticTabIndicator and CTA pills.

struct EmberPulseDot: View {
    var color: Color = Theme.Colors.accent
    var size: CGFloat = 6

    // Static glowing dot. Reads as a "live / local" indicator without the
    // continuously expanding ring, which was perpetual motion in both the
    // sidebar footer and the hero header.
    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.22))
                .frame(width: size + 6, height: size + 6)

            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.6), radius: 4, x: 0, y: 0)
        }
    }
}

// MARK: - Cinematic Background
//
// Page-wide ambient backdrop: deep noir in dark mode, warm ivory in light mode,
// with a single off-frame ember bloom for depth.

struct CinematicPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.Colors.bg

            if colorScheme == .dark {
                // Distant ember glow, off-canvas top-right
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.Colors.accent.opacity(0.16),
                                Theme.Colors.accent.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 600
                        )
                    )
                    .frame(width: 1100, height: 1100)
                    .offset(x: 460, y: -380)
                    .allowsHitTesting(false)

                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.Colors.quietBlue.opacity(0.10),
                                Theme.Colors.quietBlue.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 500
                        )
                    )
                    .frame(width: 900, height: 900)
                    .offset(x: -380, y: 520)
                    .allowsHitTesting(false)
            } else {
                // Warmer, much subtler bloom in light
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Theme.Colors.accent.opacity(0.06),
                                Theme.Colors.accent.opacity(0)
                            ],
                            center: .center,
                            startRadius: 0,
                            endRadius: 500
                        )
                    )
                    .frame(width: 900, height: 900)
                    .offset(x: 360, y: -300)
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Magnetic Card
//
// Card that gently lifts and brightens on hover. Used on dashboard sections that
// the user can drill into.

struct MagneticCard: ViewModifier {
    @State private var isHovered: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered && !reduceMotion ? 1.005 : 1)
            .shadow(
                color: Color.black.opacity(isHovered ? 0.18 : 0.10),
                radius: isHovered ? 28 : 18,
                x: 0,
                y: isHovered ? 18 : 12
            )
            .onHover { hovering in
                withAnimation(
                    Theme.Animation.whenAllowed(
                        Theme.Animation.quickSpring,
                        reduceMotion: reduceMotion
                    )
                ) {
                    isHovered = hovering
                }
            }
    }
}

extension View {
    func magneticCard() -> some View {
        modifier(MagneticCard())
    }
}

// MARK: - Section Title
//
// Editorial section heading with a small accent line marker. Replaces the bare
// `Text(...).font(.headline)` pattern used across the dashboard.

struct EditorialSectionTitle: View {
    let kicker: String?
    let title: String

    init(_ title: String, kicker: String? = nil) {
        self.title = title
        self.kicker = kicker
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if let kicker {
                HStack(spacing: Theme.Spacing.sm) {
                    Rectangle()
                        .fill(Theme.Colors.accent)
                        .frame(width: 14, height: 1)
                    Text(kicker.uppercased())
                        .font(Theme.Typography.stamp)
                        .tracking(2.2)
                        .foregroundStyle(Theme.Colors.accent)
                }
            }
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Colors.textPrimary)
        }
    }
}
