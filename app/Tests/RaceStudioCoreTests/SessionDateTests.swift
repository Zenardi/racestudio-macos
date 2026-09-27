import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for rendering session timestamps.
///
/// An AiM logger records **local wall-clock with no timezone**, and the decoder
/// turns that into an epoch by reading it as UTC (`parse_datetime_utc`). So the
/// stored `Date` is a *floating* wall-clock, not a true instant: rendering it in
/// the viewer's zone shifts it by their UTC offset — a session logged at 14:18 in
/// Sao Paulo (UTC-3) displayed as 11:18. These tests pin the rule that a session
/// date renders in GMT (reproducing the logger's own digits), while a genuine
/// instant such as `importedAt` renders in the viewer's zone.
@Suite struct SessionDateTests {

    /// 09/25/2026 14:18:29 as the decoder stores it — the user's `stint-1.xrk`.
    private let stint1 = Date(timeIntervalSince1970: 1_790_345_909)

    // MARK: - The logger's wall clock round-trips

    @Test func test_logger_text_reproduces_the_recorded_date_and_time() {
        #expect(SessionDate.loggerText(stint1) == "09/25/2026 14:18:29")
    }

    /// The regression this file exists for: the display zone is pinned to GMT, so
    /// the rendered digits are the logger's own. A developer machine in UTC-3 and a
    /// CI runner in UTC must agree \u2014 which is exactly what broke before.
    @Test func test_session_dates_are_rendered_in_gmt_not_the_viewers_zone() {
        #expect(SessionDate.displayTimeZone.secondsFromGMT() == 0)
    }

    /// Session text must agree with an *explicitly* GMT-formatted instant and so,
    /// on any machine not already on GMT, disagree with the machine's own zone.
    @Test func test_session_text_renders_in_gmt_whatever_the_machine_is_set_to() {
        let gmt = TimeZone(secondsFromGMT: 0)!

        #expect(SessionDate.text(stint1) == SessionDate.instantText(stint1, timeZone: gmt))
    }

    @Test func test_session_components_are_the_digits_the_logger_wrote() {
        let parts = SessionDate.components(of: stint1)

        #expect(parts.year == 2026)
        #expect(parts.month == 9)
        #expect(parts.day == 25)
        #expect(parts.hour == 14)
        #expect(parts.minute == 18)
        #expect(parts.second == 29)
    }

    /// The second stint of the same day, an hour and twenty minutes later — proves
    /// the rule holds across more than one sample.
    @Test func test_a_second_session_the_same_day_renders_its_own_clock() {
        #expect(SessionDate.loggerText(Date(timeIntervalSince1970: 1_790_350_729)) == "09/25/2026 15:38:49")
    }

    // MARK: - A genuine instant still follows the viewer

    /// `importedAt` is stamped by `Date()` — a real instant — so it *must* localise,
    /// unlike the session date. The two rules living side by side is the point.
    @Test func test_an_imported_instant_does_shift_with_the_viewers_timezone() {
        let saoPaulo = TimeZone(identifier: "America/Sao_Paulo")!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        #expect(SessionDate.instantText(stint1, timeZone: saoPaulo)
                != SessionDate.instantText(stint1, timeZone: tokyo))
    }

    // MARK: - Absent / degenerate timestamps

    /// A session whose header carried no parseable date decodes to `datetime_utc`
    /// 0. That is not a real 1970 session, so it is reported as unknown rather than
    /// listed under a misleading date.
    @Test func test_an_unset_timestamp_is_reported_as_unknown() {
        #expect(SessionDate.isUnset(Date(timeIntervalSince1970: 0)))
        #expect(SessionDate.text(Date(timeIntervalSince1970: 0)) == SessionDate.unknownText)
    }

    @Test func test_a_real_timestamp_is_not_unset() {
        #expect(!SessionDate.isUnset(stint1))
    }
}
