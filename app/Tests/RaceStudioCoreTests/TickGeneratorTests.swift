import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `TickGenerator` (issue 4.1) — the nice-number axis tick algorithm.
@Suite struct TickGeneratorTests {

    /// Golden tick sets — exact expected output, so the test asserts against
    /// known-nice values rather than re-deriving the nice-number math.
    private static let goldens: [(domain: ClosedRange<Double>, expected: [Double])] = [
        (0...1, [0, 0.2, 0.4, 0.6, 0.8, 1.0]),
        (0...100, [0, 20, 40, 60, 80, 100]),
        (3.2...18.7, [5, 10, 15]),
        (-50...50, [-40, -20, 0, 20, 40]),
        (0.001...0.009, [0.002, 0.004, 0.006, 0.008])
    ]

    @Test func test_ticks_are_nice_and_within_domain() {
        for (domain, expected) in Self.goldens {
            let ticks = TickGenerator.ticks(for: domain, targetCount: 5)
            #expect(ticks.count == expected.count, "count for \(domain)")
            for (got, want) in zip(ticks, expected) {
                #expect(abs(got - want) < 1e-9, "tick \(got) vs \(want) in \(domain)")
                #expect(got >= domain.lowerBound - 1e-9 && got <= domain.upperBound + 1e-9,
                        "tick \(got) outside \(domain)")
            }
        }
    }

    @Test func test_ticks_are_strictly_ascending() {
        for (domain, _) in Self.goldens {
            let ticks = TickGenerator.ticks(for: domain, targetCount: 5)
            for i in 1..<ticks.count {
                #expect(ticks[i] > ticks[i - 1], "not ascending in \(domain)")
            }
        }
    }

    @Test func test_tick_count_near_target() {
        let cases: [(ClosedRange<Double>, Int)] = [
            (0...1, 5), (0...100, 5), (0...10, 5), (-1...1, 5), (0...3.7, 5)
        ]
        for (domain, target) in cases {
            let count = TickGenerator.ticks(for: domain, targetCount: target).count
            #expect(abs(count - target) <= 1, "count \(count) not within ±1 of \(target) for \(domain)")
        }
    }

    @Test func test_target_one_rounds_step_down_to_fit_domain() {
        // targetCount 1 gives a raw step == span; the nice-round-up (5) would
        // overflow the domain, so the algorithm rounds the step down to 2.
        let ticks = TickGenerator.ticks(for: 0...3, targetCount: 1)
        #expect(ticks.count == 2)
        #expect(abs(ticks[0] - 0) < 1e-9)
        #expect(abs(ticks[1] - 2) < 1e-9)
    }

    @Test func test_degenerate_domain_and_invalid_target_are_empty() {
        #expect(TickGenerator.ticks(for: 5...5, targetCount: 5).isEmpty)
        #expect(TickGenerator.ticks(for: 0...1, targetCount: 0).isEmpty)
        #expect(TickGenerator.ticks(for: 0...1, targetCount: -3).isEmpty)
    }
}
