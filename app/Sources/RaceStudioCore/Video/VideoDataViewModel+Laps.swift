import Foundation

/// Picking and playing laps, the track map's reads, and the HUD renderer of the
/// Video + Data view (issue 9.12).
public extension VideoDataViewModel {

    // MARK: - Laps

    /// Review `lap` — picked in the lap list — and show it on the plot and the
    /// map. Where the footage seeks and the window it plays are the review's
    /// (``VideoReviewModel/seekTarget``, ``VideoReviewModel/videoWindow``). An
    /// unknown lap changes nothing.
    func selectLap(_ lap: LapID) {
        guard review.timeline.lapSpan(lap) != nil else { return }
        review.select(lap: lap)
        setPlotLap(lap)
    }

    /// Review one sector — clicked in the grid — and show its lap.
    func selectSector(_ sector: SectorSpan) {
        review.select(lap: sector.lap, splitID: sector.splitID)
        guard review.selectedLap == sector.lap else { return }
        setPlotLap(sector.lap)
    }

    /// Get ready for *Play lap*: put the whole lap under review — the one picked
    /// (a sector widens to its lap), else the lap at the cursor, else the lap on
    /// the plot. Returns whether the footage holds any of it; the shell then
    /// plays from ``VideoReviewModel/seekTarget``, and the review's window rules
    /// (``VideoReviewModel/loops``) stop or replay it at its end.
    func prepareLapPlayback() -> Bool {
        let cursorLap = displayedTime.flatMap { review.timeline.location(atSessionTime: $0)?.lap }
        guard let lap = review.selectedLap ?? cursorLap ?? plotLap, review.timeline.lapSpan(lap) != nil else {
            return false
        }
        review.select(lap: lap)
        setPlotLap(lap)
        return review.canPlaySelection
    }

    /// The session-time window the strip plot spans — ``plotLap``'s — or `nil`.
    var plotRange: SessionTimeSpan? {
        plotLap.flatMap { review.timeline.lapSpan($0)?.span }
    }

    // MARK: - Track map

    /// The kart's dot on the map at session time `time`.
    func trackMarkers(atTime time: Double) -> [TrackMapMarker] {
        lapMap?.markers(atTime: time) ?? []
    }

    /// The map fix where each sector of the plotted lap after the first begins
    /// — the sector marks, on the review's own split layout.
    var sectorMarks: [Int] {
        guard let map = lapMap, let lap = plotLap, let span = review.timeline.lapSpan(lap) else { return [] }
        return span.sectors.dropFirst().compactMap { map.index(atTime: $0.span.start) }
    }

    /// The session time of map fix `index` — where a click on the map moves the
    /// cursor — or `nil` off the map.
    func sessionTime(atFix index: Int) -> Double? {
        lapMap?.time(atIndex: index)
    }

    // MARK: - The HUD renderer

    /// What this session can feed the overlay, with the garage `kart` and the
    /// session's `metadata`; `nil` before the telemetry is in.
    func overlayContext(kart: Kart?, metadata: SessionMetadata?) -> OverlaySessionContext? {
        guard let telemetry else { return nil }
        return OverlaySessionContext(channelMap: telemetry.channelMap, hasLaps: !review.timeline.isEmpty,
                                     hasSectors: !review.timeline.sectors.isEmpty,
                                     hasTrackPosition: !telemetry.position.isEmpty, kart: kart, metadata: metadata)
    }

    /// The shared renderer drawing `layout` for this session — the same one the
    /// export uses, so the preview is what is exported — writing numbers in
    /// `locale`. `nil` before the telemetry is in.
    func makeRenderer(layout: OverlayLayout, kart: Kart?, metadata: SessionMetadata?,
                      locale: Locale = .current) -> OverlayRenderer? {
        guard let telemetry, let session = overlayContext(kart: kart, metadata: metadata) else { return nil }
        return OverlayRenderer(layout: layout, formatter: OverlayFormatter(locale: locale), session: session,
                               track: OverlayTrackMap(timeline: telemetry, sectors: review.timeline),
                               sectors: review.timeline)
    }
}
