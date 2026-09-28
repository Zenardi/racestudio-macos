import Foundation

// MARK: - Track map (issue 8.6)

/// The track-map panel's reads and cursor binding. The map shows only the
/// selected laps (``rebuildTrackMap()``); with none selected it is empty and
/// ``trackMapNeedsLapSelection`` tells the panel to ask for one.
public extension AnalysisWindowModel {

    /// The assembled racing line, colour-by-channel values, colour scale, and
    /// cursor↔fix mapping feeding the reused `TrackMapView`, scoped to the
    /// selected laps. Empty when the session has no GPS track (or no analysis
    /// pump), or when no lap is selected.
    var trackMap: TrackMapModel { trackMapCache }

    /// `true` when the map is empty only because no lap is selected — the panel
    /// then asks for a selection instead of claiming there is no GPS data. Never
    /// `true` for a session without GPS, or one with no laps to select (that
    /// shows its whole line).
    var trackMapNeedsLapSelection: Bool {
        !gpsTrackPoints.isEmpty && !lapByID.isEmpty && selection.laps.selected.isEmpty
    }

    /// `true` when the session carries a GPS track at all, so an empty map with a
    /// lap selected reads "no GPS in these laps" rather than "no GPS data".
    var hasGPSTrack: Bool { !gpsTrackPoints.isEmpty }

    /// The channel currently colouring the racing line (issue 8.6): the explicit
    /// override while it stays selected, else the first selected channel. `nil`
    /// when nothing is selected.
    var colorChannel: ChannelID? {
        if let override = colorChannelOverride, selection.channels.contains(override) { return override }
        return selection.channels.first
    }

    /// The GPS fix index under the shared cursor — the marker position on the map
    /// (issue 8.6). Reads the live cursor, so it follows every cursor move; `nil`
    /// when the session has no GPS track or the cursor is outside the selected laps.
    var gpsCursorIndex: Int? {
        trackMapCache.index(atTime: linkedCursor.timePosition)
    }

    /// Colour the racing line by `channel` (issue 8.6); ignored when it is not a
    /// selected channel (only a plotted channel can colour the line).
    func setColorChannel(_ channel: ChannelID) {
        guard selection.channels.contains(channel) else { return }
        colorChannelOverride = channel
        rebuildTrackMap()
    }

    /// Move the shared cursor to GPS fix `index` — a hover / click on the map
    /// drives the window's cursor (issue 8.6). A no-op for an out-of-range index or
    /// a dropped fix with no finite time.
    func moveTrackCursor(toFix index: Int) {
        guard let time = trackMapCache.time(atIndex: index), time.isFinite else { return }
        linkedCursor.moveTime(time)
    }
}
