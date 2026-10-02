import Foundation

/// The library browser's non-destructive preview of a session (issue 8.14): its
/// laps summary and a racing-line thumbnail, derived purely from a decoded
/// ``Session`` (and its GPS coordinates).
///
/// It reuses the 2.4 ``SessionSummaryViewModel`` for the laps/metadata/channel
/// listing and ``MapPreviewModel`` for the map, so the browser can show "what's in
/// this session" without opening the full analysis workspace. A session with no
/// GPS track still previews its laps; the map is then ``MapPreviewModel/isEmpty``.
public struct SessionPreview: Equatable, Sendable {

    /// The metadata + channel + lap listing (the 2.4 summary model).
    public let summary: SessionSummaryViewModel

    /// The racing-line thumbnail — empty when the session carries no GPS track.
    public let map: MapPreviewModel

    /// - Parameters:
    ///   - session: the decoded session (metadata/channels/laps).
    ///   - coordinates: the session's GPS racing line, or empty for no map.
    public init(session: Session, coordinates: [GPSCoord]) {
        self.summary = SessionSummaryViewModel(session: session)
        self.map = MapPreviewModel(coordinates: coordinates)
    }

    /// Preview `session` with its map drawn from the **best lap** only — one
    /// clean loop of the circuit, without the out-lap, in-lap and pit lane the
    /// whole session wanders through.
    ///
    /// The best lap is the one the laps table flags (the shared
    /// ``SessionSummaryViewModel`` rule), and its fixes are those whose time
    /// falls inside it — lap and GPS times share the samples' clock. With no
    /// valid lap, or a best lap holding fewer than two fixes, the whole track is
    /// drawn instead, so a session never loses its map.
    public init(session: Session, track: [GPSTrackPoint]) {
        self.init(session: session, coordinates: Self.bestLapCoordinates(session.laps, track: track))
    }

    static func bestLapCoordinates(_ laps: [Lap], track: [GPSTrackPoint]) -> [GPSCoord] {
        let whole = track.map(\.coordinate)
        guard let best = SessionSummaryViewModel.bestLapIndex(laps).map({ laps[$0] }) else { return whole }
        let lap = track.filter { $0.time >= best.startTimeS && $0.time <= best.endTimeS }
        return lap.count >= 2 ? lap.map(\.coordinate) : whole
    }
}
