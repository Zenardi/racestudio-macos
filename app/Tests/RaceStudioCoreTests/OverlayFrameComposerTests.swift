import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import RaceStudioCore

/// One export frame composed (issue 9.13): the source frame scaled and turned
/// upright into the output, and the overlay for **that frame's** session time
/// alpha-blended over it with Core Image — read back pixel by pixel.
@Suite struct OverlayFrameComposerTests {

    private static let output = CGSize(width: 320, height: 180)

    private func context(_ drawer: any OverlayFrameDrawing = SessionTimeBar(origin: 0),
                         telemetry: TelemetryTimeline, offset: Double = 0, rate: Double = 1,
                         session: SessionTimeSpan = SessionTimeSpan(start: -100, end: 100),
                         outside: OutsideSessionOverlay = .hidden, sourceStart: Double = 0,
                         rotation: FootageRotation = .none, size: CGSize = output) -> Framing {
        Framing(context: OverlayRenderContext(overlay: ExportOverlay(drawer: drawer, telemetry: telemetry),
                                              sync: VideoSyncModel(videoDuration: 600, offset: offset, rate: rate),
                                              session: session, outsideSession: outside, sourceStart: sourceStart,
                                              rotation: rotation),
                size: size)
    }

    /// A render context and the output size its frames are composed at.
    private struct Framing {
        let context: OverlayRenderContext
        let size: CGSize
    }

    private func compose(_ source: CVPixelBuffer?, at seconds: Double, _ framing: Framing,
                         composer: OverlayFrameComposer = OverlayFrameComposer()) throws -> FrameReadback {
        let source = try #require(source)
        let output = try #require(TestPixelBuffers.empty(width: Int(framing.size.width),
                                                         height: Int(framing.size.height)))
        try composer.compose(source: source, at: CMTime(seconds: seconds, preferredTimescale: 30_000),
                             context: framing.context, into: output)
        return FrameReadback(output)
    }

    // MARK: - Timing

    /// The bar drawn on a frame encodes the session time that frame maps to:
    /// `t = (sourceStart + compositionTime − offset) / rate`.
    @Test(arguments: [SyncCase(offset: 0, rate: 1, sourceStart: 0, time: 1),
                      SyncCase(offset: -1.5, rate: 1, sourceStart: 0, time: 1),
                      SyncCase(offset: -1.5, rate: 1.002, sourceStart: 0.5, time: 1)])
    func test_the_overlay_is_drawn_for_the_frames_session_time(_ sync: SyncCase) async throws {
        let telemetry = try await SessionTimeBar.timeline(from: -10, to: 10)
        let bar = SessionTimeBar(origin: 0)

        let frame = try compose(TestPixelBuffers.frame(12), at: sync.time,
                                context(bar, telemetry: telemetry, offset: sync.offset, rate: sync.rate,
                                        sourceStart: sync.sourceStart))

        #expect(frame.barLength() == bar.length(at: sync.sessionTime), "\(sync)")
    }

    // MARK: - Blending

    /// Outside the overlay's widgets the output is the source frame, untouched.
    @Test func test_pixels_outside_the_overlay_are_the_source_colour() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: -10, to: 10)

        let frame = try compose(TestPixelBuffers.frame(37), at: 1, context(telemetry: telemetry))

        #expect(frame.sourcePixel.isNear(TestPixelBuffers.colour(ofFrame: 37), tolerance: 1))
        #expect(frame.pixel(x: 200, row: 20).isNear(TestPixelBuffers.colour(ofFrame: 37), tolerance: 1),
                "beside the 90 px bar, in its rows")
    }

    /// A translucent overlay pixel is blended source-over: half red over the
    /// source is half of each.
    @Test func test_a_translucent_overlay_is_alpha_blended() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: -10, to: 10)
        let source = TestPixelBuffers.colour(ofFrame: 37)

        let frame = try compose(TestPixelBuffers.frame(37), at: 1, context(HalfRedBox(), telemetry: telemetry))

        let blended = FramePixel(red: (source.red + 255) / 2, green: source.green / 2, blue: source.blue / 2)
        #expect(frame.pixel(x: HalfRedBox.centre.x, row: HalfRedBox.centre.row).isNear(blended, tolerance: 2))
        #expect(frame.sourcePixel.isNear(source, tolerance: 1))
    }

    // MARK: - Outside the session

    /// By default a frame outside the session carries no overlay at all.
    @Test func test_outside_the_session_the_overlay_is_hidden_by_default() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: 0, to: 10)
        let bar = SessionTimeBar(origin: -2)

        let frame = try compose(TestPixelBuffers.frame(5), at: 1,
                                context(bar, telemetry: telemetry, offset: 2,
                                        session: SessionTimeSpan(start: 0, end: 10)))

        #expect(bar.length(at: -1) == 90, "a bar would be drawn if the overlay were")
        #expect(frame.barLength { $0.isBar || $0.isNoDataBar } == 0, "session time −1 s is before the session")
        #expect(frame.pixel(x: 2, row: 20).isNear(TestPixelBuffers.colour(ofFrame: 5), tolerance: 1))
    }

    /// With the "no data" option, a frame outside the session draws the overlay
    /// from a frame without data, at that frame's session time.
    @Test func test_outside_the_session_the_no_data_overlay_is_drawn_on_request() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: 0, to: 10)
        let bar = SessionTimeBar(origin: -2)

        let frame = try compose(TestPixelBuffers.frame(5), at: 1,
                                context(bar, telemetry: telemetry, offset: 2,
                                        session: SessionTimeSpan(start: 0, end: 10), outside: .noData))

        #expect(frame.barLength { $0.isNoDataBar } == bar.length(at: -1))
    }

    // MARK: - Geometry

    /// A larger source is scaled down to the output, its colour kept.
    @Test func test_a_larger_source_is_scaled_to_the_output() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: -10, to: 10)

        let frame = try compose(TestPixelBuffers.frame(21, width: 640, height: 360), at: 1,
                                context(telemetry: telemetry))

        #expect(frame.width == 320 && frame.height == 180)
        #expect(frame.sourcePixel.isNear(TestPixelBuffers.colour(ofFrame: 21), tolerance: 2))
        #expect(frame.barLength() == 90, "the overlay is drawn at the output size")
    }

    /// Footage stored landscape and turned a quarter clockwise comes out
    /// upright: the stored top-left corner lands top-right.
    @Test func test_rotated_footage_is_turned_upright() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: 50, to: 60)
        let upright = CGSize(width: 180, height: 320)

        let frame = try compose(TestPixelBuffers.frame(9, marker: true), at: 1,
                                context(telemetry: telemetry, session: SessionTimeSpan(start: 50, end: 60),
                                        rotation: .clockwise90, size: upright))

        #expect(frame.pixel(x: 175, row: 4).isBar, "the white corner marker, top-right")
        #expect(frame.pixel(x: 4, row: 4).isNear(TestPixelBuffers.colour(ofFrame: 9), tolerance: 2))
        #expect(frame.pixel(x: 4, row: 315).isNear(TestPixelBuffers.colour(ofFrame: 9), tolerance: 2))
    }

    /// The overlay's static layers are prepared once per output size, not per frame.
    @Test func test_the_overlay_is_prepared_once_per_output_size() async throws {
        let telemetry = try await SessionTimeBar.timeline(from: -10, to: 10)
        let drawer = PrepareCounter()
        let composer = OverlayFrameComposer()
        let small = context(drawer, telemetry: telemetry)
        let large = context(drawer, telemetry: telemetry, size: CGSize(width: 640, height: 360))

        for second in [0.1, 0.2, 0.3] {
            _ = try compose(TestPixelBuffers.frame(1), at: second, small, composer: composer)
        }
        _ = try compose(TestPixelBuffers.frame(1), at: 0.4, large, composer: composer)

        #expect(drawer.preparedSizes == [CGSize(width: 320, height: 180), CGSize(width: 640, height: 360)])
    }
}

/// A sync and frame for the timing tests.
struct SyncCase: Sendable, CustomTestStringConvertible {
    let offset: Double
    let rate: Double
    let sourceStart: Double
    let time: Double

    /// The session time the frame maps to.
    var sessionTime: Double { (sourceStart + time - offset) / rate }

    var testDescription: String { "offset \(offset) s, rate \(rate), from \(sourceStart) s at \(time) s" }
}

/// An overlay of one half-transparent red box, copied (not blended) into the
/// overlay so no translucent fill races CoreGraphics on another thread.
private struct HalfRedBox: OverlayFrameDrawing {
    static let centre = (x: 60, row: 100)

    func prepare(for size: CGSize) {}

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        context.clear(CGRect(origin: .zero, size: size))
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 40, y: size.height - 120, width: 40, height: 40))
    }
}

/// Records every size it is prepared for.
private final class PrepareCounter: OverlayFrameDrawing, @unchecked Sendable {
    private let lock = NSLock()
    private var sizes: [CGSize] = []

    var preparedSizes: [CGSize] { lock.withLock { sizes } }

    func prepare(for size: CGSize) { lock.withLock { sizes.append(size) } }

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        context.clear(CGRect(origin: .zero, size: size))
    }
}
