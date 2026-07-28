import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the Home / dashboard startup model: the static onboarding tips shown
/// when the app opens (``StartGuide``) and the at-a-glance ``LibraryDashboard``
/// summary derived from the session library. Pure value types — no SwiftUI — so
/// the content and the derived stats are verifiable here; the shell only renders.
@Suite struct HomeModelTests {

    private func summary(id: String = UUID().uuidString, venue: String = "Adria",
                         vehicle: String = "Kart", laps: Int = 3,
                         date: Date = Date(timeIntervalSince1970: 1_000)) -> SessionSummary {
        SessionSummary(id: id, venue: venue, date: date, vehicle: vehicle, driver: "Driver",
                       lapCount: laps, bestLap: nil,
                       sourceURL: URL(fileURLWithPath: "/tmp/\(id).xrk"),
                       importedAt: date, isAvailable: true)
    }

    // MARK: - Start guide (onboarding tips)

    @Test func test_getting_started_tips_are_present_and_well_formed() {
        let tips = StartGuide.gettingStarted
        #expect(tips.count >= 2)
        #expect(tips.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    @Test func test_analysis_tips_are_present_and_well_formed() {
        let tips = StartGuide.analysisTips
        #expect(tips.count >= 2)
        #expect(tips.allSatisfy { !$0.symbol.isEmpty && !$0.title.isEmpty && !$0.detail.isEmpty })
    }

    @Test func test_all_tip_ids_are_unique() {
        let ids = (StartGuide.gettingStarted + StartGuide.analysisTips).map(\.id)
        #expect(Set(ids).count == ids.count, "tip ids must be unique so ForEach is stable")
    }

    // MARK: - Library dashboard summary

    @Test func test_empty_library_dashboard_is_all_zero() {
        let dashboard = LibraryDashboard(sessions: [])
        #expect(dashboard.isEmpty)
        #expect(dashboard.sessionCount == 0)
        #expect(dashboard.venueCount == 0)
        #expect(dashboard.vehicleCount == 0)
        #expect(dashboard.totalLaps == 0)
        #expect(dashboard.mostRecent == nil)
    }

    @Test func test_dashboard_counts_sessions_and_sums_laps() {
        let sessions = [
            summary(venue: "Adria", vehicle: "Kart A", laps: 5),
            summary(venue: "Adria", vehicle: "Kart B", laps: 3),
            summary(venue: "Mugello", vehicle: "Kart A", laps: 7)
        ]
        let dashboard = LibraryDashboard(sessions: sessions)
        #expect(!dashboard.isEmpty)
        #expect(dashboard.sessionCount == 3)
        #expect(dashboard.venueCount == 2, "Adria counted once")
        #expect(dashboard.vehicleCount == 2, "Kart A counted once")
        #expect(dashboard.totalLaps == 15)
    }

    @Test func test_dashboard_ignores_empty_venue_and_vehicle_in_distinct_counts() {
        let sessions = [
            summary(venue: "", vehicle: ""),
            summary(venue: "Adria", vehicle: "Kart")
        ]
        let dashboard = LibraryDashboard(sessions: sessions)
        #expect(dashboard.sessionCount == 2)
        #expect(dashboard.venueCount == 1)
        #expect(dashboard.vehicleCount == 1)
    }

    @Test func test_dashboard_most_recent_is_the_latest_date() {
        let old = Date(timeIntervalSince1970: 1_000)
        let recent = Date(timeIntervalSince1970: 9_000)
        let dashboard = LibraryDashboard(sessions: [
            summary(id: "a", date: old), summary(id: "b", date: recent), summary(id: "c", date: old)
        ])
        #expect(dashboard.mostRecent == recent)
    }
}
