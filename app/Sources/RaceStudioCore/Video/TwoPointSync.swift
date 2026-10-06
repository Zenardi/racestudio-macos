import Foundation

/// One point both clocks agree on (issue 9.7): a session time — a lap start read
/// off the track data — and the video playhead of the frame where the kart
/// actually crosses the line there.
public struct SyncAnchor: Equatable, Sendable {
    /// The instant on the session (logger) clock, in seconds.
    public let sessionTime: Double
    /// The playhead of the matching frame, in seconds of footage.
    public let videoTime: Double

    /// Pairs the session instant `sessionTime` with the frame at `videoTime`.
    public init(sessionTime: Double, videoTime: Double) {
        self.sessionTime = sessionTime
        self.videoTime = videoTime
    }
}

/// Why two anchors could not be turned into a sync (issue 9.7).
public enum TwoPointSyncError: Error, Equatable, Sendable {
    /// The anchors are less than ``TwoPointSync/minimumAnchorSpacing`` apart in
    /// session time — too close to tell a rate from frame-picking error.
    case anchorsTooClose
    /// The rate the anchors imply lies outside ``TwoPointSync/rateBounds`` — no
    /// camera clock drifts that far, so one anchor is on the wrong frame or lap.
    case rateOutOfBounds(Double)
    /// An anchor carries a `NaN` or infinite time.
    case nonFinite
    /// Anchor A or B has not been set yet — raised by the review model before it
    /// can call ``TwoPointSync/solve(anchorA:anchorB:)``.
    case missingAnchor
}

/// Solves the sync **offset** and clock **rate** from two anchors (issue 9.7).
///
/// One offset cannot follow a camera clock that runs 10–100 ppm off the logger's:
/// over a 12-minute stint that is up to a frame or two of drift. Anchoring on two
/// laps far apart pins both unknowns of `videoTime = sessionTime × rate + offset`
/// so that both anchors map exactly, and everything between them is corrected
/// in proportion.
public enum TwoPointSync {

    /// The solved alignment, ready for ``VideoSyncModel/init(videoDuration:offset:rate:)``.
    public struct Solution: Equatable, Sendable {
        /// The playhead session time `0` maps to, in seconds.
        public let offset: Double
        /// Video seconds per session second.
        public let rate: Double
    }

    /// The clock rates accepted as a real camera drift: ±0.5% — fifty times the
    /// worst consumer camera (100 ppm), while still catching an anchor on the
    /// wrong lap.
    public static let rateBounds: ClosedRange<Double> = 0.995...1.005

    /// The least session time between the anchors, in seconds. Closer anchors
    /// let a one-frame picking error swamp the rate.
    public static let minimumAnchorSpacing: Double = 10

    /// The offset and rate that map both anchors exactly. The anchors may be
    /// given in either order.
    public static func solve(anchorA: SyncAnchor, anchorB: SyncAnchor) -> Result<Solution, TwoPointSyncError> {
        let times = [anchorA.sessionTime, anchorA.videoTime, anchorB.sessionTime, anchorB.videoTime]
        guard times.allSatisfy(\.isFinite) else { return .failure(.nonFinite) }

        let sessionSpan = anchorB.sessionTime - anchorA.sessionTime
        guard abs(sessionSpan) >= minimumAnchorSpacing else { return .failure(.anchorsTooClose) }

        let rate = (anchorB.videoTime - anchorA.videoTime) / sessionSpan
        guard rateBounds.contains(rate) else { return .failure(.rateOutOfBounds(rate)) }
        return .success(Solution(offset: anchorA.videoTime - anchorA.sessionTime * rate, rate: rate))
    }
}
