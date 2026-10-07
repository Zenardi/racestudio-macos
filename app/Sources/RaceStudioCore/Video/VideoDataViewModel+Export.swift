import Foundation

/// What the Video + Data view hands *Export Video with Overlay* (issue 9.14):
/// the export sheet's input, and the overlay the export burns in — drawn by
/// the HUD's own renderer, so what was previewed is what is exported.
public extension VideoDataViewModel {

    /// The export sheet's input: `footage` (probed from `source`) with the
    /// review's sync, sync status, laps and section under review, and the
    /// session's span from its telemetry — or `nil` before the telemetry is in.
    ///
    /// - Parameters:
    ///   - session: the decoded session — its laps, for the best lap and the
    ///     lap times, and its track and date, for the file name.
    ///   - selectedLaps: the laps selected in the window.
    ///   - hasWorkspaceOverlay: whether the workspace has an overlay of its own.
    func exportSheetInput(source: URL, footage: FootageInfo, session: Session, selectedLaps: [LapID],
                          hasWorkspaceOverlay: Bool) -> ExportSheetInput? {
        guard let span = telemetry?.timeRange else { return nil }
        return ExportSheetInput(source: source, footage: footage, sync: review.sync, status: review.status,
                                timeline: review.timeline, laps: session.laps,
                                session: SessionTimeSpan(start: span.lowerBound, end: span.upperBound),
                                selection: review.selectedSpan, selectedLaps: selectedLaps,
                                metadata: session.metadata, hasWorkspaceOverlay: hasWorkspaceOverlay)
    }

    /// The overlay an export of `layout` burns in: the shared renderer drawing
    /// it — shown, even if the HUD is off — over this session's telemetry.
    ///
    /// The telemetry on show is reused when it samples every channel the
    /// layout names and was cut by the current laps and sectors; otherwise the
    /// export loads its own from `analysis`, leaving the HUD's untouched.
    ///
    /// - Returns: the overlay, or `nil` when there is no telemetry to draw
    ///   from (none loaded yet, or a load needed without an `analysis`).
    /// - Throws: `CancellationError` when the calling task is cancelled
    ///   mid-load.
    func exportOverlay(layout: OverlayLayout, kart: Kart?, metadata: SessionMetadata?, analysis: AnalysisSession?,
                       locale: Locale = .current) async throws -> ExportOverlay? {
        var shown = layout
        shown.isEnabled = true
        let channels = shown.sessionChannelNames
        let timeline: TelemetryTimeline
        if let current = telemetry(sampling: channels) {
            timeline = current
        } else if let analysis {
            timeline = try await TelemetryTimeline.load(from: analysis, timeline: review.timeline, channels: channels)
        } else {
            return nil
        }
        return ExportOverlay(drawer: makeRenderer(layout: shown, kart: kart, metadata: metadata, locale: locale,
                                                  telemetry: timeline),
                             telemetry: timeline)
    }
}
