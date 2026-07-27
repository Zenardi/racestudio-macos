import Foundation

/// Stable identity for one loaded session within a multi-session comparison
/// (parity gap 9.1, issue #138). ``Session`` is a value snapshot with no identity
/// of its own, so ``MultiSessionModel`` assigns each added session an id —
/// auto-generated in insertion order, or one the caller supplies — under which
/// its laps, colour, and readouts are addressed.
public struct SessionID: Hashable, Sendable {
    public let value: String
    public init(_ value: String) { self.value = value }
}

/// A `(session, lap)` selection key — a lap addressed across sessions (issue
/// 9.1). Multi-session compare overlays laps from different sessions, so a bare
/// ``LapID`` is ambiguous; this pairs it with its owning ``SessionID``.
public struct CrossLapID: Hashable, Sendable {
    public let session: SessionID
    public let lap: LapID

    public init(session: SessionID, lap: LapID) {
        self.session = session
        self.lap = lap
    }
}

/// One session's lap rendered onto the shared cross-session overlay (issue 9.1):
/// its distance-aligned ``ChannelTrace`` (re-based to distance 0 so laps from
/// different sessions share one axis), the owning ``session`` + ``lap``, and the
/// deterministic per-session ``color`` the legend and plot key off.
public struct SessionOverlayTrace: Equatable, Sendable, Identifiable {
    public let session: SessionID
    public let lap: LapID
    public let color: PlotColor
    public let trace: ChannelTrace

    /// Stable per-(session, lap) identity for SwiftUI diffing.
    public var id: String { "\(session.value)#\(lap.index)" }

    public init(session: SessionID, lap: LapID, color: PlotColor, trace: ChannelTrace) {
        self.session = session
        self.lap = lap
        self.color = color
        self.trace = trace
    }
}

/// One session's value at the shared cursor (issue 9.1): each selected session's
/// lap resolved independently at the cursor's along-lap ``distance``. ``value`` is
/// `nil` when that lap carries no data for the overlay channel.
public struct SessionReadout: Equatable, Sendable, Identifiable {
    public let session: SessionID
    public let lap: LapID
    public let distance: Double
    public let value: Double?

    /// Stable per-(session, lap) identity for SwiftUI diffing.
    public var id: String { "\(session.value)#\(lap.index)" }

    public init(session: SessionID, lap: LapID, distance: Double, value: Double?) {
        self.session = session
        self.lap = lap
        self.distance = distance
        self.value = value
    }
}
