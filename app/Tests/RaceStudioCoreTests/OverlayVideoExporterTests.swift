import AVFoundation
import Foundation
import Testing
import VideoToolbox
@testable import RaceStudioCore

/// The overlay MP4 export end to end (issue 9.13): synthetic footage in, an
/// MP4 out whose duration, frame count, rate, size, codec and sound match the
/// plan, with every frame carrying the overlay of its own session time.
@Suite struct OverlayVideoExporterTests {

    private static let bar = SessionTimeBar(origin: 0)

    private func overlay(_ drawer: any OverlayFrameDrawing = bar) async throws -> ExportOverlay {
        ExportOverlay(drawer: drawer, telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))
    }

    /// The whole clip exported at its own size: the output matches the plan
    /// frame for frame, keeps the sound, and frame `k` is footage frame `k`
    /// with the bar of session time `k / 30`.
    @Test func test_an_export_matches_its_plan() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())

        let events = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(),
                                                                 to: sandbox.destination))

        let movie = try await MovieReadback.read(sandbox.destination, decoding: [0, 45, 89])
        let frame = 1.0 / 30
        #expect(abs(movie.duration - plan.duration) <= frame)
        #expect(movie.frameTimes.count == plan.frameCount)
        #expect(abs(Double(movie.frameRate) - 30) < 0.01)
        #expect(movie.size == plan.outputSize)
        #expect(movie.codec == "avc1")
        #expect(abs((movie.audioDuration ?? 0) - plan.duration) <= 1_024 / 48_000.0, "within one AAC packet")
        for index in [0, 45, 89] {
            let decoded = try #require(movie.frames[index])
            #expect(decoded.sourcePixel.frameIndex == index)
            // ±2 px absorbs codec edge blur; a one-frame error moves the bar 3 px.
            #expect(abs(decoded.barLength() - Self.bar.length(at: Double(index) / 30)) <= 2, "frame \(index)")
        }
        #expect(events.last?.fraction == 1)
        #expect(!sandbox.scratchExists, "the scratch directory is removed")
    }

    /// A lap-like span of 29.97 fps footage exports exactly its frames, each
    /// at exactly `k × 1001 / 30000` s — no rounding to a coarse timescale.
    @Test func test_a_span_of_ntsc_footage_exports_exactly_its_frames() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let footage = try await sandbox.footage(TestMediaFactory.Spec(
            frameRate: FrameGrid(numerator: 30_000, denominator: 1_001)))
        let plan = try await exportPlan(footage, range: .span(SessionTimeSpan(start: 0.5, end: 2)))

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(), to: sandbox.destination))

        let movie = try await MovieReadback.read(sandbox.destination, decoding: [0])
        #expect(plan.firstFrame == 15 && plan.frameCount == 45)
        let exact = (0..<45).map { Double($0 * 1_001) / 30_000 }
        #expect(movie.frameTimes.count == 45)
        #expect(zip(movie.frameTimes, exact).allSatisfy { abs($0 - $1) < 1e-9 }, "\(movie.frameTimes)")
        #expect(abs(movie.duration - plan.duration) < 1e-9)
        #expect(abs(Double(movie.frameRate) - 29.97) < 0.01)
        #expect(try #require(movie.frames[0]).sourcePixel.frameIndex == 15)
    }

    /// Portrait phone footage — stored landscape, turned a quarter
    /// counter-clockwise — exports upright: sides swapped, the stored top-left
    /// corner bottom-left.
    @Test func test_rotated_footage_exports_upright() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let footage = try await sandbox.footage(TestMediaFactory.Spec(rotation: .counterclockwise90, marker: true))
        let plan = try await exportPlan(footage, session: SessionTimeSpan(start: 50, end: 60))

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(), to: sandbox.destination))

        let movie = try await MovieReadback.read(sandbox.destination, decoding: [20])
        let frame = try #require(movie.frames[20])
        let marker = MarkerCorner.bottomLeft.pixel(in: frame), opposite = MarkerCorner.topRight.pixel(in: frame)
        #expect(movie.size == CGSize(width: 180, height: 320))
        #expect(frame.pixel(x: marker.x, row: marker.row).isBar, "the white marker, bottom-left")
        #expect(frame.pixel(x: opposite.x, row: opposite.row).frameIndex == 20)
    }

    /// Dropping the sound leaves the output without an audio track.
    @Test func test_dropping_the_audio_leaves_no_audio_track() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage(),
                                        settings: ExportSettings(resolution: .source, audio: .drop))

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(), to: sandbox.destination))

        #expect(try await MovieReadback.read(sandbox.destination).audioDuration == nil)
    }

    /// HEVC, where this Mac can encode it, comes out as `hvc1` — the tag
    /// QuickTime and Safari play.
    @Test(.enabled(if: EncoderAvailability.system.supportsHEVC, "this Mac has no HEVC encoder"))
    func test_an_hevc_export_is_tagged_hvc1() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage(),
                                        settings: ExportSettings(resolution: .source, codec: .hevc))

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(), to: sandbox.destination))

        let movie = try await MovieReadback.read(sandbox.destination)
        #expect(movie.codec == "hvc1")
        #expect(movie.frameTimes.count == plan.frameCount)
    }

    /// By default a plan checks this Mac's encoders: where no HEVC encoder
    /// exists, an HEVC export is refused up front.
    @Test func test_the_system_encoder_list_decides_hevc_up_front() throws {
        let footage = FootageInfo(duration: 3, frameRate: FrameGrid(numerator: 30, denominator: 1),
                                  naturalSize: CGSize(width: 320, height: 180), rotation: .none, audio: nil,
                                  codec: "avc1")
        let request = ExportRequest(source: URL(fileURLWithPath: "/tmp/x.mp4"), sync: VideoSyncModel(videoDuration: 3),
                                    range: .wholeFootage, session: SessionTimeSpan(start: 0, end: 3),
                                    settings: ExportSettings(codec: .hevc))

        let result = ExportPlan.make(request: request, footage: footage, timeline: .empty)

        #expect((result.failureValue == nil) == EncoderAvailability.system.supportsHEVC)
    }

    /// A codec is offered only where a compression session for it can be
    /// made — an encoder listed but unusable (a virtual machine without the
    /// media engine) does not count.
    @Test func test_a_codec_is_offered_only_where_its_session_can_be_made() {
        #expect(EncoderAvailability.canEncode(kCMVideoCodecType_HEVC) { _ in noErr })
        #expect(!EncoderAvailability.canEncode(kCMVideoCodecType_HEVC) { _ in kVTCouldNotFindVideoEncoderErr })
        #expect(EncoderAvailability.system.supportsHEVC == EncoderAvailability.canEncode(kCMVideoCodecType_HEVC))
    }

    /// Progress arrives while the export runs, never goes backwards, and ends
    /// at every frame done.
    @Test func test_progress_rises_to_every_frame_done() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let slow = SlowSessionTimeBar(delay: 0.005)

        let events = try await collect(sandbox.exporter(progressInterval: .milliseconds(50))
            .export(plan, overlay: try await overlay(slow), to: sandbox.destination))

        let last = try #require(events.last)
        #expect(events.count >= 3)
        #expect(events.map(\.framesDone) == events.map(\.framesDone).sorted())
        #expect(events.map(\.elapsed) == events.map(\.elapsed).sorted())
        #expect(last.framesDone == plan.frameCount && last.totalFrames == plan.frameCount)
        #expect(last.fraction == 1 && last.estimatedRemaining == 0)
        #expect(events.contains { $0.fraction > 0 && $0.fraction < 1 && $0.estimatedRemaining != nil })
    }

    /// A timeline whose lap deltas are still to be fetched (a new reference
    /// lap) has them fetched before the first frame — never from the core on
    /// the compositor's queue, in the middle of the encode.
    @Test func test_lap_deltas_are_fetched_before_the_frames_are_composed() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage(), session: SessionTimeSpan(start: 0, end: 3))
        let laps = [Lap(index: 0, startTimeS: 0, durationS: 1.5, endTimeS: 1.5),
                    Lap(index: 1, startTimeS: 1.5, durationS: 1.5, endTimeS: 3)]
        let fetches = QueueLabels()
        let delta = LiveDelta(reference: LapID(0), laps: laps,
                              distance: TelemetrySeries(times: [0, 3], values: [0, 30], maxGap: .infinity)) { _, _ in
            fetches.record()
            return [DeltaSample(distance: 0, dt: 0), DeltaSample(distance: 15, dt: 0.2)]
        }
        let telemetry = TelemetryTimeline(channelMap: TelemetryChannelMap.resolve(channels: []), series: [:],
                                          clock: LapClock(laps: laps), position: TrackPosition(track: [], laps: laps),
                                          liveDelta: delta)

        _ = try await collect(sandbox.exporter().export(plan, overlay: ExportOverlay(drawer: Self.bar,
                                                                                     telemetry: telemetry),
                                                        to: sandbox.destination))

        #expect(!fetches.labels.isEmpty, "the deltas were fetched")
        #expect(!fetches.labels.contains("com.racestudio.overlay-compositor"), "\(fetches.labels)")
    }

    /// The app's own renderer draws the overlay of a real layout into the export.
    @Test func test_the_overlay_renderer_draws_into_the_export() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let timer = OverlayWidget(kind: .speed, frame: NormalizedRect(x: 0.05, y: 0.05, width: 0.4, height: 0.4),
                                  plate: .solid)
        let renderer = OverlayRenderer(layout: OverlayLayout(name: "Speed", widgets: [timer]),
                                       session: OverlayRenderFixture.session())

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(renderer),
                                                        to: sandbox.destination))

        let frame = try #require(try await MovieReadback.read(sandbox.destination, decoding: [30]).frames[30])
        #expect(frame.pixel(x: 60, row: 40).frameIndex != 30, "the widget's plate covers the footage")
        #expect(frame.sourcePixel.frameIndex == 30)
    }
}
