import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelFormatter` (issue 4.4) — unit + precision formatting.
@Suite struct ChannelFormatterTests {

    private struct ChannelsGolden: Decodable { let channels: [ChannelGolden] }
    private struct ChannelGolden: Decodable { let name: String; let decimals: Int }

    @Test func test_formatter_applies_unit_and_precision() {
        #expect(ChannelFormatter(unit: "km/h", precision: 1).string(for: 123.456) == "123.5 km/h")
        #expect(ChannelFormatter(unit: "rpm", precision: 0).string(for: 6543.2) == "6543 rpm")
        // A dimensionless channel has no suffix.
        #expect(ChannelFormatter(unit: "", precision: 2).string(for: 1.5) == "1.50")
        // Negative precision is clamped to zero.
        #expect(ChannelFormatter(unit: "", precision: -3).string(for: 9.9) == "10")
    }

    @Test func test_formatter_renders_nan_as_dash() {
        let formatter = ChannelFormatter(unit: "km/h", precision: 1)
        #expect(formatter.string(for: .nan) == ChannelFormatting.emDash)
        #expect(formatter.string(for: nil) == ChannelFormatting.emDash)
        #expect(formatter.string(for: .infinity) == ChannelFormatting.emDash)
    }

    @Test func test_formatter_normalizes_negative_zero() {
        let formatter = ChannelFormatter(unit: "km/h", precision: 2)
        // -0.0 and a tiny negative that rounds to zero must not show a minus.
        #expect(formatter.string(for: -0.0) == "0.00 km/h")
        #expect(formatter.string(for: -0.001) == "0.00 km/h")
        // A genuinely negative value keeps its sign.
        #expect(formatter.string(for: -1.5) == "-1.50 km/h")
    }

    @Test func test_formatter_clamps_high_precision() {
        // An absurd precision is clamped, not rendered as a giant string.
        let clamped = ChannelFormatter(unit: "", precision: 1000).string(for: 1.5)
        #expect(clamped == ChannelFormatter(unit: "", precision: 15).string(for: 1.5))
        #expect(clamped.count < 30)
    }

    @Test func test_plain_default_is_two_decimals_dimensionless() {
        #expect(ChannelFormatter.plain.string(for: 3.14159) == "3.14")
        #expect(ChannelFormatter.plain.string(for: nil) == ChannelFormatting.emDash)
    }

    @Test func test_formatter_uses_golden_channel_precision() throws {
        let golden: ChannelsGolden = try FixtureLoader.golden("aim_official_test", aspect: "channels")
        // AccelerometerX is recorded at 2 decimals in the golden.
        let accel = try #require(golden.channels.first { $0.name == "AccelerometerX" })
        #expect(accel.decimals == 2)
        #expect(ChannelFormatter(unit: "g", precision: accel.decimals).string(for: -1.2345) == "-1.23 g")
    }
}
