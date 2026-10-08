import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``OverlayTheme`` (issue 9.10): the HUD's colours come from the
/// brand's ``Theme`` tokens, and every text role stays readable (WCAG AA,
/// ≥ 4.5:1, through the 7.3 ``BrandColor/contrastRatio(against:)`` helper) on
/// its plate — on the solid plate, and on the translucent plate over the worst
/// footage there is, pure white or pure black.
@Suite struct OverlayThemeContrastTests {

    private let theme = OverlayTheme.raceStudio
    private let brand = Theme.raceStudio.palette

    // MARK: - Tokens

    /// The HUD sits over footage, so it takes the brand's dark-appearance tokens.
    @Test func test_colours_come_from_the_brand_dark_palette() {
        #expect(theme.plate == brand.background.dark)
        #expect(theme.text == brand.textPrimary.dark)
        #expect(theme.secondaryText == brand.textSecondary.dark)
        #expect(theme.accent == brand.accent.dark)
        #expect(theme.gain == brand.positive.dark)
        #expect(theme.loss == brand.negative.dark)
    }

    /// The shift light's warning hue stands apart from the RPM bar's accent.
    @Test func test_warning_is_distinct_from_the_accent() {
        #expect(theme.warning != theme.accent)
        #expect(theme.warning.contrastRatio(against: theme.accent) > 2)
    }

    /// The sector splits (issue 9.17) use F1's colours: purple for the best so
    /// far, yellow for slower — two hues apart from each other and from the
    /// delta's gain green and loss red.
    @Test func test_sector_colours_are_purple_and_yellow() {
        let best = theme.sectorBest, slower = theme.sectorSlower

        #expect(best.blue > best.red && best.red > best.green, "purple: \(best)")
        #expect(slower.red > 0.9 && slower.green > 0.75 && slower.blue < 0.2, "yellow: \(slower)")
        #expect(theme.color(.sectorBest) == best && theme.color(.sectorSlower) == slower)
        #expect(Set([best, slower, theme.gain, theme.loss, theme.accent]).count == 5)
    }

    /// A solid plate is opaque, a translucent one lets the footage through, and
    /// no plate has no fill.
    @Test func test_plate_fills() {
        #expect(theme.plateFill(.solid)?.alpha == 1)
        #expect(theme.plateFill(.translucent)?.alpha == theme.translucentPlateOpacity)
        #expect(theme.plateFill(.none) == nil)
        #expect(theme.effectivePlate(.none, over: .rgb(255, 255, 255)) == nil)
    }

    /// The translucent plate composites over the footage behind it.
    @Test func test_translucent_plate_composites_over_the_backdrop() throws {
        let plate = try #require(theme.effectivePlate(.translucent, over: .rgb(0, 0, 0)))

        #expect(abs(plate.red - theme.plate.red * theme.translucentPlateOpacity) < 1e-12)
        #expect(plate.alpha == 1)
        #expect(theme.effectivePlate(.solid, over: .rgb(255, 255, 255)) == theme.plate)
    }

    // MARK: - The accessibility proof

    /// Every text role clears WCAG AA on every plate, over white and over black.
    @Test(arguments: OverlayTheme.TextRole.allCases, [BrandColor.rgb(255, 255, 255), .rgb(0, 0, 0)])
    func test_text_over_plate_meets_wcag_aa(role: OverlayTheme.TextRole, backdrop: BrandColor) throws {
        for style in [OverlayPlateStyle.solid, .translucent] {
            let plate = try #require(theme.effectivePlate(style, over: backdrop))

            let ratio = theme.color(role).contrastRatio(against: plate)

            #expect(ratio >= 4.5, "\(role) on a \(style) plate over \(backdrop): \(ratio)")
        }
    }

    // MARK: - Persistence

    /// A theme persists by its id, so the colours always come from today's tokens.
    @Test func test_theme_persists_by_id() throws {
        let data = try JSONEncoder().encode([theme])

        #expect(String(bytes: data, encoding: .utf8) == #"["raceStudio"]"#)
        #expect(try JSONDecoder().decode([OverlayTheme].self, from: data) == [theme])
    }

    /// An id this build doesn't know reads as the RaceStudio theme.
    @Test func test_an_unknown_theme_reads_as_the_default() throws {
        let decoded = try JSONDecoder().decode([OverlayTheme].self, from: Data(#"["neon"]"#.utf8))

        #expect(decoded == [.raceStudio])
    }
}
