import Foundation

/// An observable wrapper around a decoded ``Session`` — the value `SessionStore`
/// publishes in its `.loaded` state (issue 2.2).
///
/// It exposes the decoded metadata/channels/laps directly; human-readable
/// formatting (durations, dates, counts) is deferred to the summary screen
/// (2.4), and richer error surfacing to 2.5.
public struct SessionViewModel: Equatable, Sendable {

    /// The decoded session this view-model presents.
    public let session: Session

    public init(session: Session) {
        self.session = session
    }

    /// Session-level metadata.
    public var metadata: SessionMetadata { session.metadata }

    /// The decoded channels.
    public var channels: [Channel] { session.channels }

    /// The decoded laps.
    public var laps: [Lap] { session.laps }
}

/// A typed failure importing a session.
///
/// Minimal placeholder for 2.2 — mapping decode/IO errors to user-facing
/// messages is issue 2.5.
public enum ImportError: Error, Equatable, Sendable {
    /// Decoding the file failed.
    case decodeFailed
}
