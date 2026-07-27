import Foundation
import Combine

/// The `@MainActor` Core state behind multi-session compare (parity gap 9.1,
/// issue #138): an ordered set of ``AnalysisSession``s overlaid in one analysis
/// window, each colour-keyed, with a cross-session lap selection.
///
/// It builds on the M8 workspace (``AnalysisSession``, the 8.7 distance-aligned
/// ``OverlayLap``) and the 3.1/3.2 distance-domain alignment: overlaid laps are
/// re-based to distance 0 so laps from different sessions share one axis, and
/// cross-session delta-t is computed over that shared grid — no new FFI, since
/// each session's distance-paired samples are already exposed by 8.2/8.7.
///
/// Views bind to it directly: ``overlayTraces()`` (plot / track-map source),
/// ``deltaStrip`` (delta strip), and ``readouts(atDistance:)`` (per-session
/// measures) all recompute from the shared selection and cursor distance.
/// `@MainActor` because it owns main-actor ``AnalysisSession`` pumps and the UI
/// reads it on the main actor; macOS 13 has no `@Observable`, so it is an
/// `ObservableObject`.
@MainActor
public final class MultiSessionModel: ObservableObject {

    /// One added session: its id, the live pump, the colour slot assigned at
    /// insertion (stable for the session's lifetime, so removing another session
    /// never recolours it), and its display label.
    private struct Entry {
        let id: SessionID
        let analysis: AnalysisSession
        let colorSlot: Int
        let label: String
    }

    private var entries: [Entry] = []

    /// The added sessions, in insertion order.
    @Published public private(set) var sessions: [SessionID] = []

    /// The cross-session lap selection, in the order laps were added.
    @Published public private(set) var selectedLaps: [CrossLapID] = []

    /// The reference lap every delta / comparison is measured against. Non-nil
    /// **iff** ``selectedLaps`` is non-empty, and always one of them.
    @Published public private(set) var referenceLap: CrossLapID?

    /// The channel overlaid across every session (issue 9.1). Defaults to the
    /// first channel of the first added session; change it with ``setChannel(_:)``.
    @Published public private(set) var channel: String = ""

    /// The next colour slot / auto-id counter — monotonic, so a removed session's
    /// slot is never reused and colours stay stable across add/remove.
    private var nextSlot = 0

    /// Cached whole-channel distance read per session (issue 8.7 pattern): a lap
    /// toggle / cursor move re-slices rather than re-marshalling across the FFI.
    /// Each entry records which channel it holds, so a channel change is detected
    /// without an explicit invalidation.
    private var distanceCache: [SessionID: (channel: String, samples: [DistanceSample])] = [:]

    public init() {}

    // MARK: - Session management

    /// Add `analysis` under `id` (auto-generated in insertion order when `nil`),
    /// returning the id it was stored under. Re-adding an existing *explicit* id
    /// reloads its pump in place, preserving its stable colour slot and label. The
    /// first added session seeds the default overlay ``channel``.
    @discardableResult
    public func add(_ analysis: AnalysisSession, id explicitID: SessionID? = nil) -> SessionID {
        // Only an explicit id can reload an existing session in place; an
        // auto-generated id is always fresh (below), so it never silently
        // clobbers a session a caller happened to name "session-N" itself.
        if let explicitID {
            if let existing = entries.firstIndex(where: { $0.id == explicitID }) {
                let previous = entries[existing]
                entries[existing] = Entry(id: explicitID, analysis: analysis,
                                          colorSlot: previous.colorSlot, label: previous.label)
                distanceCache[explicitID] = nil
                objectWillChange.send()
                return explicitID
            }
            return append(analysis, id: explicitID)
        }
        // Auto id: advance the counter past any id already in use, so mixing
        // explicit "session-N" ids with auto ids can never collide.
        var id = SessionID("session-\(nextSlot)")
        while entries.contains(where: { $0.id == id }) {
            nextSlot += 1
            id = SessionID("session-\(nextSlot)")
        }
        return append(analysis, id: id)
    }

    /// Append a brand-new session under `id`, assigning the next monotonic colour
    /// slot and seeding the default overlay ``channel`` from the first session.
    private func append(_ analysis: AnalysisSession, id: SessionID) -> SessionID {
        let slot = nextSlot
        nextSlot += 1
        entries.append(Entry(id: id, analysis: analysis, colorSlot: slot,
                             label: Self.label(for: analysis.session, fallback: id)))
        sessions.append(id)
        if channel.isEmpty {
            channel = analysis.session.channels.first?.name ?? ""
        }
        return id
    }

    /// Remove the session `id` and everything keyed to it: its selected laps, its
    /// cached read, and — if it owned the reference — promote the reference onto a
    /// surviving lap. Unknown ids are a no-op, so a removed session leaves the
    /// others' overlays intact.
    public func remove(_ id: SessionID) {
        entries.removeAll { $0.id == id }
        sessions.removeAll { $0 == id }
        selectedLaps.removeAll { $0.session == id }
        distanceCache[id] = nil
        promoteReferenceIfNeeded()
    }

    /// The live pump for `id`, or `nil` when no such session is loaded.
    public func analysis(for id: SessionID) -> AnalysisSession? { entry(id)?.analysis }

    /// The deterministic overlay colour for `id`: its palette colour by insertion
    /// slot (wrapping past the palette), or ``PlotColor/unselected`` for an
    /// unknown session.
    public func color(for id: SessionID) -> PlotColor {
        guard let slot = entry(id)?.colorSlot else { return .unselected }
        return PlotColor.palette[slot % PlotColor.palette.count]
    }

    /// The stable colour slot assigned to `id` at insertion, or `nil` for an
    /// unknown session — the deterministic per-session colour key.
    public func colorKey(for id: SessionID) -> Int? { entry(id)?.colorSlot }

    /// The display label for `id` — the session's own name (metadata), else its
    /// id — for the overlay legend. Falls back to the raw id value for an unknown
    /// session.
    public func sessionLabel(for id: SessionID) -> String { entry(id)?.label ?? id.value }

    // MARK: - Selection

    /// Add `lap` to the selection if absent, remove it if present, then restore
    /// the reference invariant.
    public func toggleLap(_ lap: CrossLapID) {
        if let index = selectedLaps.firstIndex(of: lap) {
            selectedLaps.remove(at: index)
        } else {
            selectedLaps.append(lap)
        }
        promoteReferenceIfNeeded()
    }

    /// Make `lap` the reference, selecting it first if needed.
    public func setReferenceLap(_ lap: CrossLapID) {
        if !selectedLaps.contains(lap) { selectedLaps.append(lap) }
        referenceLap = lap
    }

    /// The first selected lap that is not the reference — the delta strip's
    /// comparison target — or `nil` when only the reference (or nothing) is
    /// selected.
    public var comparisonTarget: CrossLapID? {
        selectedLaps.first { $0 != referenceLap }
    }

    /// Overlay a different `channel` across the sessions (issue 9.1). A no-op when
    /// it is already the overlay channel.
    public func setChannel(_ channel: String) {
        guard channel != self.channel else { return }
        self.channel = channel
    }

    // MARK: - Panels

    /// One distance-aligned, per-session ``SessionOverlayTrace`` for each selected
    /// lap, in selection order, on the current overlay ``channel``. Every lap is
    /// re-based to distance 0, so laps from different sessions overlay on one
    /// shared axis; each trace carries its session's stable colour. A lap carrying
    /// no data for the channel is skipped.
    public func overlayTraces() -> [SessionOverlayTrace] {
        selectedLaps.compactMap { cross in
            guard let overlay = overlayLap(for: cross), let values = overlay.channels[channel] else {
                return nil
            }
            let name = "\(sessionLabel(for: cross.session)) · \(overlay.label)"
            let trace = ChannelTrace(name: name, times: overlay.times,
                                     distances: overlay.distances, values: values)
            return SessionOverlayTrace(session: cross.session, lap: cross.lap,
                                       color: color(for: cross.session), trace: trace)
        }
    }

    /// The cross-session delta-t of `comparison` versus `reference` over the
    /// reference lap's distance grid (issue 9.1): at each distance, the comparison
    /// lap's elapsed time minus the reference lap's, interpolated on the shared
    /// distance axis. Negative means the comparison is ahead. `[]` when either lap
    /// is unavailable. Because both laps are read as distance-aligned
    /// ``OverlayLap``s, the computation is identical whether they share a session
    /// or not — so cross-session delta matches the single-session case.
    public func crossSessionDelta(reference: CrossLapID, comparison: CrossLapID) -> [DeltaSample] {
        guard let ref = overlayLap(for: reference), let cmp = overlayLap(for: comparison) else {
            return []
        }
        return Self.distanceDomainDelta(reference: ref, comparison: cmp)
    }

    /// The delta strip for the current selection: the reference lap versus the
    /// ``comparisonTarget``, or `[]` when there is no pair to compare.
    public var deltaStrip: [DeltaSample] {
        guard let reference = referenceLap, let target = comparisonTarget else { return [] }
        return crossSessionDelta(reference: reference, comparison: target)
    }

    /// Each selected session's value at along-lap `distance` (issue 9.1), in
    /// selection order — the per-session measures at the shared cursor. Each
    /// session resolves independently from its own lap; ``SessionReadout/value``
    /// is `nil` when that lap has no data for the overlay channel.
    public func readouts(atDistance distance: Double) -> [SessionReadout] {
        selectedLaps.map { cross in
            let value = overlayLap(for: cross).flatMap {
                Self.sample(distance, xs: $0.distances, ys: $0.channels[channel] ?? [])
            }
            return SessionReadout(session: cross.session, lap: cross.lap, distance: distance, value: value)
        }
    }

    /// The `[0, lap length]` distance extent of the reference lap — the scrub
    /// range for the shared cursor — or `nil` when there is no reference lap or it
    /// has no distance basis.
    public var distanceBounds: ClosedRange<Double>? {
        guard let reference = referenceLap, let overlay = overlayLap(for: reference),
              let low = overlay.distances.first, let high = overlay.distances.last, low <= high else {
            return nil
        }
        return low...high
    }

    // MARK: - Internals

    private func entry(_ id: SessionID) -> Entry? { entries.first { $0.id == id } }

    /// Keep the reference a currently-selected lap: promote the first selected lap
    /// (or clear to `nil` when the selection is empty).
    private func promoteReferenceIfNeeded() {
        if let reference = referenceLap, selectedLaps.contains(reference) { return }
        referenceLap = selectedLaps.first
    }

    /// The distance-aligned ``OverlayLap`` for one cross-session lap, sliced from
    /// the session's cached whole-channel distance read. `nil` for an unknown
    /// session or lap, or a lap with no samples for the channel.
    private func overlayLap(for cross: CrossLapID) -> OverlayLap? {
        guard let entry = entry(cross.session),
              let lap = entry.analysis.session.laps.first(where: { Int($0.index) == cross.lap.index }) else {
            return nil
        }
        return entry.analysis.overlayLaps(from: distanceSamples(for: entry), channel: channel, laps: [lap]).first
    }

    /// The whole distance-paired ``channel`` read for `entry`, cached so re-slicing
    /// per lap / cursor move does not re-marshal it across the FFI. Re-read when
    /// the cached channel no longer matches the current overlay channel.
    private func distanceSamples(for entry: Entry) -> [DistanceSample] {
        if let cached = distanceCache[entry.id], cached.channel == channel { return cached.samples }
        let samples = entry.analysis.distanceSamples(channelNamed: channel)
        distanceCache[entry.id] = (channel, samples)
        return samples
    }

    /// The session's display label: its own name/driver/vehicle/track (first
    /// non-empty), else the raw id value.
    private static func label(for session: Session, fallback: SessionID) -> String {
        let metadata = session.metadata
        for candidate in [metadata.session, metadata.driver, metadata.vehicle, metadata.track]
        where !candidate.isEmpty {
            return candidate
        }
        return fallback.value
    }

    /// The distance-domain delta-t of `comparison` versus `reference` over the
    /// reference's distance grid: `dt(d) = t_comparison(d) − t_reference(d)`, with
    /// the comparison time interpolated (and clamped past its range) on the shared
    /// distance axis. `[]` when the comparison lap has no samples.
    static func distanceDomainDelta(reference: OverlayLap, comparison: OverlayLap) -> [DeltaSample] {
        guard !comparison.distances.isEmpty else { return [] }
        return zip(reference.distances, reference.times).map { distance, referenceTime in
            let comparisonTime = sample(distance, xs: comparison.distances, ys: comparison.times) ?? referenceTime
            return DeltaSample(distance: distance, dt: comparisonTime - referenceTime)
        }
    }

    /// Linear interpolation of `ys` sampled against non-decreasing `xs` at `x`,
    /// clamped to the endpoints; `nil` when there is nothing to sample. The
    /// interpolated segment always has a positive span, since `x` exceeds the
    /// previous knot at the matched index.
    static func sample(_ x: Double, xs: [Double], ys: [Double]) -> Double? {
        let count = min(xs.count, ys.count)
        guard count > 0 else { return nil }
        if x <= xs[0] { return ys[0] }
        for i in 1..<count where x <= xs[i] {
            let span = xs[i] - xs[i - 1]
            return ys[i - 1] + (ys[i] - ys[i - 1]) * (x - xs[i - 1]) / span
        }
        return ys[count - 1]
    }
}
