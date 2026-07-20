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
}
