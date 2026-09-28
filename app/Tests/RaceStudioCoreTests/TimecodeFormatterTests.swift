import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for rendering a time *position or duration* as `mm:ss`.
///
/// Raw milliseconds are unreadable on a timing screen: a predictive time of
/// `40701 ms` tells a driver nothing, where `00:40.701` is the number on every
/// timing board they have ever looked at. Five channels in a real session carry the
/// unit `ms` — Predictive Time, Best Run Diff, Best Today Diff, Prev Lap Diff and
/// Ref Lap Diff — and the analysis cursor reports its position in seconds.
///
/// Milliseconds are kept in the output because this is lap timing: a tenth is the
/// difference between sessions, so truncating to whole seconds would throw away the
/// only digits that matter.
@Suite struct TimecodeFormatterTests {

    // MARK: - The basic shape

    @Test func test_minutes_are_zero_padded_to_two_digits() {
        #expect(TimecodeFormatter.string(from: 95.25) == "01:35.250")
    }

    @Test func test_under_a_minute_still_shows_the_minutes_field() {
        // A bare "40.701" is ambiguous on a screen that also shows lap times.
        #expect(TimecodeFormatter.string(from: 40.701) == "00:40.701")
    }

    @Test func test_zero_renders_as_zero_not_a_placeholder() {
        #expect(TimecodeFormatter.string(from: 0) == "00:00.000")
    }

    @Test func test_milliseconds_are_kept() {
        #expect(TimecodeFormatter.string(from: 0.001) == "00:00.001")
    }

    // MARK: - Rounding

    @Test func test_rounding_carries_into_seconds() {
        #expect(TimecodeFormatter.string(from: 59.9999) == "01:00.000")
    }

    @Test func test_rounding_carries_into_minutes() {
        #expect(TimecodeFormatter.string(from: 119.9996) == "02:00.000")
    }

    // MARK: - Past an hour

    /// An endurance session runs past an hour; "90:00.000" would be ambiguous, so
    /// the hour is promoted to its own field.
    @Test func test_an_hour_or_more_promotes_the_hour_field() {
        #expect(TimecodeFormatter.string(from: 3_661.5) == "1:01:01.500")
    }

    @Test func test_just_under_an_hour_stays_in_minutes() {
        #expect(TimecodeFormatter.string(from: 3_599.999) == "59:59.999")
    }

    // MARK: - Signed values

    /// The four "Diff" channels are gaps against a reference lap and are routinely
    /// negative — the sign is the whole point, so it leads the value.
    @Test func test_a_negative_value_keeps_its_sign() {
        #expect(TimecodeFormatter.string(from: -12.290) == "-00:12.290")
    }

    @Test func test_a_negative_value_past_a_minute_keeps_its_sign() {
        #expect(TimecodeFormatter.string(from: -95.25) == "-01:35.250")
    }

    /// A value that rounds to zero must not render as "-00:00.000".
    @Test func test_a_tiny_negative_does_not_render_a_negative_zero() {
        #expect(TimecodeFormatter.string(from: -0.0001) == "00:00.000")
    }

    // MARK: - Absent / unusable values

    @Test func test_a_non_finite_value_renders_the_placeholder() {
        #expect(TimecodeFormatter.string(from: .nan) == ChannelFormatting.emDash)
        #expect(TimecodeFormatter.string(from: .infinity) == ChannelFormatting.emDash)
    }

    @Test func test_a_nil_value_renders_the_placeholder() {
        #expect(TimecodeFormatter.string(from: nil) == ChannelFormatting.emDash)
    }

    // MARK: - From milliseconds

    /// The channel values arrive in milliseconds, which is the unit the decoder
    /// reports for them.
    @Test func test_milliseconds_convert_to_the_same_rendering() {
        #expect(TimecodeFormatter.string(fromMilliseconds: 40_701) == "00:40.701")
        #expect(TimecodeFormatter.string(fromMilliseconds: -12_290) == "-00:12.290")
    }
}

/// How a channel whose unit is milliseconds is rendered in the readouts.
@Suite struct ChannelFormatterTimeTests {

    @Test func test_a_millisecond_channel_renders_as_a_timecode() {
        let formatter = ChannelFormatter(unit: "ms", precision: 0)

        #expect(formatter.string(for: 40_701) == "00:40.701")
    }

    /// The unit suffix goes away with the conversion — "00:40.701 ms" would be wrong.
    @Test func test_a_millisecond_channel_drops_the_unit_suffix() {
        #expect(!ChannelFormatter(unit: "ms", precision: 0).string(for: 1_000).contains("ms"))
    }

    @Test func test_a_negative_millisecond_channel_keeps_its_sign() {
        #expect(ChannelFormatter(unit: "ms", precision: 0).string(for: -12_290) == "-00:12.290")
    }

    /// The unit match is on the decoder's spelling, case-insensitively — but a
    /// different unit must be left completely alone.
    @Test func test_the_match_is_case_insensitive() {
        #expect(ChannelFormatter(unit: "mS", precision: 0).string(for: 40_701) == "00:40.701")
    }

    @Test func test_other_units_are_unchanged() {
        #expect(ChannelFormatter(unit: "km/h", precision: 1).string(for: 87.34) == "87.3 km/h")
        #expect(ChannelFormatter(unit: "rpm", precision: 0).string(for: 8_420) == "8420 rpm")
        #expect(ChannelFormatter(unit: "", precision: 2).string(for: 1.5) == "1.50")
    }

    /// A seconds-unit channel is *not* converted: it is already readable, and the
    /// decoder's `s` channels (the time axis) are consumed numerically elsewhere.
    @Test func test_a_seconds_channel_is_left_numeric() {
        #expect(ChannelFormatter(unit: "s", precision: 3).string(for: 40.701) == "40.701 s")
    }

    @Test func test_an_absent_millisecond_value_still_renders_the_placeholder() {
        #expect(ChannelFormatter(unit: "ms", precision: 0).string(for: nil)
                == ChannelFormatting.emDash)
    }
}

/// Values too large to be a time.
///
/// `Int(someDouble)` **traps** when the value is outside `Int`'s range, and
/// `isFinite` does not rule that out — `1e300` is perfectly finite. A channel value
/// is whatever the decoder produced, so a corrupt or absurd sample would crash the
/// app at the point it tried to draw a readout. These pin the guard.
@Suite struct TimecodeOverflowTests {

    @Test func test_an_absurdly_large_value_renders_the_placeholder_rather_than_trapping() {
        #expect(TimecodeFormatter.string(from: 1e300) == ChannelFormatting.emDash)
    }

    @Test func test_an_absurdly_large_negative_value_renders_the_placeholder() {
        #expect(TimecodeFormatter.string(from: -1e300) == ChannelFormatting.emDash)
    }

    @Test func test_a_large_millisecond_channel_value_renders_the_placeholder() {
        #expect(ChannelFormatter(unit: "ms", precision: 0).string(for: 1e300)
                == ChannelFormatting.emDash)
    }

    /// The largest plausible real value still formats — a 24-hour endurance run.
    @Test func test_a_day_long_duration_still_formats() {
        #expect(TimecodeFormatter.string(from: 86_400) == "24:00:00.000")
    }

    /// `LapTimeFormatter` has the same `Int(Double)` conversion and the same latent
    /// trap; a lap duration also comes straight from decoded data.
    @Test func test_the_lap_time_formatter_survives_an_absurd_duration() {
        #expect(LapTimeFormatter.string(from: 1e300) == LapTimeFormatter.placeholder)
    }

    @Test func test_the_lap_time_formatter_still_formats_a_real_lap() {
        #expect(LapTimeFormatter.string(from: 82.248) == "1:22.248")
    }
}
