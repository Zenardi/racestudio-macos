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
}
