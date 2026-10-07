import CoreMedia
import Foundation

/// Everything the compositor needs to draw one export's frames (issue 9.13),
/// carried to it inside the composition instruction: the overlay, the sync
/// that maps each frame to session time, the session's span, and how the
/// footage is turned upright. The output size is the output buffer's.
struct OverlayRenderContext: Sendable {
    /// This export's identity: a compositor re-prepares when it changes.
    let id = UUID()
    let overlay: ExportOverlay
    /// The footage's alignment to the session clock.
    let sync: VideoSyncModel
    /// Where the session has data; outside it, ``outsideSession`` applies.
    let session: SessionTimeSpan
    let outsideSession: OutsideSessionOverlay
    /// The footage time (seconds) of composition time zero — the first
    /// exported frame.
    let sourceStart: Double
    /// The turn that shows the footage upright.
    let rotation: FootageRotation

    init(overlay: ExportOverlay, sync: VideoSyncModel, session: SessionTimeSpan, outsideSession: OutsideSessionOverlay,
         sourceStart: Double, rotation: FootageRotation) {
        self.overlay = overlay
        self.sync = sync
        self.session = session
        self.outsideSession = outsideSession
        self.sourceStart = sourceStart
        self.rotation = rotation
    }

    /// The context that draws `plan`'s frames with `overlay`.
    init(plan: ExportPlan, overlay: ExportOverlay) {
        self.init(overlay: overlay, sync: plan.request.sync, session: plan.request.session,
                  outsideSession: plan.request.settings.outsideSession, sourceStart: plan.sourceRange.start.seconds,
                  rotation: plan.footage.rotation)
    }

    /// The session time of the composition frame at `compositionTime`: its
    /// footage time mapped back through the sync.
    func sessionTime(at compositionTime: CMTime) -> Double {
        sync.cursorTime(forVideoTime: sourceStart + compositionTime.seconds)
    }

    /// The telemetry to draw for session time `t` — sampled forward with
    /// `cursor` inside the session; outside it, a frame without data for the
    /// "no data" overlay, or `nil` to draw no overlay at all.
    func telemetryFrame(at t: Double, cursor: inout SamplingCursor) -> TelemetryFrame? {
        if t >= session.start, t <= session.end { return overlay.telemetry.frame(at: t, cursor: &cursor) }
        switch outsideSession {
        case .hidden: return nil
        case .noData: return TelemetryFrame(time: t, values: [:])
        }
    }
}
