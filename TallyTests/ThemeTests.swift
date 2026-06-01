import Testing
@testable import Tally

@Suite("Theme token consistency")
struct ThemeTests {
    @Test func spacingValuesArePositive() {
        #expect(Theme.Spacing.xs > 0)
        #expect(Theme.Spacing.sm > 0)
        #expect(Theme.Spacing.md > 0)
        #expect(Theme.Spacing.lg > 0)
        #expect(Theme.Spacing.xl > 0)
    }

    @Test func cornerRadiusValuesAreReasonable() {
        #expect(Theme.Radius.sm >= 4)
        #expect(Theme.Radius.md >= 8)
        #expect(Theme.Radius.lg >= 12)
    }

    @Test func animationDurationsAreSubtle() {
        #expect(Theme.Animation.quick <= 0.25)
        #expect(Theme.Animation.standard <= 0.4)
    }

    // MARK: - Calibration gate (2026-05-29)
    //
    // The Obsidian Ledger redesign over-inflated the vertical rhythm and rail,
    // which read as "oversized". These upper bounds stop a silent regression to
    // that scale. Raise them only alongside the design gate in CLAUDE.md /
    // AGENTS.md.

    @Test func spacingScaleStaysCalm() {
        #expect(Theme.Spacing.xxl <= 30)
        #expect(Theme.Spacing.section <= 40)
        #expect(Theme.Spacing.breathe <= 52)
    }

    @Test func spacingScaleIsMonotonic() {
        #expect(Theme.Spacing.xs < Theme.Spacing.sm)
        #expect(Theme.Spacing.sm < Theme.Spacing.md)
        #expect(Theme.Spacing.md < Theme.Spacing.lg)
        #expect(Theme.Spacing.lg < Theme.Spacing.xl)
        #expect(Theme.Spacing.xl < Theme.Spacing.xxl)
        #expect(Theme.Spacing.xxl < Theme.Spacing.section)
        #expect(Theme.Spacing.section < Theme.Spacing.breathe)
    }

    @Test func navigationRailWidthIsReasonable() {
        #expect(Theme.Layout.navigationRailWidth >= 200)
        #expect(Theme.Layout.navigationRailWidth <= 248)
    }
}
