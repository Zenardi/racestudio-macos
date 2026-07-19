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

    /// The live analysis pump for this session, retained so the workspace can
    /// read windowed samples (issue 8.1). `nil` when the loader vends no data
    /// source (the non-FFI test loaders); the production path always sets it.
    public let analysis: AnalysisSession?

    /// The math-channel evaluator over the retained handle (issue 8.8), so the Math
    /// Channels editor validates/previews expressions against the live session.
    /// `nil` when the loader vends none (the non-FFI test loaders).
    public let evaluator: (any ExpressionEvaluating)?

    public init(session: Session, analysis: AnalysisSession? = nil,
                evaluator: (any ExpressionEvaluating)? = nil) {
        self.session = session
        self.analysis = analysis
        self.evaluator = evaluator
    }

    /// Session-level metadata.
    public var metadata: SessionMetadata { session.metadata }

    /// The decoded channels.
    public var channels: [Channel] { session.channels }

    /// The decoded laps.
    public var laps: [Lap] { session.laps }

    /// Equality is by ``session`` only: `analysis` is a reference-typed pump
    /// derived from the same session, and comparing its identity would spuriously
    /// distinguish two view-models built from equal data (and would break the
    /// `LoadState` equality the M2 tests rely on).
    public static func == (lhs: SessionViewModel, rhs: SessionViewModel) -> Bool {
        lhs.session == rhs.session
    }
}
