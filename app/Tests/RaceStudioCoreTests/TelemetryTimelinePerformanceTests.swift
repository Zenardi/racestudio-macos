import Testing
import Foundation

@testable import RaceStudioCore

/// Budgets for the telemetry timeline (issue 9.9), measured on a synthetic
/// 12-minute, 20 Hz MyChron-like session (every role, GPS, three laps of delta).
///
/// The issue's budget — 18,000 sequential frames (10 min @ 30 fps) in ≤ 50 ms —
/// is stated for a **release** build and is asserted only when the tests are
/// compiled optimised, which neither `make` nor CI does — run it by hand, from
/// `app/` (`@testable import` needs `-enable-testing`):
///
///     swift build -c release --target RaceStudioCoreTests -Xswiftc -enable-testing
///     swift test -c release --skip-build --filter TelemetryTimelinePerformanceTests
///
/// The default debug run (CI's coverage build) asserts a generous ceiling that
/// only an algorithmic regression (a per-frame linear scan, a per-frame core
/// call) would break, so the gate is not flaky on a loaded runner.
@Suite struct TelemetryTimelinePerformanceTests {

    /// 10 minutes of footage at 30 fps.
    private static let frameCount = 18_000

    #if DEBUG
    // ~10x the instrumented debug run measured locally (~0.1 s / ~0.15 s).
    private static let sequentialBudget = Duration.seconds(1)
    private static let randomBudget = Duration.seconds(2)
    #else
    private static let sequentialBudget = Duration.milliseconds(50)
    private static let randomBudget = Duration.milliseconds(200)
    #endif

    private func twelveMinuteTimeline() async throws -> TelemetryTimeline {
        let built = TelemetryFixture.twelveMinutes()
        return try await TelemetryTimeline.load(session: built.session, source: built.source, sectors: built.sectors)
    }

    /// Given a loaded 12-minute session, when 18,000 frames are sampled in
    /// order with one cursor (the export path), then it fits the budget.
    @Test func test_sequential_sampling_of_ten_minutes_at_30fps_fits_the_budget() async throws {
        let timeline = try await twelveMinuteTimeline()
        var cursor = SamplingCursor()
        var checksum = 0.0

        let elapsed = ContinuousClock().measure {
            for index in 0..<Self.frameCount {
                checksum += timeline.frame(at: 60 + Double(index) / 30, cursor: &cursor).speed ?? 0
            }
        }

        print("TelemetryTimeline sequential: \(Self.frameCount) frames in \(elapsed)")
        #expect(checksum > 0)
        #expect(elapsed <= Self.sequentialBudget, "\(elapsed) for \(Self.frameCount) frames")
    }

    /// Random seeks are binary searches (O(log n)): 18,000 seeks in a shuffled
    /// order stay within a few times the sequential cost, not a linear scan each.
    @Test func test_random_seeks_fit_the_budget() async throws {
        let timeline = try await twelveMinuteTimeline()
        var rng = SeededGenerator(seed: 30)
        let instants = (0..<Self.frameCount).map { 60 + Double($0) / 30 }.shuffled(using: &rng)
        var checksum = 0.0

        let elapsed = ContinuousClock().measure {
            for t in instants { checksum += timeline.frame(at: t).rpm ?? 0 }
        }

        print("TelemetryTimeline random: \(Self.frameCount) seeks in \(elapsed)")
        #expect(checksum > 0)
        #expect(elapsed <= Self.randomBudget, "\(elapsed) for \(Self.frameCount) seeks")
    }

    /// Given a 12-minute 20 Hz session, then everything the timeline retains
    /// fits in 20 MB.
    @Test func test_a_twelve_minute_session_fits_in_twenty_megabytes() async throws {
        let timeline = try await twelveMinuteTimeline()

        print("TelemetryTimeline retained payload: \(timeline.approximateByteCount) bytes")
        #expect(timeline.approximateByteCount > 0)
        #expect(timeline.approximateByteCount <= 20 * 1024 * 1024)
    }
}
