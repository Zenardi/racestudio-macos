import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Frame budgets for the overlay renderer (issue 9.11): the Full telemetry
/// preset — every widget — drawn into a reused BGRA buffer, the export
/// compositor's path, with a different frame each time.
///
/// The issue's budget — ≤ 6 ms per 1920×1080 frame and ≤ 12 ms per 3840×2160
/// frame on Apple silicon — is stated for a **release** build and is asserted
/// only when the tests are compiled optimised, which neither `make` nor CI does
/// — run it by hand, from `app/` (`@testable import` needs `-enable-testing`):
///
///     swift build -c release --target RaceStudioCoreTests -Xswiftc -enable-testing
///     swift test -c release --skip-build --filter OverlayRendererPerformanceTests
///
/// The default debug run (CI's instrumented coverage build, beside the other
/// suites on a runner about three times slower) asserts a generous ceiling that
/// only an algorithmic regression — re-rendering the static layers every frame,
/// say — would break, so the gate is not flaky.
@Suite(.serialized) struct OverlayRendererPerformanceTests {

    /// Frames timed per size, after a warm-up that builds the static layers.
    private static let frameCount = 60

    #if DEBUG
    private static let budget1080p = Duration.milliseconds(80)
    private static let budget2160p = Duration.milliseconds(240)
    #else
    private static let budget1080p = Duration.milliseconds(6)
    private static let budget2160p = Duration.milliseconds(12)
    #endif

    /// A different frame for each index: every readout moves.
    private static func frame(_ index: Int) -> TelemetryFrame {
        let step = Double(index)
        let base = index.isMultiple(of: 2) ? OverlayRenderFixture.midLap : OverlayRenderFixture.lapStartFrame
        let lap = base.lap.map {
            LapClockReading(lap: $0.lap, number: $0.number, elapsed: $0.elapsed + step / 30, last: $0.last,
                            best: $0.best, bestSoFar: $0.bestSoFar, isOutLap: false, isInLap: false,
                            sector: $0.sector)
        }
        return TelemetryFrame(
            time: base.time + step / 30,
            values: [.speed: 80 + step, .rpm: 11_000 + 61 * step, .gear: Double(2 + index % 4),
                     .throttle: Double(index * 7 % 100), .brake: Double(index * 3 % 40), .latG: sin(step / 9),
                     .lonG: cos(step / 7) * 0.8, .waterTemp: 54 + step / 10, .exhaustTemp: 600 + step],
            lap: lap, delta: -0.4 + step / 60, position: base.position,
            gTrail: Array(base.gTrail), channels: ["Oil Temp": 98 + step / 20])
    }

    /// The median time to draw one frame at `width × height`.
    private func medianFrameTime(width: Int, height: Int) throws -> Duration {
        let renderer = OverlayRenderer(layout: OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")),
                                       session: OverlayRenderFixture.session(), track: OverlayRenderFixture.track,
                                       sectors: OverlayRenderFixture.sectors)
        let size = CGSize(width: width, height: height)
        let buffer = try #require(OverlayRenderer.makeBitmapContext(width: width, height: height))
        let frames = (0..<Self.frameCount).map(Self.frame)
        for warmUp in 0..<3 { renderer.draw(frames[warmUp], in: buffer, size: size) }
        let clock = ContinuousClock()
        let times = frames.map { frame in clock.measure { renderer.draw(frame, in: buffer, size: size) } }.sorted()
        return times[times.count / 2]
    }

    /// Given the Full telemetry preset at 1080p, when frames are drawn into a
    /// reused buffer, then the median frame fits the budget.
    @Test func test_a_1080p_frame_fits_the_budget() throws {
        let median = try medianFrameTime(width: 1920, height: 1080)

        print("OverlayRenderer 1920×1080: median \(median) per frame")
        #expect(median <= Self.budget1080p, "\(median) per 1080p frame")
    }

    /// Given the Full telemetry preset at 4K, when frames are drawn into a
    /// reused buffer, then the median frame fits the budget.
    @Test func test_a_2160p_frame_fits_the_budget() throws {
        let median = try medianFrameTime(width: 3840, height: 2160)

        print("OverlayRenderer 3840×2160: median \(median) per frame")
        #expect(median <= Self.budget2160p, "\(median) per 4K frame")
    }
}
