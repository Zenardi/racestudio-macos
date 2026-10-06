import Foundation

/// A ``SessionDataSource`` that can match camera audio against its session
/// (issue 9.8). The production `FFISessionDataSource` adopts it over the live
/// Rust handle; a source without it (a build without the core) cannot
/// auto-sync, and the panel says so.
public protocol AudioSyncEstimatorProviding {
    /// The estimator over this source's session, or `nil` when there is none.
    var audioSyncEstimator: (any AudioSyncEstimating)? { get }
}

/// The session side of *Auto-sync from engine sound* (issue 9.8).
public extension AnalysisSession {

    /// The session's RPM channel, resolved as the telemetry overlay resolves its
    /// `rpm` role (by name and unit), or `nil` when it has none.
    var rpmChannel: TelemetryChannelBinding? {
        TelemetryChannelMap.resolve(channels: session.channels).binding(for: .rpm)
    }

    /// Whether this build can estimate an offset at all.
    var canEstimateAudioSync: Bool { estimator != nil }

    /// The session-time span (seconds) channel `channelIndex`'s samples cover —
    /// two single-sample reads, never the whole channel — or `nil` for an unknown
    /// or empty channel.
    func sampleSpan(channelIndex: Int) -> ClosedRange<Double>? {
        guard session.channels.indices.contains(channelIndex) else { return nil }
        let count = session.channels[channelIndex].sampleCount
        guard count > 0 else { return nil }
        let first = series(channelIndex: channelIndex, window: SampleWindow(start: 0, count: 1)).xs.first
        let last = series(channelIndex: channelIndex, window: SampleWindow(start: count - 1, count: 1)).xs.first
        guard let first, let last, first <= last else { return nil }
        return first...last
    }

    /// The offsets worth searching for a clip of `videoDuration` seconds — every
    /// alignment that puts some of the RPM trace on the footage — or `nil`
    /// without an RPM channel.
    func audioSyncSearchRange(videoDuration: Double) -> ClosedRange<Double>? {
        guard let index = rpmChannel?.channelIndex, let span = sampleSpan(channelIndex: index) else { return nil }
        return AudioSyncCoordinator.searchRange(videoDuration: videoDuration, sessionSpan: span)
    }

    /// A coordinator matching `source` against the RPM channel, or `nil` without
    /// an RPM channel or an estimator.
    func audioSyncCoordinator(source: AudioPCMSource) -> AudioSyncCoordinator? {
        guard let channel = rpmChannel?.channelName, let estimator else { return nil }
        return AudioSyncCoordinator(source: source, estimator: estimator, rpmChannel: channel)
    }

    private var estimator: (any AudioSyncEstimating)? {
        (dataSource as? AudioSyncEstimatorProviding)?.audioSyncEstimator
    }
}

/// A session's RPM channel name, resolved once per session (issue 9.8). The
/// auto-sync button asks on every render, and resolving walks every channel
/// name for every telemetry role — the session's channels never change, so one
/// walk is enough.
@MainActor
public final class RPMChannelMemo {
    private weak var session: AnalysisSession?
    private var name: String?

    public init() {}

    /// The RPM channel of `analysis`, or `nil` without a session or an RPM
    /// channel — resolved again only when asked about a different session.
    public func channelName(in analysis: AnalysisSession?) -> String? {
        guard let analysis else { return nil }
        if session !== analysis {
            session = analysis
            name = analysis.rpmChannel?.channelName
        }
        return name
    }
}
