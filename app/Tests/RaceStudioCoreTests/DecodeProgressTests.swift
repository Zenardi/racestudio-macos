import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `DecodeProgress` (issue 2.5) — the clamped, monotonic progress model.
@Suite struct DecodeProgressTests {

    @Test func test_progress_is_clamped_and_monotonic() {
        // Clamp to 0...1, guarding non-finite input.
        #expect(DecodeProgress(fraction: 1.5).fraction == 1.0)
        #expect(DecodeProgress(fraction: -0.2).fraction == 0.0)
        #expect(DecodeProgress(fraction: .nan).fraction == 0.0)

        // reduce() never decreases the fraction and clamps the incoming value.
        let progress = DecodeProgress(fraction: 0.5, phase: .decoding)
        #expect(progress.reduce(DecodeProgress(fraction: 0.3)).fraction == 0.5)
        #expect(progress.reduce(DecodeProgress(fraction: 0.8)).fraction == 0.8)
        #expect(progress.reduce(DecodeProgress(fraction: 2.0)).fraction == 1.0)
    }
}
