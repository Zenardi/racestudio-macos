import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `TickGenerator` (issue 4.1) — the nice-number axis tick algorithm.
@Suite struct TickGeneratorTests {

    /// The mantissa of a nice step is 1, 2, or 5 (× a power of ten).
    private func isNiceStep(_ step: Double) -> Bool {
        let exp = floor(log10(step))
        let mantissa = (step / pow(10, exp)).rounded()
        return mantissa == 1 || mantissa == 2 || mantissa == 5
    }

    @Test func test_ticks_are_nice_and_within_domain() {
        let domains: [ClosedRange<Double>] = [
            0...1, 0...100, 3.2...18.7, -50...50, 0.001...0.009
        ]
        for domain in domains {
            let ticks = TickGenerator.ticks(for: domain, targetCount: 5)

            // Non-degenerate domains always yield at least one tick.
            #expect(!ticks.isEmpty, "empty ticks for \(domain)")
            // Strictly ascending.
            for i in 1..<ticks.count {
                #expect(ticks[i] > ticks[i - 1], "not ascending in \(domain)")
            }
            // All inside the domain.
            for tick in ticks {
                #expect(tick >= domain.lowerBound - 1e-9 && tick <= domain.upperBound + 1e-9,
                        "tick \(tick) outside \(domain)")
            }
            // Uniform, nice spacing; every tick is an integer multiple of it.
            if ticks.count >= 2 {
                let step = ticks[1] - ticks[0]
                for i in 1..<ticks.count {
                    #expect(abs((ticks[i] - ticks[i - 1]) - step) < step * 1e-6, "uneven step in \(domain)")
                }
                #expect(isNiceStep(step), "step \(step) not nice in \(domain)")
                for tick in ticks {
                    #expect(abs((tick / step).rounded() - tick / step) < 1e-6, "tick \(tick) not on grid")
                }
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
        #expect(ticks == [0, 2])
        #expect(isNiceStep(ticks[1] - ticks[0]))
    }

    @Test func test_degenerate_domain_and_invalid_target_are_empty() {
        #expect(TickGenerator.ticks(for: 5...5, targetCount: 5).isEmpty)
        #expect(TickGenerator.ticks(for: 0...1, targetCount: 0).isEmpty)
        #expect(TickGenerator.ticks(for: 0...1, targetCount: -3).isEmpty)
    }
}
