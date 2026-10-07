import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The export's video composition (issue 9.13): the planned footage range as
/// an `AVMutableComposition`, rendered frame by frame through the custom
/// `AVVideoCompositing` ``OverlayCompositor`` — read back here with
/// `AVAssetImageGenerator` at zero tolerance, on synthetic footage whose
/// frames encode their index and a test overlay whose bar encodes the
/// session time.
@Suite struct OverlayCompositorTests {

    /// A sync clock: `video = session × rate + offset`.
    struct Clock: Sendable, CustomTestStringConvertible {
        let offset: Double
        let rate: Double

        func sessionTime(atVideoTime video: Double) -> Double { (video - offset) / rate }
        var testDescription: String { "offset \(offset) s, rate \(rate)" }
    }

    private func movie(_ spec: TestMediaFactory.Spec = .init(), in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent("footage.mp4")
        try await TestMediaFactory.writeMovie(spec, to: url)
        return url
    }

    private func plan(_ url: URL, range: ExportRange = .wholeFootage, clock: Clock = Clock(offset: 0, rate: 1),
                      settings: ExportSettings = ExportSettings(resolution: .source)) async throws -> ExportPlan {
        let footage = try await FootageProbe.probe(url)
        let request = ExportRequest(source: url, sync: VideoSyncModel(videoDuration: footage.duration,
                                                                      offset: clock.offset, rate: clock.rate),
                                    range: range, session: SessionTimeSpan(start: -100, end: 100), settings: settings)
        return try ExportPlan.make(request: request, footage: footage, timeline: .empty, encoders: .all).get()
    }

    private func composition(_ plan: ExportPlan, bar: SessionTimeBar) async throws -> OverlayComposition {
        let telemetry = try await SessionTimeBar.timeline(from: -100, to: 100)
        return try await OverlayComposition.make(plan: plan, overlay: ExportOverlay(drawer: bar, telemetry: telemetry))
    }

    /// Composition frame `index`, rendered through the compositor at its exact time.
    private func frame(_ index: Int, of composition: OverlayComposition, plan: ExportPlan) async throws
        -> FrameReadback {
        let generator = AVAssetImageGenerator(asset: composition.asset)
        generator.videoComposition = composition.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let grid = plan.footage.frameRate
        let time = CMTime(value: CMTimeValue(index * grid.denominator), timescale: CMTimeScale(grid.numerator))
        let (image, actual) = try await generator.image(at: time)
        #expect(actual == time, "frame \(index) is rendered at its own time")
        return FrameReadback(image)
    }

    /// Frame `k` carries the overlay for exactly its session time — with no
    /// offset, with the footage running 1.5 s behind, and with a camera clock
    /// running 0.2% fast — over the footage frame `k` itself.
    @Test(arguments: [Clock(offset: 0, rate: 1), Clock(offset: -1.5, rate: 1), Clock(offset: -1.5, rate: 1.002)])
    func test_frame_k_carries_the_overlay_for_its_session_time(_ clock: Clock) async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try await plan(try await movie(in: dir), clock: clock)
        let bar = SessionTimeBar(origin: clock.sessionTime(atVideoTime: 0))
        let composition = try await composition(plan, bar: bar)

        for index in [0, 31, 89] {
            let frame = try await frame(index, of: composition, plan: plan)

            let expected = bar.length(at: clock.sessionTime(atVideoTime: Double(index) / 30))
            // ±2 px absorbs codec edge blur; a one-frame error moves the bar 3 px.
            #expect(abs(frame.barLength() - expected) <= 2, "frame \(index): bar \(frame.barLength()) ≠ \(expected)")
            #expect(frame.sourcePixel.frameIndex == index, "frame \(index) shows \(frame.sourcePixel)")
        }
    }

    /// A trimmed range starts the composition at its first footage frame:
    /// composition frame `j` is footage frame `first + j`, overlaid for that
    /// footage frame's session time.
    @Test func test_a_trimmed_range_maps_composition_frames_back_to_the_footage() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let clock = Clock(offset: 0.5, rate: 1)
        let plan = try await plan(try await movie(in: dir), range: .span(SessionTimeSpan(start: 1, end: 2)),
                                  clock: clock)
        let bar = SessionTimeBar(origin: 1)
        let composition = try await composition(plan, bar: bar)

        let frame = try await frame(10, of: composition, plan: plan)

        #expect(plan.firstFrame == 45 && plan.frameCount == 30, "video 1.5 … 2.5 s")
        #expect(frame.sourcePixel.frameIndex == 55)
        #expect(abs(frame.barLength() - bar.length(at: clock.sessionTime(atVideoTime: 55.0 / 30))) <= 2)
        #expect(try await composition.asset.load(.duration) == plan.sourceRange.duration)
    }

    /// At 29.97 fps every composition frame keeps its exact rational time and
    /// shows its own footage frame.
    @Test func test_ntsc_frames_keep_their_exact_times() async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ntsc = TestMediaFactory.Spec(frameRate: FrameGrid(numerator: 30_000, denominator: 1_001))
        let plan = try await plan(try await movie(ntsc, in: dir))
        let composition = try await composition(plan, bar: SessionTimeBar(origin: 0))

        for index in [1, 47, 89] {
            #expect(try await frame(index, of: composition, plan: plan).sourcePixel.frameIndex == index)
        }
        #expect(composition.videoComposition.frameDuration == CMTime(value: 1_001, timescale: 30_000))
    }

    /// The composition renders at the planned size and carries the footage's
    /// sound only when the plan keeps it.
    @Test(arguments: [ExportAudio.keep, .drop])
    func test_the_composition_follows_the_plan(_ audio: ExportAudio) async throws {
        let dir = try MediaFixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try await plan(try await movie(in: dir), settings: ExportSettings(resolution: .source, audio: audio))

        let composition = try await composition(plan, bar: SessionTimeBar(origin: 0))

        let soundTracks = try await composition.asset.loadTracks(withMediaType: .audio)
        #expect(composition.videoComposition.renderSize == plan.outputSize)
        #expect(soundTracks.count == (audio == .keep ? 1 : 0))
        #expect(composition.videoComposition.customVideoCompositorClass.map(ObjectIdentifier.init)
                == ObjectIdentifier(OverlayCompositor.self))
    }
}
