import Foundation

/// Which part of the footage an overlay export covers (issue 9.13).
public enum ExportRange: Equatable, Sendable {
    /// Every frame of the footage, whatever the session covers.
    case wholeFootage
    /// The session's span (``ExportRequest/session``), mapped onto the footage.
    case session
    /// These laps, exported as **one continuous span** from the earliest lap's
    /// start to the latest lap's end — gaps and laps between them included. A
    /// stitched multi-lap export is a later feature.
    case laps([LapID])
    /// A span of session time.
    case span(SessionTimeSpan)
}

/// The output resolution of an overlay export (issue 9.13). A preset names
/// the output's **short edge** — landscape height, portrait width — so the
/// aspect is kept; footage smaller than the preset is never upscaled.
public enum ExportResolution: String, CaseIterable, Codable, Sendable {
    /// The footage's own size (rounded down to even dimensions).
    case source
    /// 2160p (4K UHD).
    case p2160
    /// 1080p (Full HD).
    case p1080
    /// 720p (HD).
    case p720

    /// The short edge the preset scales to, in pixels; `nil` keeps the source's.
    public var shortEdge: Int? {
        switch self {
        case .source: return nil
        case .p2160: return 2_160
        case .p1080: return 1_080
        case .p720: return 720
        }
    }
}

/// The video codec of an overlay export (issue 9.13).
public enum ExportCodec: String, CaseIterable, Codable, Sendable {
    /// H.264 / AVC — plays everywhere.
    case h264
    /// HEVC / H.265 — about 40% smaller for the same quality; needs a newer
    /// player and an HEVC encoder (checked up front, ``EncoderAvailability``).
    case hevc
}

/// What an overlay export does with the footage's sound (issue 9.13).
public enum ExportAudio: String, CaseIterable, Codable, Sendable {
    /// Keep it, trimmed to the exported range.
    case keep
    /// Leave it out: the output has no audio track.
    case drop
}

/// What the overlay shows on frames whose session time lies outside the
/// session (issue 9.13) — footage filmed before the logger started, or after
/// it stopped.
public enum OutsideSessionOverlay: String, CaseIterable, Codable, Sendable {
    /// No overlay: the footage alone.
    case hidden
    /// The overlay's plates with every readout showing "no data" (`—`).
    case noData
}

/// The output settings of an overlay export (issue 9.13). The defaults are
/// the export sheet's: 1080p H.264 with the audio kept, the overlay hidden
/// outside the session.
public struct ExportSettings: Equatable, Codable, Sendable {
    public var resolution: ExportResolution
    public var codec: ExportCodec
    public var audio: ExportAudio
    public var outsideSession: OutsideSessionOverlay

    public init(resolution: ExportResolution = .p1080, codec: ExportCodec = .h264, audio: ExportAudio = .keep,
                outsideSession: OutsideSessionOverlay = .hidden) {
        self.resolution = resolution
        self.codec = codec
        self.audio = audio
        self.outsideSession = outsideSession
    }
}

/// What to export (issue 9.13): which footage, how it is synced to the
/// session, which part of it, and how it is encoded. A pure value — the
/// export sheet re-plans it (``ExportPlan/make(request:footage:timeline:encoders:)``)
/// on every change for its live estimate.
///
/// The overlay itself (its renderer and the telemetry it draws) is not part of
/// the request: drawing needs the session's channels, track and sectors, which
/// travel with the export as an ``ExportOverlay``.
public struct ExportRequest: Equatable, Sendable {
    /// The footage file.
    public var source: URL
    /// The footage's alignment to the session clock.
    public var sync: VideoSyncModel
    /// The part of the footage to export.
    public var range: ExportRange
    /// The session's own span on its clock (`0…duration`): what
    /// ``ExportRange/session`` exports, and where the overlay has data.
    public var session: SessionTimeSpan
    /// How the output is encoded.
    public var settings: ExportSettings

    public init(source: URL, sync: VideoSyncModel, range: ExportRange, session: SessionTimeSpan,
                settings: ExportSettings = ExportSettings()) {
        self.source = source
        self.sync = sync
        self.range = range
        self.session = session
        self.settings = settings
    }
}
