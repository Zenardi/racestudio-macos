import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `LapStripPlot` (issue 9.12): the Video + Data panel's strip of
/// speed and RPM over one lap, sampled from the same ``TelemetryTimeline`` the
/// HUD draws from — so the plot and the HUD can never disagree — with the
/// time ↔ position mapping a scrub and the cursor use.
@Suite struct LapStripPlotTests {

    /// The fixture's best lap, `[21, 40)`.
    private let lap = LapID(1)
    private let span = SessionTimeSpan(start: 21, end: 40)

    private func timeline(_ built: TelemetryFixture.Built = TelemetryFixture.make()) async throws
        -> TelemetryTimeline {
        try await TelemetryTimeline.load(session: built.session, source: built.source, sectors: built.sectors)
    }

    private func trace(_ role: TelemetryRole, in plot: LapStripPlot) -> LapStripPlot.Trace? {
        plot.traces.first { $0.role == role }
    }

    // MARK: - Sampling

    /// The lap is sampled evenly, first and last instant included.
    @Test func test_samples_span_the_lap_evenly() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: span, samples: 5)

        #expect(plot.times == [21, 25.75, 30.5, 35.25, 40])
        #expect(plot.lap == lap)
        #expect(plot.span == span)
    }

    /// Each trace holds exactly the value the HUD shows at that instant.
    @Test func test_traces_hold_the_timeline_values() async throws {
        let telemetry = try await timeline()

        let plot = LapStripPlot(timeline: telemetry, lap: lap, span: span, samples: 7)

        let speed = try #require(trace(.speed, in: plot))
        let rpm = try #require(trace(.rpm, in: plot))
        #expect(speed.values == plot.times.map { telemetry.frame(at: $0).speed })
        #expect(rpm.values == plot.times.map { telemetry.frame(at: $0).rpm })
        #expect(plot.traces.map(\.role) == [.speed, .rpm])
    }

    /// A session without an RPM channel plots speed alone.
    @Test func test_a_role_without_a_channel_is_not_traced() async throws {
        let plot = LapStripPlot(timeline: try await timeline(TelemetryFixture.make(gpsOnly: true)), lap: lap,
                                span: span)

        #expect(plot.traces.map(\.role) == [.speed])
    }

    /// Inside a channel's gap its trace has no value, and so no level.
    @Test func test_a_gap_has_no_value() async throws {
        let plot = LapStripPlot(timeline: try await timeline(TelemetryFixture.make(rpmGap: 25..<30)), lap: lap,
                                span: span, samples: 5)

        let rpm = try #require(trace(.rpm, in: plot))
        #expect(rpm.values[1] == nil, "25.75 s is inside the gap")
        #expect(rpm.level(at: 1) == nil)
        #expect(rpm.values[0] != nil)
    }

    /// Fewer than two samples would draw no line: two is the least.
    @Test func test_at_least_two_samples_are_taken() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: span, samples: 0)

        #expect(plot.times == [21, 40])
    }

    // MARK: - Scale

    /// Each trace is scaled to its own range: its lowest value at the bottom
    /// (`0`), its highest at the top (`1`).
    @Test func test_each_trace_fills_its_own_height() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: span, samples: 3)

        let rpm = try #require(trace(.rpm, in: plot))
        #expect(rpm.domain == TelemetryFixture.rpm(21)...TelemetryFixture.rpm(40))
        #expect(rpm.level(at: 0) == 0)
        #expect(rpm.level(at: 1) == 0.5)
        #expect(rpm.level(at: 2) == 1)
        #expect(rpm.level(at: 99) == nil, "no sample there")
    }

    /// A flat trace sits mid-height rather than dividing by zero.
    @Test func test_a_flat_trace_sits_mid_height() {
        let flat = LapStripPlot.Trace(role: .speed, values: [40, 40, nil])

        #expect(flat.domain == 40...40)
        #expect(flat.level(at: 0) == 0.5)
        #expect(flat.level(at: 2) == nil)
    }

    /// A trace with no value at all has no range.
    @Test func test_an_empty_trace_has_no_range() {
        let empty = LapStripPlot.Trace(role: .rpm, values: [nil, nil])

        #expect(empty.domain == nil)
        #expect(empty.level(at: 0) == nil)
        #expect(empty.rangeLabel(units: .metric, locale: Locale(identifier: "en_US")) == nil)
    }

    /// The axis label states the range in the layout's units.
    @Test func test_the_range_label_uses_the_layout_units() {
        let speed = LapStripPlot.Trace(role: .speed, values: [80.4, 160.9])
        let rpm = LapStripPlot.Trace(role: .rpm, values: [8_000, 13_500])
        let en = Locale(identifier: "en_US")

        #expect(speed.rangeLabel(units: .metric, locale: en) == "80–161 km/h")
        #expect(speed.rangeLabel(units: .imperial, locale: en) == "50–100 mph")
        #expect(rpm.rangeLabel(units: .imperial, locale: en) == "8,000–13,500 rpm")
    }

    // MARK: - Time ↔ position

    /// The cursor's place across the strip, and the time a scrub there means,
    /// are inverses inside the lap.
    @Test func test_fraction_and_time_are_inverses() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: span)

        #expect(plot.fraction(atTime: 21) == 0)
        #expect(plot.fraction(atTime: 30.5) == 0.5)
        #expect(plot.fraction(atTime: 40) == 1)
        #expect(plot.time(atFraction: 0.25) == 25.75)
    }

    /// Outside the lap the cursor is off the strip, and a scrub past either end
    /// stops at the lap's edge.
    @Test func test_outside_the_lap_the_cursor_is_off_the_strip() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: span)

        #expect(plot.fraction(atTime: 20) == nil)
        #expect(plot.fraction(atTime: 41) == nil)
        #expect(plot.fraction(atTime: .nan) == nil)
        #expect(plot.time(atFraction: -0.5) == 21)
        #expect(plot.time(atFraction: 1.5) == 40)
        #expect(plot.time(atFraction: .nan) == 21)
    }

    /// A lap with no length places no cursor.
    @Test func test_a_lap_with_no_length_places_no_cursor() async throws {
        let plot = LapStripPlot(timeline: try await timeline(), lap: lap, span: SessionTimeSpan(start: 30, end: 30))

        #expect(plot.fraction(atTime: 30) == nil)
        #expect(plot.time(atFraction: 0.5) == 30)
    }
}
