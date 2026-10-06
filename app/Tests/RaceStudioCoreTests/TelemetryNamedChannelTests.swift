import Testing
import Foundation

@testable import RaceStudioCore

/// Session channels sampled by name (issue 9.11) — what a
/// `channelValue(.channel(name))` overlay widget reads, beside the roles: a
/// timeline loaded with extra channel names carries their values in every frame,
/// matched like the channel map (case- and surrounding-whitespace-insensitively).
@Suite struct TelemetryNamedChannelTests {

    private func timeline(channels: [String], rpmGap: Range<Double>? = nil) async throws -> TelemetryTimeline {
        let built = TelemetryFixture.make(rpmGap: rpmGap)
        return try await TelemetryTimeline.load(session: built.session, source: built.source,
                                                sectors: built.sectors, channels: channels)
    }

    // MARK: - Frames built by hand

    @Test func test_a_hand_built_frame_reports_its_named_channels() {
        let frame = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 92])

        #expect(frame.value(ofChannel: "Oil Temp") == 92)
    }

    @Test func test_a_channel_name_matches_ignoring_case_and_surrounding_spaces() {
        let frame = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 92])

        #expect(frame.value(ofChannel: "  oil TEMP ") == 92)
    }

    @Test func test_a_channel_the_frame_does_not_carry_reads_nil() {
        let frame = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 92])

        #expect(frame.value(ofChannel: "Fuel") == nil)
    }

    @Test func test_a_frame_carries_several_named_channels() {
        let frame = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 92, "Lambda": 0.98, "Fuel": 7])

        #expect(frame.value(ofChannel: "Oil Temp") == 92)
        #expect(frame.value(ofChannel: "Lambda") == 0.98)
        #expect(frame.value(ofChannel: "Fuel") == 7)
    }

    /// Two names that match alike are one channel: the name that sorts first
    /// keeps it, whatever order the dictionary iterates in.
    @Test func test_two_names_for_one_channel_keep_the_name_that_sorts_first() {
        let frame = TelemetryFrame(time: 1, values: [:], channels: ["oil temp": 2, "Oil Temp": 1, " OIL TEMP": 3])

        #expect(frame.value(ofChannel: "Oil Temp") == 3)
    }

    @Test func test_two_series_for_one_channel_keep_the_name_that_sorts_first() {
        let low = TelemetrySeries(times: [0, 1], values: [1, 1], maxGap: 2)
        let high = TelemetrySeries(times: [0, 1], values: [9, 9], maxGap: 2)
        let built = TelemetryTimeline(channelMap: TelemetryChannelMap.resolve(channels: []), series: [:],
                                      clock: LapClock(laps: []), position: TrackPosition(track: [], laps: []),
                                      liveDelta: LiveDelta(reference: nil, laps: [],
                                                           distance: TelemetrySeries(times: [], values: [])) { _, _ in
                                          []
                                      },
                                      channels: ["lambda": high, "Lambda": low, "AFR": high])

        #expect(built.frame(at: 0.5).value(ofChannel: "LAMBDA") == 1)
        #expect(built.frame(at: 0.5).value(ofChannel: "afr") == 9)
    }

    @Test func test_frames_differing_only_in_a_named_channel_are_not_equal() {
        let hot = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 92])
        let cold = TelemetryFrame(time: 1, values: [:], channels: ["Oil Temp": 60])

        #expect(hot != cold)
    }

    // MARK: - Sampled from a timeline

    @Test func test_a_timeline_loaded_with_a_channel_name_samples_it() async throws {
        let loaded = try await timeline(channels: ["Water Temp"])

        let value = try #require(loaded.frame(at: 10).value(ofChannel: "Water Temp"))

        #expect(abs(value - TelemetryFixture.water(10)) < 1e-9)
    }

    @Test func test_the_sequential_path_samples_a_named_channel_like_the_random_path() async throws {
        let loaded = try await timeline(channels: ["water temp"])
        var cursor = SamplingCursor()
        let instants = stride(from: 0.0, through: 30, by: 0.37).map { $0 }

        let sequential = instants.map { loaded.frame(at: $0, cursor: &cursor).value(ofChannel: "Water Temp") }
        let random = instants.map { loaded.frame(at: $0).value(ofChannel: "Water Temp") }

        #expect(sequential == random)
        #expect(sequential.allSatisfy { $0 != nil })
    }

    @Test func test_a_named_channel_reads_nil_inside_its_gap() async throws {
        let loaded = try await timeline(channels: ["RPM"], rpmGap: 10..<12)

        #expect(loaded.frame(at: 11).value(ofChannel: "RPM") == nil)
    }

    @Test func test_a_channel_name_the_session_lacks_reads_nil() async throws {
        let loaded = try await timeline(channels: ["Oil Temp"])

        #expect(loaded.frame(at: 10).value(ofChannel: "Oil Temp") == nil)
    }

    @Test func test_a_timeline_loaded_without_channel_names_carries_none() async throws {
        let loaded = try await timeline(channels: [])

        #expect(loaded.frame(at: 10).value(ofChannel: "Water Temp") == nil)
    }

    @Test func test_variants_keep_the_named_channels() async throws {
        let loaded = try await timeline(channels: ["Water Temp"])

        #expect(loaded.withDeltaReference(LapID(2)).frame(at: 10).value(ofChannel: "Water Temp") != nil)
        #expect(loaded.withDeltaSource(.computed).frame(at: 10).value(ofChannel: "Water Temp") != nil)
    }

    @Test func test_named_channels_count_towards_the_retained_bytes() async throws {
        let without = try await timeline(channels: [])
        let with = try await timeline(channels: ["Water Temp"])

        #expect(with.approximateByteCount > without.approximateByteCount)
    }

    @Test func test_the_public_initializer_takes_named_series() {
        let series = TelemetrySeries(times: [0, 1], values: [5, 7], maxGap: 2)
        let odometer = TelemetrySeries(times: [], values: [])
        let built = TelemetryTimeline(channelMap: TelemetryChannelMap.resolve(channels: []), series: [:],
                                      clock: LapClock(laps: []), position: TrackPosition(track: [], laps: []),
                                      liveDelta: LiveDelta(reference: nil, laps: [], distance: odometer) { _, _ in [] },
                                      channels: ["Lambda": series])

        #expect(built.frame(at: 0.5).value(ofChannel: "lambda") == 6)
    }

    // MARK: - What an overlay layout needs

    @Test func test_a_layout_lists_the_session_channels_its_readouts_name() {
        let layout = OverlayLayout(name: "Readouts", widgets: [
            OverlayWidget(id: "a", kind: .channelValue(.channel("Oil Temp")), frame: .unit),
            OverlayWidget(id: "b", kind: .channelValue(.role(.rpm)), frame: .unit),
            OverlayWidget(id: "c", kind: .channelValue(.channel("Lambda")), frame: .unit),
            OverlayWidget(id: "d", kind: .channelValue(.channel("oil temp")), frame: .unit)
        ])

        #expect(layout.sessionChannelNames == ["Oil Temp", "Lambda"])
    }
}
