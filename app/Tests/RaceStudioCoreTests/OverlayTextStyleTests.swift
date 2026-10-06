import CoreGraphics
import CoreText
import Testing
@testable import RaceStudioCore

/// The overlay's text (issue 9.11): one condensed face with monospaced digits,
/// sized from the slot it fills, drawn with a dark outline so it reads on any
/// footage.
@Suite struct OverlayTextStyleTests {

    private let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
    private let black = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

    private func isWhite(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.alpha == 255 && pixel.red > 240 && pixel.green > 240 && pixel.blue > 240
    }

    private func isDark(_ pixel: OverlayBitmap.Pixel) -> Bool {
        pixel.alpha == 255 && pixel.red < 15 && pixel.green < 15 && pixel.blue < 15
    }

    // MARK: - Face and size

    @Test func test_the_overlay_draws_in_its_condensed_face() {
        let style = OverlayTextStyle(capHeight: 20, outline: 1)

        #expect(CTFontCopyPostScriptName(style.font) as String == OverlayTextStyle.fontName)
    }

    @Test func test_digits_are_monospaced_so_numbers_do_not_jitter() {
        let style = OverlayTextStyle(capHeight: 30, outline: 1)

        #expect(style.width(of: "1111") == style.width(of: "8888"))
        #expect(style.width(of: "1:11.111") == style.width(of: "0:58.093"))
    }

    /// Every digit takes the same advance, so no number — whatever its digits —
    /// changes width as it counts.
    @Test func test_every_digit_takes_the_same_advance() {
        let style = OverlayTextStyle(capHeight: 30, outline: 1)

        let advances = Set((0...9).map { style.width(of: String($0)) })

        #expect(advances.count == 1)
    }

    @Test func test_capitals_fill_a_fixed_share_of_the_slot() {
        let style = OverlayTextStyle.fitting(height: 100, sizeClass: .medium, outline: 1)

        #expect(abs(style.capHeight - 100 * OverlayTextStyle.capHeightFraction) < 0.01)
    }

    @Test func test_the_size_class_scales_the_text() {
        let medium = OverlayTextStyle.fitting(height: 50, sizeClass: .medium, outline: 1)
        let large = OverlayTextStyle.fitting(height: 50, sizeClass: .large, outline: 1)

        #expect(abs(large.capHeight - medium.capHeight * 1.25) < 0.01)
    }

    @Test func test_a_style_shrinks_to_fit_its_widest_text() {
        let style = OverlayTextStyle.fitting(height: 100, sizeClass: .medium, outline: 1)

        let fitted = style.shrunk(toFit: "8:88.888", width: 60)

        #expect(fitted.width(of: "8:88.888") <= 60)
        #expect(fitted.width(of: "8:88.888") > 58)
    }

    @Test func test_a_style_that_fits_is_never_grown() {
        let style = OverlayTextStyle.fitting(height: 20, sizeClass: .medium, outline: 1)

        #expect(style.shrunk(toFit: "88", width: 1_000).capHeight == style.capHeight)
    }

    // MARK: - Drawing

    @Test func test_text_is_drawn_inside_its_slot() {
        let bitmap = OverlayBitmap(width: 200, height: 80)
        let slot = CGRect(x: 20, y: 20, width: 160, height: 40)
        let style = OverlayTextStyle.fitting(height: slot.height, outline: 1)

        style.draw("1:02.345", in: slot, alignment: .center, color: white, outlineColor: black, in: bitmap.context)

        let ink = bitmap.bounds { !$0.isTransparent }
        #expect(ink != nil)
        #expect(slot.insetBy(dx: -2, dy: -2).contains(ink ?? .null))
    }

    @Test func test_text_is_centred_on_its_capitals() {
        let bitmap = OverlayBitmap(width: 200, height: 100)
        let slot = CGRect(x: 0, y: 30, width: 200, height: 50)
        let style = OverlayTextStyle.fitting(height: slot.height, outline: 1)

        style.draw("88", in: slot, alignment: .center, color: white, outlineColor: black, in: bitmap.context)

        let ink = bitmap.bounds(where: isWhite)
        #expect(abs((ink?.midY ?? 0) - slot.midY) <= 1.5)
        #expect(abs((ink?.midX ?? 0) - slot.midX) <= 1.5)
    }

    @Test func test_leading_and_trailing_text_hug_their_edges() {
        let leading = OverlayBitmap(width: 200, height: 60)
        let trailing = OverlayBitmap(width: 200, height: 60)
        let slot = CGRect(x: 10, y: 10, width: 180, height: 40)
        let style = OverlayTextStyle.fitting(height: slot.height, outline: 1)

        style.draw("88", in: slot, alignment: .leading, color: white, outlineColor: black, in: leading.context)
        style.draw("88", in: slot, alignment: .trailing, color: white, outlineColor: black, in: trailing.context)

        #expect(abs((leading.bounds(where: isWhite)?.minX ?? 0) - slot.minX) <= 4)
        #expect(abs((trailing.bounds(where: isWhite)?.maxX ?? 0) - slot.maxX) <= 4)
    }

    @Test func test_text_carries_a_dark_outline_for_bright_footage() {
        let bitmap = OverlayBitmap(width: 200, height: 80)
        let style = OverlayTextStyle.fitting(height: 60, outline: 2)

        style.draw("88", in: CGRect(x: 0, y: 10, width: 200, height: 60), alignment: .center,
                   color: white, outlineColor: black, in: bitmap.context)

        let fill = bitmap.bounds(where: isWhite) ?? .null
        let ink = bitmap.bounds { !$0.isTransparent } ?? .null
        #expect(bitmap.count(where: isDark) > 100)
        #expect(abs(ink.minX - (fill.minX - 2)) <= 1)
        #expect(abs(ink.maxY - (fill.maxY + 2)) <= 1)
    }

    @Test func test_a_style_without_an_outline_draws_only_the_fill() {
        let bitmap = OverlayBitmap(width: 200, height: 80)
        let style = OverlayTextStyle.fitting(height: 60, outline: 0)

        style.draw("88", in: CGRect(x: 0, y: 10, width: 200, height: 60), color: white, outlineColor: black,
                   in: bitmap.context)

        #expect(bitmap.count(where: isWhite) > 100)
        #expect(bitmap.count(where: isDark) == 0)
    }

    @Test func test_an_empty_string_draws_nothing() {
        let bitmap = OverlayBitmap(width: 50, height: 50)
        let style = OverlayTextStyle.fitting(height: 40, outline: 1)

        style.draw("", in: bitmap.bounds, alignment: .center, color: white, outlineColor: black, in: bitmap.context)

        #expect(bitmap.count { !$0.isTransparent } == 0)
    }

    @Test func test_glyphs_outside_the_face_still_draw() {
        let bitmap = OverlayBitmap(width: 200, height: 60)
        let style = OverlayTextStyle.fitting(height: 50, outline: 1)

        style.draw("✓", in: bitmap.bounds, alignment: .center, color: white, outlineColor: black, in: bitmap.context)

        #expect(bitmap.count(where: isWhite) > 0)
    }
}
