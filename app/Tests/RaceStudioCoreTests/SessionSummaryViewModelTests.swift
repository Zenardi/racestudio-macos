import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SessionSummaryViewModel` + formatting (issue 2.4) — the metadata
/// panel, channel list, and lap list presentation, asserted against the libxrk
/// golden for `aim_official_test.xrk` (composed from the committed split goldens
/// via `GoldenSession`).
@Suite struct SessionSummaryViewModelTests {

    private static let fixtureName = "aim_official_test"

    private func goldenSummary() throws -> SessionSummaryViewModel {
        SessionSummaryViewModel(session: try GoldenSession.load(Self.fixtureName))
    }

    private func emptyMetadataSession() -> Session {
        Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }

    // MARK: - Metadata

    @Test func test_metadata_fields_match_golden() throws {
        let metadata = try goldenSummary().metadata

        #expect(metadata.driver == "A.GIARDELLI")
        #expect(metadata.track == "Adria Kart")
        #expect(metadata.vehicle == "—") // empty in the golden
    }

    @Test func test_missing_metadata_field_renders_em_dash() {
        let metadata = SessionSummaryViewModel(session: emptyMetadataSession()).metadata

        #expect(metadata.vehicle == "—")
        #expect(metadata.track == "—")
        #expect(metadata.driver == "—")
        #expect(metadata.date == "—") // datetimeUtc == 0
    }

    @Test func test_metadata_date_formatting_is_stable() throws {
        // 1453550944 == 2016-01-23 12:09:04 UTC, rendered with a fixed locale/zone.
        #expect(try goldenSummary().metadata.date == "Jan 23, 2016 at 12:09 PM")
    }

    // MARK: - Channels

    @Test func test_channel_rows_match_golden() throws {
        let channels = try goldenSummary().channels

        #expect(channels.count == 21) // regular (non-GPS) channels
        #expect(channels.first == ChannelRowModel(id: 0, name: "AccelerometerX", unit: "g", rate: "100 Hz"))
        // A rate-less alarm channel renders "—"; a dimensionless channel's unit renders "—".
        #expect(channels.first { $0.name == "CHT Alarm_1" }?.rate == "—")
        #expect(channels.first { $0.name == "Backlight" }?.unit == "—")
    }

    @Test func test_channel_rate_formatting_integer_and_fractional() {
        #expect(ChannelFormatting.rate(hz: 50) == "50 Hz")
        #expect(ChannelFormatting.rate(hz: 100) == "100 Hz")
        #expect(ChannelFormatting.rate(hz: 12.5) == "12.5 Hz")
        #expect(ChannelFormatting.rate(hz: 0) == "—")
        #expect(ChannelFormatting.rate(hz: -1) == "—")
        #expect(ChannelFormatting.rate(hz: .nan) == "—")
    }

    // MARK: - Laps

    @Test func test_lap_rows_number_and_time_from_golden() throws {
        let laps = try goldenSummary().laps

        #expect(laps.count == 11)
        #expect(laps.first?.number == 1)
        #expect(laps.first?.time == "1:22.248") // 82248 ms
    }

    @Test func test_exactly_one_lap_flagged_best() throws {
        let laps = try goldenSummary().laps

        let best = laps.filter(\.isBest)
        #expect(best.count == 1)
        #expect(best.first?.number == 9) // golden best_lap_index 8 -> 1-based number 9
    }

    @Test func test_no_best_when_no_valid_laps() {
        let session = Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [],
            laps: [Lap(index: 0, startTimeS: 0, durationS: .nan, endTimeS: 0)])

        let laps = SessionSummaryViewModel(session: session).laps

        #expect(laps.count == 1)
        #expect(laps.allSatisfy { !$0.isBest })
    }
}
