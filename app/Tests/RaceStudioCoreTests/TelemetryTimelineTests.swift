import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `TelemetryTimeline` / `TelemetryFrame` (issue 9.9): the one
/// immutable, `Sendable` answer to "what was the kart doing at session time
/// `t`?" — every role in canonical units, the lap clock, the live delta, the
/// track position and a one-second G trail — sampled sequentially (the export
/// path) or at random (a seek), with identical results.
@Suite struct TelemetryTimelineTests {

    // MARK: - Fixtures

    private func timeline(_ built: TelemetryFixture.Built = TelemetryFixture.make(),
                          deltaSource: DeltaSource = .computed) async throws -> TelemetryTimeline {
        try await TelemetryTimeline.load(session: built.session, source: built.source,
                                         sectors: built.sectors, deltaSource: deltaSource)
    }

    // MARK: - Channels

    /// Given `t` between samples, then every resolved role is interpolated and
    /// reported in its canonical unit (speed m/s → km/h), and gear is step-held.
    @Test func test_frame_carries_every_role_in_canonical_units() async throws {
        let frame = try await timeline().frame(at: 12.34)

        #expect(abs(try #require(frame.speed) - TelemetryFixture.speedMS(12.34) * 3.6) < 1e-9)
        #expect(abs(try #require(frame.rpm) - TelemetryFixture.rpm(12.34)) < 1e-9)
        #expect(abs(try #require(frame.latG) - TelemetryFixture.lateral(12.34)) < 1e-9)
        #expect(abs(try #require(frame.lonG) - 0.3) < 1e-12)
        #expect(abs(try #require(frame.waterTemp) - TelemetryFixture.water(12.34)) < 1e-9)
        #expect(frame.gear == 3, "12.34 s holds the gear engaged at 10 s")
        #expect(frame.time == 12.34)
        #expect(frame[.rpm] == frame.rpm, "the role subscript reads the same value")
    }

    /// A role the session has no channel for is `nil` — never zero.
    @Test func test_unresolved_roles_are_nil() async throws {
        let frame = try await timeline().frame(at: 12.34)

        #expect(frame.throttle == nil)
        #expect(frame.brake == nil)
        #expect(frame.exhaustTemp == nil)
    }

    /// Pedals pass through in their channels' own units; exhaust temperature is
    /// converted to °C.
    @Test func test_pedals_and_exhaust_temperature_are_carried() async throws {
        let channels = [Channel(name: "Throttle", unit: "%", sampleRateHz: 20, decimals: 0, sampleCount: 2),
                        Channel(name: "Brake Pressure", unit: "bar", sampleRateHz: 20, decimals: 1, sampleCount: 2),
                        Channel(name: "EGT", unit: "°F", sampleRateHz: 20, decimals: 0, sampleCount: 2)]
        let banks = [[DataSample(time: 0, value: 0), DataSample(time: 0.1, value: 100)],
                     [DataSample(time: 0, value: 20), DataSample(time: 0.1, value: 0)],
                     [DataSample(time: 0, value: 1112), DataSample(time: 0.1, value: 1112)]]
        let session = Session(metadata: SessionFixture.make().metadata, channels: channels, laps: [])

        let frame = try await TelemetryTimeline.load(session: session, source: FakeSessionDataSource(banks: banks))
            .frame(at: 0.05)

        #expect(frame.throttle == 50)
        #expect(frame.brake == 10)
        #expect(abs(try #require(frame.exhaustTemp) - 600) < 1e-9)
    }

    /// Given a GPS-only session, then speed, both G, the lap and the track
    /// position are all still there; rpm and gear are `nil`.
    @Test func test_a_gps_only_session_still_yields_speed_g_lap_and_position() async throws {
        let frame = try await timeline(TelemetryFixture.make(gpsOnly: true)).frame(at: 30)

        #expect(frame.speed != nil)
        #expect(frame.latG != nil && frame.lonG != nil)
        #expect(frame.lap?.lap == LapID(1))
        #expect(frame.position != nil)
        #expect(frame.rpm == nil && frame.gear == nil)
    }

    /// Inside a channel's sample gap, that channel alone reads `nil`.
    @Test func test_a_sample_gap_reads_nil_for_that_channel_only() async throws {
        let frame = try await timeline(TelemetryFixture.make(rpmGap: 10..<11)).frame(at: 10.5)

        #expect(frame.rpm == nil)
        #expect(frame.speed != nil)
    }

    /// Outside the recording every value is `nil`, there is no lap, no position
    /// and no trail.
    @Test func test_outside_the_session_everything_is_nil() async throws {
        let timeline = try await timeline()

        for t in [-1.0, 70, .nan] {
            let frame = timeline.frame(at: t)
            #expect(TelemetryRole.allCases.allSatisfy { frame[$0] == nil }, "t \(t)")
            #expect(frame.lap == nil && frame.delta == nil && frame.position == nil)
            #expect(frame.gTrail.isEmpty)
        }
        #expect(timeline.timeRange == 0...61.95)
    }

    // MARK: - Lap clock and delta

    /// The frame's lap reading is the lap clock's, with the split timeline's
    /// sectors, and the best lap is the Summary's.
    @Test func test_frame_lap_matches_the_lap_clock() async throws {
        let timeline = try await timeline()
        let built = TelemetryFixture.make()

        let frame = timeline.frame(at: 25)

        #expect(frame.lap == LapClock(laps: built.session.laps, sectors: built.sectors).reading(at: 25))
        #expect(frame.lap?.sector?.name == "S1")
        #expect(frame.lap?.best?.lap == LapID(1))
    }

    /// The live delta defaults to the best lap as reference: zero along it, the
    /// fake core's series elsewhere (sign kept: lap 0 loses, lap 2 gains).
    @Test func test_delta_defaults_to_the_best_lap() async throws {
        let timeline = try await timeline()

        #expect(timeline.deltaReference == LapID(1))
        #expect(timeline.frame(at: 30).delta == 0)
        #expect(try #require(timeline.frame(at: 10.5).delta) > 0, "slower than the reference: losing")
        #expect(try #require(timeline.frame(at: 50).delta) < 0, "faster than the reference: gaining")
        #expect(timeline.frame(at: 61).delta == nil, "after the in-lap there is no lap to compare")
    }

    /// Switching the reference recomputes the delta against the new lap.
    @Test func test_switching_the_reference_recomputes_the_delta() async throws {
        let timeline = try await timeline()

        let againstOutLap = timeline.withDeltaReference(LapID(0))

        #expect(againstOutLap.deltaReference == LapID(0))
        #expect(againstOutLap.frame(at: 10.5).delta == 0)
        #expect(againstOutLap.frame(at: 30).delta == nil, "the fake core has no series for lap 1 vs lap 0")
    }

    /// The logger's own delta channel can replace the computed delta; it is
    /// reported in seconds. A channel the session lacks reads `nil`.
    @Test func test_logger_delta_channel_is_an_alternative_source() async throws {
        let computed = try await timeline()

        let logger = computed.withDeltaSource(.logger(channel: "Best Run Diff"))

        #expect(logger.deltaSource == .logger(channel: "Best Run Diff"))
        #expect(logger.frame(at: 30.5).delta == 0.2, "100 ms × lap 2, held between 1 Hz samples")
        #expect(computed.withDeltaSource(.logger(channel: "Ghost")).frame(at: 30).delta == nil)
        #expect(logger.withDeltaSource(.computed).frame(at: 30).delta == 0)
    }

    // MARK: - Track position and G trail

    /// The frame's position is the track position model's.
    @Test func test_frame_position_matches_the_track_position() async throws {
        let timeline = try await timeline()

        #expect(timeline.frame(at: 33.3).position == timeline.position.reading(at: 33.3))
    }

    /// The G trail holds the last second of `(lateral, longitudinal)` samples,
    /// oldest first, ending at or before `t`.
    @Test func test_g_trail_holds_the_last_second() async throws {
        let trail = try await timeline().frame(at: 10.01).gTrail

        #expect(trail.count == 20, "20 Hz × 1 s")
        #expect(trail.first?.time == 9.05)
        #expect(trail.last?.time == 10)
        #expect(trail.last.map { abs($0.lateral - TelemetryFixture.lateral(10)) < 1e-12 } == true)
        #expect(trail.allSatisfy { $0.longitudinal == 0.3 })
    }

    /// The trail is a zero-based collection: `gTrail[0]` is its oldest point.
    @Test func test_g_trail_is_zero_based() async throws {
        let trail = try await timeline().frame(at: 10.01).gTrail

        #expect(trail.startIndex == 0)
        #expect(trail[0].time == 9.05)
        #expect(trail[trail.count - 1].time == 10)
    }

    /// A renderer can build a frame by hand (previews, snapshot tests): roles
    /// it gives are reported, the rest are `nil`.
    @Test func test_a_frame_can_be_built_by_hand() {
        let point = GForcePoint(time: 1, lateral: 0.5, longitudinal: -0.8)

        let frame = TelemetryFrame(time: 1, values: [.speed: 84, .gear: 3], lap: nil, delta: -0.21,
                                   position: TrackPositionReading(point: .zero, heading: 90), gTrail: [point])

        #expect(frame.speed == 84 && frame.gear == 3 && frame.rpm == nil)
        #expect(frame.delta == -0.21)
        #expect(Array(frame.gTrail) == [point])
    }

    // MARK: - Sequential vs random

    /// Property: a sequential sweep with one cursor gives exactly the frames
    /// random reads give, at 30 fps across the whole session and beyond it.
    @Test func test_sequential_frames_equal_random_frames() async throws {
        let timeline = try await timeline()
        var cursor = SamplingCursor()

        for frameIndex in 0..<2000 {
            let t = -1 + Double(frameIndex) / 30
            #expect(timeline.frame(at: t, cursor: &cursor) == timeline.frame(at: t), "t \(t)")
        }
    }

    /// Property: a cursor survives backwards seeks and jumps — a scrub — without
    /// changing any answer.
    @Test func test_a_cursor_survives_seeks() async throws {
        let timeline = try await timeline()
        var rng = SeededGenerator(seed: 186)
        var cursor = SamplingCursor()

        for _ in 0..<500 {
            let t = Double.random(in: -2...64, using: &rng)
            #expect(timeline.frame(at: t, cursor: &cursor) == timeline.frame(at: t), "t \(t)")
        }
    }

    /// A cursor carried from one timeline to a re-referenced one is never
    /// trusted for the other's delta curve: its frames equal fresh reads.
    @Test func test_a_cursor_carried_to_a_re_referenced_timeline_is_not_trusted() async throws {
        let original = try await timeline()
        var cursor = SamplingCursor()
        _ = original.frame(at: 10, cursor: &cursor)

        for reference in [LapID(0), LapID(2), LapID(1)] {
            let switched = original.withDeltaReference(reference)
            #expect(switched.frame(at: 10.5, cursor: &cursor) == switched.frame(at: 10.5), "\(reference)")
        }
    }

    // MARK: - Concurrency

    /// The timeline is `Sendable`: four tasks sampling it at once (an export
    /// worker beside the UI) each get exactly the single-threaded frames.
    @Test func test_concurrent_sampling_from_four_tasks_is_identical() async throws {
        let timeline = try await timeline()
        let instants = (0..<1800).map { Double($0) / 30 }
        let expected = instants.map { timeline.frame(at: $0) }

        let results = await withTaskGroup(of: [TelemetryFrame].self) { group in
            for _ in 0..<4 {
                group.addTask {
                    var cursor = SamplingCursor()
                    return instants.map { timeline.frame(at: $0, cursor: &cursor) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 4)
        for frames in results { #expect(frames == expected) }
    }
}
