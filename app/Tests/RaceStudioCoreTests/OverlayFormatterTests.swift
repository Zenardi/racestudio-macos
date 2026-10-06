import Testing
import Foundation
@testable import RaceStudioCore

/// The overlay's number formatting (issue 9.11): fixed per export, never read
/// from the machine — the decimal mark follows the export locale only.
@Suite struct OverlayFormatterTests {

    private let english = OverlayFormatter(locale: Locale(identifier: "en_US"))
    private let brazilian = OverlayFormatter(locale: Locale(identifier: "pt_BR"))

    // MARK: - Decimal mark

    @Test func test_english_uses_a_decimal_point() {
        #expect(english.decimalSeparator == ".")
    }

    @Test func test_brazilian_portuguese_uses_a_decimal_comma() {
        #expect(brazilian.decimalSeparator == ",")
    }

    @Test func test_the_default_formatter_uses_a_decimal_point() {
        #expect(OverlayFormatter().decimalSeparator == ".")
    }

    // MARK: - Lap times

    @Test func test_a_lap_time_under_a_minute_keeps_its_minutes() {
        #expect(english.lapTime(59.999) == "0:59.999")
    }

    @Test func test_a_lap_time_of_a_minute_rolls_the_minutes() {
        #expect(english.lapTime(60.0) == "1:00.000")
    }

    @Test func test_a_lap_time_rounding_up_to_the_minute_rolls_the_minutes() {
        #expect(english.lapTime(59.9996) == "1:00.000")
    }

    @Test func test_a_lap_time_in_brazilian_portuguese_uses_a_comma() {
        #expect(brazilian.lapTime(62.345) == "1:02,345")
    }

    @Test func test_a_missing_lap_time_is_an_em_dash() {
        #expect(english.lapTime(nil) == "—")
    }

    @Test func test_an_unusable_lap_time_is_an_em_dash() {
        #expect(english.lapTime(.nan) == "—")
        #expect(english.lapTime(-1) == "—")
    }

    // MARK: - Sector times

    @Test func test_a_sector_under_a_minute_drops_the_minutes() {
        #expect(english.sectorTime(12.3456) == "12.346")
    }

    @Test func test_a_sector_of_a_minute_or_more_shows_them() {
        #expect(english.sectorTime(75) == "1:15.000")
    }

    @Test func test_a_sector_in_brazilian_portuguese_uses_a_comma() {
        #expect(brazilian.sectorTime(12.3456) == "12,346")
    }

    @Test func test_an_empty_or_missing_sector_is_an_em_dash() {
        #expect(english.sectorTime(0) == "—")
        #expect(english.sectorTime(nil) == "—")
    }

    // MARK: - Delta

    @Test func test_a_losing_delta_carries_a_plus_sign() {
        #expect(english.delta(0.226) == "+0.23")
    }

    @Test func test_a_gaining_delta_carries_a_minus_sign() {
        #expect(english.delta(-0.41) == "\u{2212}0.41")
    }

    @Test func test_a_delta_rounding_to_zero_carries_no_sign() {
        #expect(english.delta(0.004) == "0.00")
        #expect(english.delta(-0.004) == "0.00")
    }

    @Test func test_a_delta_in_brazilian_portuguese_uses_a_comma() {
        #expect(brazilian.delta(-1.5) == "\u{2212}1,50")
    }

    @Test func test_a_missing_delta_is_an_em_dash() {
        #expect(english.delta(nil) == "—")
        #expect(english.delta(.infinity) == "—")
    }

    // MARK: - Numbers

    @Test func test_a_whole_number_rounds_half_away_from_zero() {
        #expect(english.number(87.5, decimals: 0) == "88")
        #expect(english.number(86.5, decimals: 0) == "87")
    }

    @Test func test_a_number_keeps_its_decimals() {
        #expect(english.number(1.25, decimals: 2) == "1.25")
        #expect(english.number(3, decimals: 1) == "3.0")
        #expect(english.number(0.05, decimals: 2) == "0.05")
    }

    @Test func test_a_negative_number_uses_a_minus_sign() {
        #expect(english.number(-12.34, decimals: 1) == "\u{2212}12.3")
    }

    @Test func test_a_negative_number_rounding_to_zero_carries_no_sign() {
        #expect(english.number(-0.04, decimals: 1) == "0.0")
    }

    @Test func test_a_number_in_brazilian_portuguese_uses_a_comma() {
        #expect(brazilian.number(1.5, decimals: 1) == "1,5")
    }

    @Test func test_a_number_has_no_grouping_separator() {
        #expect(english.number(12_345, decimals: 0) == "12345")
    }

    @Test func test_a_missing_or_unusable_number_is_an_em_dash() {
        #expect(english.number(nil, decimals: 0) == "—")
        #expect(english.number(.nan, decimals: 0) == "—")
        #expect(english.number(1e300, decimals: 0) == "—")
    }

    @Test func test_decimals_are_clamped_to_a_drawable_range() {
        #expect(english.number(1.5, decimals: -2) == "2")
        #expect(english.number(1, decimals: 9) == "1.000000")
    }

    // MARK: - Gear

    @Test func test_gear_zero_is_neutral() {
        #expect(english.gear(0) == "N")
    }

    @Test func test_a_gear_is_a_whole_number() {
        #expect(english.gear(3) == "3")
        #expect(english.gear(2.6) == "3")
    }

    @Test func test_a_missing_or_negative_gear_is_an_em_dash() {
        #expect(english.gear(nil) == "—")
        #expect(english.gear(-1) == "—")
    }
}
