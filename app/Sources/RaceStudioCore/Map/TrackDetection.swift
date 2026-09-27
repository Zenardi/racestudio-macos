import Foundation

/// One gate line from an auto-detected track definition (issue 9.2): the two
/// WGS84 endpoints the car crosses. The start/finish line and each sector
/// boundary of a ``DetectedTrackInfo`` is one of these — the geometry the map and
/// split/segment UI draws in place of hand-placed beacons.
public struct DetectedTrackGate: Equatable, Sendable {
    /// The gate's first endpoint.
    public let start: GPSCoord
    /// The gate's second endpoint.
    public let end: GPSCoord

    public init(start: GPSCoord, end: GPSCoord) {
        self.start = start
        self.end = end
    }

    /// The gate's midpoint — the marker position a sector split draws at. The
    /// longitude is averaged along the shorter arc, so a gate straddling the ±180°
    /// antimeridian yields the point on the dateline rather than its antipode.
    public var midpoint: GPSCoord {
        var deltaLon = end.longitude - start.longitude
        if deltaLon > 180 { deltaLon -= 360 } else if deltaLon < -180 { deltaLon += 360 }
        var lon = start.longitude + deltaLon / 2
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return GPSCoord(latitude: (start.latitude + end.latitude) / 2, longitude: lon)
    }
}

/// The direction a circuit is driven, viewed from above.
///
/// Lap times, sector splits, and a racing line are only comparable within one
/// direction, so it belongs to the track's identity rather than to a session.
public enum TrackDirection: String, Equatable, Sendable, Codable, CaseIterable {
    /// Driven clockwise (Portuguese *horário*).
    case clockwise
    /// Driven counter-clockwise (*anti-horário*).
    case counterClockwise

    /// The direction in words, for display.
    public var title: String {
        switch self {
        case .clockwise: return "Clockwise"
        case .counterClockwise: return "Counter-clockwise"
        }
    }
}

/// A circuit auto-recognized from a session's GPS trace against the bundled track
/// database (issue 9.2), carrying the start/finish + sector geometry read off the
/// matched definition — so the UI places splits from the track, not from beacons.
public struct DetectedTrackInfo: Equatable, Sendable {
    /// Stable track id (e.g. `adria`).
    public let id: String
    /// Human-readable circuit name.
    public let name: String
    /// The layout this definition describes (e.g. `Layout 2`), or `""` when the
    /// venue has a single configuration.
    public let layout: String
    /// The direction the layout is driven, or `nil` when the database does not
    /// record it — reported as absent rather than guessed.
    public let direction: TrackDirection?
    /// The closest-approach tolerance (metres) the match was accepted at.
    public let toleranceM: Double
    /// The definition's start/finish line.
    public let startFinish: DetectedTrackGate
    /// The definition's ordered sector-boundary gates.
    public let sectorGates: [DetectedTrackGate]

    public init(
        id: String, name: String, layout: String = "", direction: TrackDirection? = nil,
        toleranceM: Double, startFinish: DetectedTrackGate, sectorGates: [DetectedTrackGate]
    ) {
        self.id = id
        self.name = name
        self.layout = layout
        self.direction = direction
        self.toleranceM = toleranceM
        self.startFinish = startFinish
        self.sectorGates = sectorGates
    }

    /// The number of segments a lap is cut into: one more than the sector gates.
    public var segmentCount: Int { sectorGates.count + 1 }

    /// The circuit name with its layout appended when there is one, e.g.
    /// `"Kartódromo San Marino — Layout 2"`.
    public var displayName: String {
        layout.isEmpty ? name : "\(name) — \(layout)"
    }
}

/// Chooses the split/segment source for a session (issue 9.2): the auto-detected
/// track when its GPS trace matched a bundled circuit, else the beacon lap markers
/// — the clean fallback when no track is recognized. The map and Split Times views
/// read the start/finish line and sector markers from here.
public struct TrackDetectionModel: Equatable, Sendable {
    /// Where the session's start/finish and sector splits come from.
    public enum Source: Equatable, Sendable {
        /// The circuit was recognized; splits come from its definition.
        case autoDetected(DetectedTrackInfo)
        /// No circuit matched; splits fall back to the logged beacon markers.
        case beacons
    }

    /// The resolved split source for this session.
    public let source: Source

    /// Resolve the split source from an optional detection: a match auto-detects,
    /// `nil` falls back to beacons.
    public init(detected: DetectedTrackInfo?) {
        source = detected.map(Source.autoDetected) ?? .beacons
    }

    /// Whether the splits were auto-detected from the track database (vs. beacons).
    public var isAutoDetected: Bool {
        if case .autoDetected = source { return true }
        return false
    }

    /// The recognized circuit name — including its layout when the venue has more
    /// than one — or `nil` under the beacon fallback.
    public var trackName: String? {
        if case let .autoDetected(track) = source { return track.displayName }
        return nil
    }

    /// The direction the recognized layout is driven, or `nil` under the beacon
    /// fallback or when the database does not record it.
    public var trackDirection: TrackDirection? {
        if case let .autoDetected(track) = source { return track.direction }
        return nil
    }

    /// The recognized track's stable id, or `nil` under the beacon fallback — the
    /// key a user-chosen track name is stored against.
    public var trackID: String? {
        if case let .autoDetected(track) = source { return track.id }
        return nil
    }

    /// The start/finish line's two endpoints when auto-detected — `nil` under the
    /// beacon fallback (start/finish then comes from the lap markers).
    public var startFinishLine: [GPSCoord]? {
        guard case let .autoDetected(track) = source else { return nil }
        return [track.startFinish.start, track.startFinish.end]
    }

    /// The sector-split marker positions (gate midpoints) when auto-detected —
    /// empty under the beacon fallback (which is distance-based, not positional).
    public var sectorMarkers: [GPSCoord] {
        guard case let .autoDetected(track) = source else { return [] }
        return track.sectorGates.map(\.midpoint)
    }

    /// The number of segments the lap is cut into when auto-detected, else `nil`.
    public var segmentCount: Int? {
        guard case let .autoDetected(track) = source else { return nil }
        return track.segmentCount
    }
}

public extension SessionDataSource {
    /// Default: no track detection (the caller falls back to beacon segmentation).
    /// The production `FFISessionDataSource` overrides this to run the Rust matcher.
    func detectTrack() -> DetectedTrackInfo? { nil }
}

public extension AnalysisSession {
    /// The resolved split/segment source for this session (issue 9.2): the
    /// auto-detected track when its GPS trace matched a bundled circuit, else the
    /// beacon lap markers. A convenience over ``detectedTrack`` for the split UI.
    func trackDetection() -> TrackDetectionModel {
        TrackDetectionModel(detected: detectedTrack)
    }
}
