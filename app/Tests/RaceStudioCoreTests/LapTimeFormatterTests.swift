import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LapTimeFormatter` (issue 2.4) — `m:ss.mmm` rendering with guards.
@Suite struct LapTimeFormatterTests {

    @Test func test_lap_time_formatting_subminute_and_multiminute() {
        #expect(LapTimeFormatter.string(from: 49.765) == "0:49.765")
        #expect(LapTimeFormatter.string(from: 59.9) == "0:59.900")
        #expect(LapTimeFormatter.string(from: 82.248) == "1:22.248")
        #expect(LapTimeFormatter.string(from: 187.001) == "3:07.001")
    }

    @Test func test_lap_time_formatting_over_one_hour() {
        #expect(LapTimeFormatter.string(from: 3661.5) == "1:01:01.500")
    }

    @Test func test_lap_time_guards_nonfinite_input() {
        #expect(LapTimeFormatter.string(from: .nan) == "—")
        #expect(LapTimeFormatter.string(from: .infinity) == "—")
        #expect(LapTimeFormatter.string(from: -5) == "—")
    }

    // MARK: - Decimal mark and sector form (issue 9.11)

    @Test func test_lap_time_takes_the_decimal_separator_it_is_given() {
        #expect(LapTimeFormatter.string(from: 82.248, decimalSeparator: ",") == "1:22,248")
    }

    @Test func test_sector_time_under_a_minute_drops_the_minutes() {
        #expect(LapTimeFormatter.sectorString(from: 9.5) == "9.500")
        #expect(LapTimeFormatter.sectorString(from: 59.999) == "59.999")
    }

    @Test func test_sector_time_rounding_up_to_a_minute_shows_the_minute() {
        #expect(LapTimeFormatter.sectorString(from: 59.9996) == "1:00.000")
    }

    @Test func test_sector_time_of_a_minute_or_more_is_a_lap_time() {
        #expect(LapTimeFormatter.sectorString(from: 75) == "1:15.000")
    }

    @Test func test_sector_time_takes_the_decimal_separator_it_is_given() {
        #expect(LapTimeFormatter.sectorString(from: 12.3456, decimalSeparator: ",") == "12,346")
    }

    @Test func test_an_empty_or_unusable_sector_time_is_the_placeholder() {
        #expect(LapTimeFormatter.sectorString(from: 0) == "—")
        #expect(LapTimeFormatter.sectorString(from: -1) == "—")
        #expect(LapTimeFormatter.sectorString(from: .nan) == "—")
        #expect(LapTimeFormatter.sectorString(from: 1e300) == "—")
    }
}
