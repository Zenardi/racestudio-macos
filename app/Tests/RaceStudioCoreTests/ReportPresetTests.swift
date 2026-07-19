import Testing
@testable import RaceStudioCore

/// Tests for `ReportPreset` (issue 8.10): the Channels Report "magic wand"
/// presets — each maps to a default statistic and a set of relevant channels
/// matched (case-insensitively) against the session's channel names.
@Suite struct ReportPresetTests {

    /// A representative channel set spanning health, driver-input, and dynamics
    /// channels, so each preset selects a distinct, predictable subset.
    private let names = ["Speed", "RPM", "Water Temp", "Oil Press",
                         "Throttle Pos", "Brake Pos", "GPS LatAcc", "Steering"]

    @Test func test_preset_cases_and_titles_are_stable() {
        #expect(ReportPreset.allCases == [.vehicleHealth, .racer, .vehiclePerformance])
        #expect(ReportPreset.vehicleHealth.title == "Vehicle Health")
        #expect(ReportPreset.racer.title == "Racer")
        #expect(ReportPreset.vehiclePerformance.title == "Vehicle Performance")
    }

    @Test func test_preset_id_is_the_raw_value() {
        #expect(ReportPreset.vehicleHealth.id == "vehicleHealth")
        #expect(ReportPreset.vehiclePerformance.id == "vehiclePerformance")
    }

    @Test func test_each_preset_carries_a_default_statistic() {
        #expect(ReportPreset.vehicleHealth.defaultStatistic == .maximum)
        #expect(ReportPreset.racer.defaultStatistic == .average)
        #expect(ReportPreset.vehiclePerformance.defaultStatistic == .maximum)
    }

    @Test func test_vehicle_health_selects_the_health_channels() {
        #expect(ReportPreset.vehicleHealth.matchingChannels(in: names)
            == [ChannelID("Water Temp"), ChannelID("Oil Press")])
    }

    @Test func test_racer_selects_the_driver_input_channels() {
        #expect(ReportPreset.racer.matchingChannels(in: names)
            == [ChannelID("RPM"), ChannelID("Throttle Pos"),
                ChannelID("Brake Pos"), ChannelID("Steering")])
    }

    @Test func test_vehicle_performance_selects_the_dynamics_channels() {
        #expect(ReportPreset.vehiclePerformance.matchingChannels(in: names)
            == [ChannelID("Speed"), ChannelID("GPS LatAcc")])
    }

    @Test func test_matching_is_case_insensitive() {
        #expect(ReportPreset.vehiclePerformance.matchingChannels(in: ["SPEED", "rpm"])
            == [ChannelID("SPEED")])
    }

    @Test func test_matching_is_empty_when_nothing_is_relevant() {
        #expect(ReportPreset.vehicleHealth.matchingChannels(in: ["Speed", "RPM"]).isEmpty)
    }

    @Test func test_matching_preserves_input_order_and_deduplicates() {
        // A repeated name collapses to its first occurrence, order preserved.
        #expect(ReportPreset.racer.matchingChannels(in: ["Brake Pos", "RPM", "Brake Pos"])
            == [ChannelID("Brake Pos"), ChannelID("RPM")])
    }
}
