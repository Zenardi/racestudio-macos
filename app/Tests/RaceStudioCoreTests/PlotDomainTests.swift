import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `plotDomain(of:)` and the `clamped(to:)` helper (issue 4.1) — the
/// finite-only axis-range derivation that keeps a stray NaN/±∞ from trapping a
/// ClosedRange or corrupting the downstream scale/viewport math.
@Suite struct PlotDomainTests {

    @Test func test_domain_is_min_max_over_finite_values() {
        #expect(plotDomain(of: [3, -1, 5, 2]) == -1...5)
    }

    @Test func test_domain_ignores_nan_and_infinity() {
        // A leading NaN sample (the crash the review caught) is filtered out…
        #expect(plotDomain(of: [.nan, 2, .nan, 8]) == 2...8)
        // …and so is ±∞, which would otherwise give a non-finite span.
        #expect(plotDomain(of: [1, .infinity, 3]) == 1...3)
        #expect(plotDomain(of: [-.infinity, 4, 6]) == 4...6)
    }

    @Test func test_domain_falls_back_when_no_finite_values() {
        #expect(plotDomain(of: []) == 0...1)
        #expect(plotDomain(of: [.nan, .infinity, -.infinity]) == 0...1)
    }

    @Test func test_domain_pads_a_flat_set() {
        // All-equal values would be a zero-span (inverted-safe) range; pad it.
        #expect(plotDomain(of: [5, 5, 5]) == 4.5...5.5)
    }

    @Test func test_clamped_pins_into_limits() {
        #expect(5.0.clamped(to: 0...10) == 5)
        #expect((-3.0).clamped(to: 0...10) == 0)
        #expect(20.0.clamped(to: 0...10) == 10)
        #expect(7.clamped(to: 0...10) == 7)
    }
}
