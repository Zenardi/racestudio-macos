import Foundation
import Testing
@testable import RaceStudioCore

/// How the export sheets write sizes and times (issue 9.14).
@Suite struct ExportFormatTests {

    private let english = Locale(identifier: "en")

    /// Sizes in the Finder's decimal units: gigabytes to a tenth, tens of
    /// megabytes whole, smaller sizes to a tenth; in the locale's numbers.
    @Test func test_sizes_use_decimal_units() {
        #expect(ExportFormat.bytes(3_100_000_000, locale: english) == "3.1 GB")
        #expect(ExportFormat.bytes(3_100_000_000, locale: Locale(identifier: "pt-BR")) == "3,1 GB")
        #expect(ExportFormat.bytes(74_400_000, locale: english) == "74 MB")
        #expect(ExportFormat.bytes(420_000, locale: english) == "0.4 MB")
        #expect(ExportFormat.bytes(-5, locale: english) == "0.0 MB")
    }

    /// Clocks: minutes and seconds, hours past an hour; rounded down unless
    /// asked otherwise; nonsense reads zero.
    @Test func test_durations_read_as_clocks() {
        #expect(ExportFormat.clock(31.9) == "0:31")
        #expect(ExportFormat.clock(31.5, rule: .toNearestOrAwayFromZero) == "0:32")
        #expect(ExportFormat.clock(3_723) == "1:02:03")
        #expect(ExportFormat.clock(-4) == "0:00")
        #expect(ExportFormat.clock(.nan) == "0:00")
        #expect(ExportFormat.clock(.infinity) == "0:00")
    }
}
