import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ChannelStatistics` + `ReportStatistic` (issue 8.10): the pure
/// descriptive-statistics assembly behind the Channels Report — min/max/avg/median
/// and the interpolated percentiles a report cell carries, plus the statistic
/// selector the table + graph plot.
@Suite struct ChannelStatisticsTests {

    /// The sorted ramp 0, 1, …, 10 — its statistics are all exact in `Double`.
    private let ramp = (0...10).map(Double.init)

    // MARK: - Assembly

    @Test func test_from_values_computes_min_max_average_and_median() throws {
        let stats = try #require(ChannelStatistics.from(ramp))
        #expect(stats.count == 11)
        #expect(stats.minimum == 0)
        #expect(stats.maximum == 10)
        #expect(stats.average == 5)
        #expect(stats.median == 5)
    }

    @Test func test_median_of_an_even_count_averages_the_two_middle_values() throws {
        // [0, 1, 2, 3] → median = (1 + 2) / 2 = 1.5.
        let stats = try #require(ChannelStatistics.from([0, 1, 2, 3]))
        #expect(stats.median == 1.5)
    }

    @Test func test_from_ignores_non_finite_values() throws {
        let stats = try #require(ChannelStatistics.from([0, .nan, 5, .infinity, 10, -.infinity]))
        #expect(stats.count == 3, "only the three finite values are counted")
        #expect(stats.minimum == 0)
        #expect(stats.maximum == 10)
        #expect(stats.average == 5)
    }

    @Test func test_from_empty_or_all_non_finite_values_is_nil() {
        #expect(ChannelStatistics.from([]) == nil)
        #expect(ChannelStatistics.from([.nan, .infinity]) == nil, "no finite value → no statistics")
    }

    @Test func test_from_a_single_value_collapses_every_statistic_onto_it() throws {
        let stats = try #require(ChannelStatistics.from([42]))
        #expect(stats.minimum == 42 && stats.maximum == 42)
        #expect(stats.average == 42 && stats.median == 42)
        #expect(stats.percentile95 == 42)
    }

    // MARK: - Percentiles

    @Test func test_percentiles_interpolate_between_ranks() throws {
        let stats = try #require(ChannelStatistics.from(ramp))
        // Linear interpolation on the 0…10 ramp (rank = p/100 · (n − 1)).
        #expect(stats.percentile25 == 2.5)
        #expect(stats.percentile75 == 7.5)
        #expect(stats.percentile90 == 9)
        #expect(stats.percentile95 == 9.5)
    }

    @Test func test_percentile_of_zero_and_hundred_are_the_extremes() {
        let sorted = ramp
        #expect(ChannelStatistics.percentile(0, ofSorted: sorted) == 0)
        #expect(ChannelStatistics.percentile(100, ofSorted: sorted) == 10)
    }

    @Test func test_percentile_of_empty_sorted_input_is_nan() {
        #expect(ChannelStatistics.percentile(50, ofSorted: []).isNaN)
    }

    // MARK: - Statistic selector

    @Test func test_value_for_statistic_selects_the_right_scalar() throws {
        let stats = try #require(ChannelStatistics.from(ramp))
        #expect(stats.value(for: .minimum) == 0)
        #expect(stats.value(for: .maximum) == 10)
        #expect(stats.value(for: .average) == 5)
        #expect(stats.value(for: .median) == 5)
        #expect(stats.value(for: .percentile25) == 2.5)
        #expect(stats.value(for: .percentile75) == 7.5)
        #expect(stats.value(for: .percentile90) == 9)
        #expect(stats.value(for: .percentile95) == 9.5)
    }

    @Test func test_report_statistic_cases_and_titles_are_stable() {
        #expect(ReportStatistic.allCases == [.minimum, .maximum, .average, .median,
                                             .percentile25, .percentile75, .percentile90, .percentile95])
        #expect(ReportStatistic.minimum.title == "Min")
        #expect(ReportStatistic.maximum.title == "Max")
        #expect(ReportStatistic.average.title == "Avg")
        #expect(ReportStatistic.median.title == "Median")
        #expect(ReportStatistic.percentile25.title == "25%")
        #expect(ReportStatistic.percentile95.title == "95%")
    }

    @Test func test_report_statistic_id_is_the_raw_value() {
        #expect(ReportStatistic.minimum.id == "minimum")
        #expect(ReportStatistic.percentile90.id == "percentile90")
    }
}
