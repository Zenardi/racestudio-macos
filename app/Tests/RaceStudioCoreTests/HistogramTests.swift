import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `Histogram` (issue 4.5) — channel-distribution binning.
@Suite struct HistogramTests {

    // MARK: - compute(values:binCount:)

    @Test func test_histogram_counts_sum_to_input_length() {
        let values: [Double] = [1, 2, 2, 3, 4, 5, 5, 5, 8, 10]
        let bins = Histogram.compute(values: values, binCount: 5)
        #expect(bins.count == 5)
        #expect(bins.reduce(0) { $0 + $1.count } == values.count)
        // Contiguous bins covering [min, max].
        #expect(bins.first?.lower == 1)
        #expect(bins.last?.upper == 10)
        for i in 1..<bins.count {
            #expect(bins[i].lower == bins[i - 1].upper, "bin \(i) abuts its predecessor")
        }
    }

    @Test func test_histogram_equal_values_single_bin() throws {
        let bins = Histogram.compute(values: [7, 7, 7, 7], binCount: 5)
        #expect(bins.count == 1, "equal values collapse to a single bin")
        let bin = try #require(bins.first)
        #expect(bin.count == 4)
        #expect(bin.lower < bin.upper, "the single bin is non-degenerate")
        #expect(bin.lower <= 7 && 7 <= bin.upper, "the value falls inside the bin")
    }

    @Test func test_histogram_empty_input_zero_bins() {
        #expect(Histogram.compute(values: [], binCount: 5).isEmpty)
        #expect(Histogram.compute(values: [], binWidth: 10) == .success([]))
    }

    @Test func test_histogram_ignores_nonfinite_values() {
        // NaN / ±∞ can't be placed in [min, max]; they're dropped before binning.
        let bins = Histogram.compute(values: [1, .nan, 2, .infinity, 3, -.infinity], binCount: 2)
        #expect(bins.reduce(0) { $0 + $1.count } == 3, "only the finite values are counted")
        #expect(bins.first?.lower == 1)
        #expect(bins.last?.upper == 3)
    }

    // MARK: - compute(values:binWidth:)

    @Test func test_histogram_rejects_nonpositive_bin_width() {
        #expect(Histogram.compute(values: [1, 2, 3], binWidth: 0) == .failure(.nonPositiveBinWidth))
        #expect(Histogram.compute(values: [1, 2, 3], binWidth: -5) == .failure(.nonPositiveBinWidth))
        #expect(Histogram.compute(values: [1, 2, 3], binWidth: .nan) == .failure(.nonPositiveBinWidth))
    }

    @Test func test_histogram_bin_width_edges_aligned_to_zero() throws {
        let bins = try Histogram.compute(values: [3, 12, 27], binWidth: 10).get()
        #expect(bins.map(\.lower) == [0, 10, 20], "edges are integer multiples of the width")
        #expect(bins.map(\.upper) == [10, 20, 30])
        #expect(bins.map(\.count) == [1, 1, 1])
    }

    @Test func test_histogram_bin_width_equal_values_single_bin() throws {
        // All values identical → one aligned, non-degenerate bin holding them all.
        let bins = try Histogram.compute(values: [10, 10, 10], binWidth: 10).get()
        #expect(bins.count == 1)
        #expect(bins.first?.count == 3)
        #expect(bins.first.map { $0.lower < $0.upper } == true)
    }

    // MARK: - Property tests over random inputs

    @Test func test_histogram_property_counts_sum_and_bins_contiguous() {
        var rng = SeededGenerator(seed: 0x9E37_79B9_7F4A_7C15)
        for _ in 0..<100 {
            let n = Int.random(in: 1...200, using: &rng)
            let values = (0..<n).map { _ in Double.random(in: -100...100, using: &rng) }
            let binCount = Int.random(in: 1...20, using: &rng)
            let bins = Histogram.compute(values: values, binCount: binCount)
            #expect(bins.reduce(0) { $0 + $1.count } == n, "every value lands in exactly one bin")
            for i in 1..<bins.count {
                #expect(abs(bins[i].lower - bins[i - 1].upper) < 1e-9, "bins are contiguous")
            }
        }
    }
}
