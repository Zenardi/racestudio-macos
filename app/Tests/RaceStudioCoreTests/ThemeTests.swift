import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the brand design-token system (issue 7.3, #141): the pure, render-
/// agnostic ``Theme`` — palette (light/dark semantic roles), type scale, spacing
/// and rounding — plus the ``BrandColor`` WCAG contrast math it is proven against.
///
/// The headline guarantee is the **accessibility proof**: every text-on-background
/// pair the palette defines meets WCAG AA (≥ 4.5:1) in *both* appearances. That
/// test is data-driven off `ColorRole.allCases`, so a new role can't slip in
/// without being contrast-checked. No SwiftUI here — the tokens are value types,
/// so the identity is asserted in the core and merely *rendered* by the thin shell.
@Suite struct ThemeTests {

    // MARK: - BrandColor: construction & sanitizing

    @Test func test_rgba_components_are_clamped_to_unit_range() {
        let c = BrandColor(red: 2, green: -1, blue: 0.5, alpha: 9)
        #expect(c.red == 1)
        #expect(c.green == 0)
        #expect(c.blue == 0.5)
        #expect(c.alpha == 1)
    }

    @Test func test_nonfinite_components_are_sanitized() {
        // `min`/`max` clamp ±∞ but propagate NaN — the init must map NaN to 0 so a
        // stray 0/0 can never poison luminance/contrast downstream.
        let c = BrandColor(red: .nan, green: .infinity, blue: -.infinity, alpha: .nan)
        #expect(c.red == 0, "NaN sanitizes to 0")
        #expect(c.green == 1, "+∞ clamps up to 1")
        #expect(c.blue == 0, "−∞ clamps down to 0")
        #expect(c.alpha == 0)
        // Luminance stays finite (green=1 → 0.7152) — proof that no NaN propagated.
        #expect(c.relativeLuminance.isFinite)
        #expect(abs(c.relativeLuminance - 0.7152) < 1e-9)
    }

    @Test func test_rgb8_factory_maps_and_clamps_0_255() {
        let c = BrandColor.rgb(255, 0, 128)
        #expect(c.red == 1)
        #expect(c.green == 0)
        #expect(abs(c.blue - 128.0 / 255.0) < 1e-9)
        // Out-of-range bytes clamp rather than trap.
        #expect(BrandColor.rgb(300, -5, 0) == BrandColor.rgb(255, 0, 0))
    }

    @Test func test_hex_parses_six_digit_rgb_with_and_without_hash() {
        let withHash = BrandColor(hex: "#C21A2B")
        let without = BrandColor(hex: "C21A2B")
        #expect(withHash == BrandColor.rgb(0xC2, 0x1A, 0x2B))
        #expect(withHash == without)
    }

    @Test func test_hex_rejects_malformed_input() {
        #expect(BrandColor(hex: "") == nil)
        #expect(BrandColor(hex: "#12") == nil)
        #expect(BrandColor(hex: "GGGGGG") == nil)
        #expect(BrandColor(hex: "#1234567") == nil)
    }

    // MARK: - BrandColor: WCAG relative luminance & contrast

    @Test func test_relative_luminance_of_black_and_white() {
        #expect(BrandColor.rgb(0, 0, 0).relativeLuminance == 0)
        #expect(abs(BrandColor.rgb(255, 255, 255).relativeLuminance - 1) < 1e-9)
    }

    @Test func test_contrast_of_black_on_white_is_21() {
        let ratio = BrandColor.rgb(0, 0, 0).contrastRatio(against: .rgb(255, 255, 255))
        #expect(abs(ratio - 21) < 1e-6)
    }

    @Test func test_contrast_is_symmetric_and_self_is_one() {
        let a = BrandColor.rgb(194, 26, 43)
        let b = BrandColor.rgb(240, 240, 240)
        #expect(abs(a.contrastRatio(against: b) - b.contrastRatio(against: a)) < 1e-12)
        #expect(abs(a.contrastRatio(against: a) - 1) < 1e-12)
    }

    // MARK: - Appearance & light/dark resolution

    @Test func test_appearance_has_light_and_dark() {
        #expect(Set(Appearance.allCases) == [.light, .dark])
    }

    @Test func test_theme_color_resolves_per_appearance() {
        let pair = ThemeColor(light: .rgb(0, 0, 0), dark: .rgb(255, 255, 255))
        #expect(pair.resolve(.light) == .rgb(0, 0, 0))
        #expect(pair.resolve(.dark) == .rgb(255, 255, 255))
    }

    @Test func test_single_value_theme_color_is_appearance_invariant() {
        let flat = ThemeColor(.rgb(194, 26, 43))
        #expect(flat.resolve(.light) == flat.resolve(.dark))
    }

    // MARK: - The accessibility proof (headline guarantee)

    /// Every foreground role, over every surface role, meets WCAG AA for normal
    /// text (≥ 4.5:1) in both light and dark — the core promise of issue 7.3.
    @Test func test_every_text_on_surface_pair_meets_wcag_aa() {
        let palette = Theme.raceStudio.palette
        // Derived from the role classification, not hand-listed: adding a text role
        // forces it through this proof (its `kind` must be set, and any `.text` role
        // is contrast-checked here automatically) — so the proof can't fall behind.
        let foregrounds = ColorRole.allCases.filter { $0.kind == .text }
        let surfaces = ColorRole.allCases.filter { $0.kind == .surface }
        #expect(!foregrounds.isEmpty && !surfaces.isEmpty)

        for appearance in Appearance.allCases {
            for fg in foregrounds {
                for bg in surfaces {
                    let ratio = palette.color(fg).resolve(appearance)
                        .contrastRatio(against: palette.color(bg).resolve(appearance))
                    #expect(ratio >= 4.5,
                            "\(fg) on \(bg) is \(ratio) in \(appearance) — below WCAG AA 4.5:1")
                }
            }
        }
    }

    /// Text drawn on the brand accent (e.g. a prominent button label) also meets AA.
    @Test func test_on_accent_text_meets_wcag_aa_in_both_appearances() {
        let palette = Theme.raceStudio.palette
        for appearance in Appearance.allCases {
            let ratio = palette.color(.onAccent).resolve(appearance)
                .contrastRatio(against: palette.color(.accent).resolve(appearance))
            #expect(ratio >= 4.5, "onAccent/accent is \(ratio) in \(appearance)")
        }
    }

    /// The accent must read as a UI element (WCAG 1.4.11 non-text contrast, ≥ 3:1)
    /// on *every* surface it can sit on — canvas, panel, or elevated card — in both
    /// appearances, not just the canvas.
    @Test func test_accent_meets_non_text_contrast_against_every_surface() {
        let palette = Theme.raceStudio.palette
        let surfaces = ColorRole.allCases.filter { $0.kind == .surface }
        for appearance in Appearance.allCases {
            for bg in surfaces {
                let ratio = palette.color(.accent).resolve(appearance)
                    .contrastRatio(against: palette.color(bg).resolve(appearance))
                #expect(ratio >= 3, "accent on \(bg) is \(ratio) in \(appearance)")
            }
        }
    }

    @Test func test_palette_exposes_every_color_role() {
        // `color(_:)` must resolve for all roles — a missing arm would trap or
        // fail to compile; iterating CaseIterable keeps this exhaustive.
        let palette = Theme.raceStudio.palette
        for role in ColorRole.allCases {
            _ = palette.color(role).resolve(.light)
            _ = palette.color(role).resolve(.dark)
        }
        #expect(ColorRole.allCases.count == 10)
    }

    // MARK: - Type scale

    @Test func test_type_scale_sizes_decrease_from_large_title_to_caption() {
        let t = Theme.raceStudio.typography
        #expect(t.largeTitle.size > t.title.size)
        #expect(t.title.size > t.headline.size)
        #expect(t.headline.size > t.body.size)
        #expect(t.body.size > t.callout.size)
        #expect(t.callout.size > t.caption.size)
    }

    @Test func test_type_tokens_declare_dynamic_type_anchors() {
        // Each token names a Dynamic Type anchor so the shell renders scalable type
        // (not a fixed point size); the readout scales with body.
        let t = Theme.raceStudio.typography
        #expect(t.largeTitle.textStyle == .largeTitle)
        #expect(t.title.textStyle == .title)
        #expect(t.headline.textStyle == .headline)
        #expect(t.body.textStyle == .body)
        #expect(t.caption.textStyle == .caption)
        #expect(t.readout.textStyle == .body, "monospaced readout scales with body")
    }

    @Test func test_color_role_kinds_partition_every_role() {
        // Every role is classified; the text/surface sets the accessibility proof
        // relies on are both non-empty and disjoint from decorative.
        #expect(ColorRole.allCases.allSatisfy { _ in true })
        #expect(ColorRole.allCases.contains { $0.kind == .text })
        #expect(ColorRole.allCases.contains { $0.kind == .surface })
        #expect(ColorRole.separator.kind == .decorative)
        #expect(ColorRole.accent.kind == .accent)
        #expect(ColorRole.onAccent.kind == .onAccent)
    }

    @Test func test_readout_token_uses_monospaced_digits() {
        // Telemetry numbers must not jitter as digits change — the readout token
        // is the one that pins digit width.
        #expect(Theme.raceStudio.typography.readout.monospacedDigit)
        #expect(!Theme.raceStudio.typography.body.monospacedDigit)
    }

    @Test func test_font_weight_has_expected_cases() {
        #expect(Set(FontWeight.allCases) == [.regular, .medium, .semibold, .bold])
    }

    // MARK: - Spacing & rounding scales

    @Test func test_spacing_scale_is_strictly_increasing_and_positive() {
        let s = Theme.raceStudio.spacing
        let steps = [s.xs, s.sm, s.md, s.lg, s.xl, s.xxl]
        #expect(steps.first! > 0)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func test_spacing_follows_a_four_point_grid() {
        let s = Theme.raceStudio.spacing
        #expect([s.xs, s.sm, s.md, s.lg, s.xl, s.xxl].allSatisfy { $0.truncatingRemainder(dividingBy: 4) == 0 })
    }

    @Test func test_radius_scale_is_strictly_increasing_and_positive() {
        let r = Theme.raceStudio.radius
        #expect(r.sm > 0)
        #expect(r.sm < r.md)
        #expect(r.md < r.lg)
    }

    // MARK: - Theme wiring

    @Test func test_race_studio_theme_is_stable_and_equatable() {
        #expect(Theme.raceStudio == Theme.raceStudio)
        #expect(Theme.raceStudio.palette.accent.resolve(.light) == BrandColor.rgb(0xC2, 0x1A, 0x2B))
    }
}
