import Foundation

/// One onboarding tip shown on the Home dashboard (the app's startup page): an SF
/// Symbol, a short title, and a one-line detail — "how to start" and "how to
/// analyze" guidance a user sees the moment they open the app.
public struct StartTip: Equatable, Sendable, Identifiable {
    public let id: String
    public let symbol: String
    public let title: String
    public let detail: String

    public init(id: String, symbol: String, title: String, detail: String) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.detail = detail
    }
}

/// The static onboarding guidance for the Home dashboard. Kept in the tested core
/// (not hard-coded in the view) so the copy is stable, ordered, and unit-checked;
/// the thin shell renders each tip with brand tokens and its SF Symbol.
public enum StartGuide {

    /// How to get a session into the app.
    public static let gettingStarted: [StartTip] = [
        StartTip(id: "import", symbol: "square.and.arrow.down",
                 title: "Import a session",
                 detail: "Drag a .xrk or .xrz telemetry file onto the window, or use File ▸ Open."),
        StartTip(id: "library", symbol: "square.grid.2x2",
                 title: "Browse your library",
                 detail: "Every imported session is filed by venue, vehicle, and driver — "
                       + "search or filter to find one, then open it."),
        StartTip(id: "device", symbol: "antenna.radiowaves.left.and.right",
                 title: "Download from your logger",
                 detail: "Connect a MyChron over Wi-Fi and pull sessions straight off the device.")
    ]

    /// What to do once a session is open, to actually analyze it.
    public static let analysisTips: [StartTip] = [
        StartTip(id: "cursor", symbol: "cursorarrow.rays",
                 title: "Scrub the linked cursor",
                 detail: "Drag across any plot or the track map — every panel tracks the same "
                       + "point in time and distance."),
        StartTip(id: "overlay", symbol: "chart.xyaxis.line",
                 title: "Overlay & compare laps",
                 detail: "Select two or more laps to overlay them and read the predictive "
                       + "gain/loss delta between them."),
        StartTip(id: "layouts", symbol: "slider.horizontal.3",
                 title: "Pick channels & layouts",
                 detail: "Choose channels, then switch layouts — time/distance, track map, "
                       + "histogram, scatter, and more."),
        StartTip(id: "video", symbol: "film",
                 title: "Sync video & build math channels",
                 detail: "Tie an external session video to the cursor, or derive new channels "
                       + "from an expression.")
    ]
}

/// An at-a-glance summary of the session library, derived from its summaries — the
/// dashboard stats the Home page shows so a returning user sees their data at
/// once. A pure function of the summaries, so it is fully unit-tested.
public struct LibraryDashboard: Equatable, Sendable {

    /// Total indexed sessions.
    public let sessionCount: Int
    /// Distinct, non-empty venues represented in the library.
    public let venueCount: Int
    /// Distinct, non-empty vehicles represented in the library.
    public let vehicleCount: Int
    /// Sum of laps across every session (negative counts are treated as zero).
    public let totalLaps: Int
    /// The most recent session date, or `nil` when the library is empty.
    public let mostRecent: Date?

    public init(sessions: [SessionSummary]) {
        sessionCount = sessions.count
        venueCount = Set(sessions.map(\.venue).filter { !$0.isEmpty }).count
        vehicleCount = Set(sessions.map(\.vehicle).filter { !$0.isEmpty }).count
        totalLaps = sessions.reduce(0) { $0 + max($1.lapCount, 0) }
        mostRecent = sessions.map(\.date).max()
    }

    /// Whether the library has no sessions yet — the Home page shows a first-run
    /// "import your first session" state instead of stats.
    public var isEmpty: Bool { sessionCount == 0 }
}
