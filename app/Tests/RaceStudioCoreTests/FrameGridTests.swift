import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `FrameGrid` (issue 9.7): the footage's nominal frame rate as an
/// exact `numerator / denominator` frames-per-second, so the sync offset can be
/// stepped frame by frame — at 29.97 fps one frame is 1001/30000 s (33.4 ms) and
/// landing on the exact frame the kart crosses the line is otherwise guesswork.
@Suite struct FrameGridTests {

    private let ntsc = FrameGrid(numerator: 30_000, denominator: 1_001)

    // MARK: - Frame duration

    /// 29.97 fps is the NTSC rational 30000/1001: one frame lasts 1001/30000 s.
    @Test func test_ntsc_frame_duration_is_1001_over_30000() {
        #expect(ntsc.frameDuration == 1_001.0 / 30_000.0)
        #expect(abs(ntsc.framesPerSecond - 29.970_029_97) < 1e-8)
    }

    /// Integer rates have integer-reciprocal frame durations.
    @Test(arguments: [(25, 0.04), (30, 1.0 / 30.0), (60, 1.0 / 60.0)])
    func test_integer_rate_frame_duration(fps: Int, duration: Double) {
        #expect(FrameGrid(numerator: fps, denominator: 1).frameDuration == duration)
    }

    /// An unknown (zero) or nonsensical rate falls back to 30 fps rather than a
    /// zero-length or negative frame.
    @Test(arguments: [(0, 1), (30, 0), (-25, 1), (25, -1), (0, 0)])
    func test_unknown_rate_falls_back_to_30_fps(numerator: Int, denominator: Int) {
        let grid = FrameGrid(numerator: numerator, denominator: denominator)

        #expect(grid == FrameGrid.fallback)
        #expect(grid.frameDuration == 1.0 / 30.0)
    }

    /// The rational is kept in lowest terms, so two spellings of one rate compare
    /// equal.
    @Test func test_rate_is_kept_in_lowest_terms() {
        let grid = FrameGrid(numerator: 50, denominator: 2)

        #expect(grid == FrameGrid(numerator: 25, denominator: 1))
        #expect(grid.numerator == 25 && grid.denominator == 1)
    }

    // MARK: - From the asset's nominal frame rate

    /// `AVAssetTrack.nominalFrameRate` is a `Float` (29.97003…); the NTSC family
    /// is recognised and stored as its exact rational.
    @Test(arguments: [(Double(Float(29.97003)), 30_000, 1_001),
                      (23.976, 24_000, 1_001),
                      (59.94, 60_000, 1_001),
                      (25, 25, 1),
                      (30, 30, 1),
                      (Double(Float(60.0)), 60, 1)])
    func test_nominal_rate_maps_to_its_exact_rational(fps: Double, numerator: Int, denominator: Int) {
        #expect(FrameGrid(nominalFrameRate: fps) == FrameGrid(numerator: numerator, denominator: denominator))
    }

    /// Any other rate is kept to the millisecond-frame, in lowest terms.
    @Test func test_an_unusual_nominal_rate_is_kept_to_the_thousandth() {
        #expect(FrameGrid(nominalFrameRate: 12.5) == FrameGrid(numerator: 25, denominator: 2))
    }

    /// An unknown or absurd nominal rate falls back to 30 fps.
    @Test(arguments: [0.0, -29.97, .nan, .infinity, 1e12])
    func test_unknown_nominal_rate_falls_back(fps: Double) {
        #expect(FrameGrid(nominalFrameRate: fps) == FrameGrid.fallback)
    }

    // MARK: - Snapping

    /// A time snaps to the nearest frame boundary.
    @Test func test_snap_rounds_to_the_nearest_frame() {
        let grid = FrameGrid(numerator: 25, denominator: 1)

        #expect(grid.snap(0.05) == 0.04)
        #expect(grid.snap(0.07) == 0.08)
        #expect(grid.snap(-0.05) == -0.04)
    }

    /// Snapping is idempotent: a time already on the grid stays exactly put.
    @Test func test_snap_is_idempotent() {
        for time in [0.0, 0.013, 1.0, -2.71828, 12.345_678, 599.9, -173_000.25] {
            let once = ntsc.snap(time)
            #expect(ntsc.snap(once) == once, "snap(snap(\(time)))")
        }
    }

    // MARK: - Stepping

    /// One step from a grid time moves exactly one frame duration, either way.
    @Test func test_step_moves_exactly_one_frame() {
        let start = ntsc.snap(12.345)

        #expect(abs(ntsc.step(start, frames: 1) - start - ntsc.frameDuration) < 1e-12)
        #expect(abs(start - ntsc.step(start, frames: -1) - ntsc.frameDuration) < 1e-12)
    }

    /// Steps compose: ten single steps land where one ten-frame step does.
    @Test func test_steps_compose() {
        var time = 0.0
        for _ in 0..<10 { time = ntsc.step(time, frames: 1) }

        #expect(time == ntsc.step(0, frames: 10))
        #expect(abs(time - 10 * 1_001.0 / 30_000.0) < 1e-12)
    }

    /// A step from between two frames lands back on the grid, a frame on from the
    /// nearest one — frame stepping always keeps the offset on the frame grid.
    @Test func test_step_from_off_the_grid_lands_on_it() {
        let grid = FrameGrid(numerator: 25, denominator: 1)

        #expect(grid.step(0.05, frames: 1) == 0.08)
        #expect(grid.step(0.05, frames: -1) == 0)
        #expect(ntsc.snap(ntsc.step(0.05, frames: 1)) == ntsc.step(0.05, frames: 1))
    }

    /// A non-finite time is treated as `0`, so a step can never emit `NaN`.
    @Test func test_non_finite_time_is_treated_as_zero() {
        #expect(ntsc.snap(.nan) == 0)
        #expect(ntsc.snap(.infinity) == 0)
        #expect(ntsc.step(.nan, frames: 1) == ntsc.frameDuration)
    }
}
