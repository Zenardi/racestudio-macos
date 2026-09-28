import Foundation

/// How the analysis window's bottom scrubber addresses time.
public enum ScrubMode: String, Equatable, Sendable, Codable, CaseIterable {
    /// Absolute session time — one position anywhere in the recording.
    case session
    /// A position *within* a lap, resolved to the equivalent point in every
    /// selected lap.
    case lap

    /// The label shown on the mode control.
    public var title: String {
        switch self {
        case .session: return "Session"
        case .lap: return "Lap"
        }
    }
}

/// The cursor's position in one lap, resolved from a lap-relative offset.
public struct LapScrubTime: Equatable, Sendable {
    /// 1-based lap number, as shown everywhere else in the UI.
    public let lapNumber: Int
    /// Absolute session time (seconds).
    public let time: Double
    /// Seconds into that lap.
    public let offset: Double
    /// `true` when the offset exceeds this lap's duration, so there is no such point
    /// in it and ``time`` has been clamped to the lap's end. Surfaced rather than
    /// hidden: a shorter lap genuinely has nothing to compare at that offset.
    public let isBeyondLap: Bool

    public init(lapNumber: Int, time: Double, offset: Double, isBeyondLap: Bool) {
        self.lapNumber = lapNumber
        self.time = time
        self.offset = offset
        self.isBeyondLap = isBeyondLap
    }
}

/// The state of the analysis window's bottom scrubber (issue 8.3's measures bar).
///
/// The bar used to be a bare slider over absolute session time with a
/// `t = 123.45 s` readout. With two or more laps selected that gave the user
/// nothing: dragging swept the whole recording including unselected laps, the
/// readout was in session seconds rather than "12.3 s into lap 7", the track showed
/// no lap boundaries, and a single absolute cursor said nothing about where in each
/// selected lap it landed — which is the entire reason to select several.
///
/// This adds a second way to address time. **Session** sweeps only the selected laps,
/// joined end to end in time order (the whole recording when none is selected), with
/// lap boundaries marked on the track and a readout that names the lap. **Lap**
/// scrubs an offset *within* a lap and reports the equivalent point in every
/// selected lap, so the channel readouts above are comparing like with like.
///
/// A value type computed from the laps, the selection, and the cursor — so every
/// conversion and every readout is covered by tests rather than decided in a view.
public struct LapScrub: Equatable, Sendable {

    /// Shown when the cursor is not inside any lap (a gap before the first lap
    /// marker, or past the last).
    public static let outsideLapsText = "Outside any lap"

    private let laps: [Lap]
    private let selected: [Int]
    private let reference: Int?
    /// The active mode, already downgraded to ``ScrubMode/session`` when lap mode has
    /// no lap to anchor to.
    public let mode: ScrubMode
    /// The absolute cursor time (seconds).
    public let time: Double

    /// - Parameters:
    ///   - laps: the session's laps.
    ///   - selected: the selected laps' zero-based indices, in selection order.
    ///   - reference: the reference lap's index, or `nil` to anchor on the first
    ///     selected lap.
    ///   - mode: the requested mode; silently falls back to `.session` when lap mode
    ///     is unavailable, so the control is never left inert.
    ///   - time: the absolute cursor time.
    public init(laps: [Lap], selected: [Int], reference: Int?, mode: ScrubMode, time: Double) {
        self.laps = laps
        self.selected = selected
        self.reference = reference
        self.time = time
        let anchor = Self.anchorLap(laps: laps, selected: selected, reference: reference)
        self.mode = (mode == .lap && anchor == nil) ? .session : mode
    }

    /// The lap that lap-mode offsets are measured in: the reference lap when it is
    /// valid, else the first valid selected lap.
    private static func anchorLap(laps: [Lap], selected: [Int], reference: Int?) -> Lap? {
        func lap(_ index: Int) -> Lap? {
            guard let found = laps.first(where: { Int($0.index) == index }), found.hasValidDuration else {
                return nil
            }
            return found
        }
        if let reference, let found = lap(reference) { return found }
        return selected.compactMap(lap).first
    }

    /// The lap lap-mode offsets are measured in, or `nil` when there is none.
    public var anchor: Lap? {
        Self.anchorLap(laps: laps, selected: selected, reference: reference)
    }

    /// Whether lap mode can be offered at all — it needs one valid selected (or
    /// reference) lap to anchor offsets to.
    public var canScrubByLap: Bool { anchor != nil }

    /// The session's scrubbable extent: the first valid lap's start to the last
    /// valid lap's end. `nil` when there are no valid laps or it has no width.
    private var sessionRange: ClosedRange<Double>? {
        let valid = laps.filter(\.hasValidDuration)
        guard let low = valid.map(\.startTimeS).min(),
              let high = valid.map(\.endTimeS).max(),
              low.isFinite, high.isFinite, low < high else { return nil }
        return low...high
    }

    /// The selected valid laps' time windows in time order — what session mode
    /// scrubs when anything is selected. Selection order is irrelevant here.
    private var selectedSegments: [ClosedRange<Double>] {
        let chosen = Set(selected)
        return laps
            .filter { $0.hasValidDuration && chosen.contains(Int($0.index)) && $0.endTimeS > $0.startTimeS }
            .sorted { $0.startTimeS < $1.startTimeS }
            .map { $0.startTimeS...$0.endTimeS }
    }

    /// The stretches of session time the session-mode slider covers, joined end to
    /// end: the selected laps, or — with none selected — the whole session, so the
    /// control is never inert.
    private var segments: [ClosedRange<Double>] {
        let picked = selectedSegments
        if !picked.isEmpty { return picked }
        return sessionRange.map { [$0] } ?? []
    }

    /// The slider length in session mode: the segments' summed widths.
    private var timelineLength: Double {
        segments.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// The slider's value range in the active mode, or `nil` when there is nothing to
    /// scrub (a session with no valid laps).
    ///
    /// In session mode it spans only the selected laps: selecting laps 1 and 3
    /// gives a slider of lap 1 followed directly by lap 3, with the rest of the
    /// recording — lap 2 included — off the track entirely.
    public var range: ClosedRange<Double>? {
        switch mode {
        case .session:
            let length = timelineLength
            return length > 0 ? 0...length : nil
        case .lap:
            guard let anchor else { return nil }
            return 0...anchor.durationS
        }
    }

    /// The slider's value for the current cursor time, in the active mode's terms.
    /// A session-mode cursor outside every segment sits at the nearest segment edge.
    public var value: Double {
        switch mode {
        case .session:
            return timelineValue(at: time)
        case .lap:
            guard let anchor else { return time }
            return time - anchor.startTimeS
        }
    }

    /// The absolute session time a slider value means — the inverse of ``value``, so
    /// switching mode never moves the cursor.
    public func time(for value: Double) -> Double {
        switch mode {
        case .session:
            return sessionTime(atTimelineValue: value)
        case .lap:
            guard let anchor else { return value }
            return anchor.startTimeS + value
        }
    }

    /// Session time → position along the joined segments; a time between or
    /// outside them maps to the nearest segment edge.
    private func timelineValue(at time: Double) -> Double {
        var before = 0.0
        var nearest = (gap: Double.infinity, value: 0.0)
        for segment in segments {
            let width = segment.upperBound - segment.lowerBound
            if segment.contains(time) { return before + time - segment.lowerBound }
            let gapBefore = segment.lowerBound - time, gapAfter = time - segment.upperBound
            if gapBefore > 0, gapBefore < nearest.gap { nearest = (gapBefore, before) }
            if gapAfter > 0, gapAfter < nearest.gap { nearest = (gapAfter, before + width) }
            before += width
        }
        return nearest.value
    }

    /// Position along the joined segments → session time, clamped to their ends.
    /// A join resolves to the earlier segment's end.
    private func sessionTime(atTimelineValue value: Double) -> Double {
        guard let first = segments.first, let last = segments.last else { return value }
        guard value > 0 else { return first.lowerBound }
        var before = 0.0
        for segment in segments {
            let width = segment.upperBound - segment.lowerBound
            if value <= before + width { return segment.lowerBound + (value - before) }
            before += width
        }
        return last.upperBound
    }

    /// The lap the cursor currently sits in, or `nil` when it is between/outside laps.
    public var currentLap: Lap? {
        laps.first { $0.hasValidDuration && time >= $0.startTimeS && time <= $0.endTimeS }
    }

    /// Normalised (`0...1`) positions of the interior lap boundaries along the slider
    /// track — the marks that make the control legible. With laps selected they are
    /// the joins between them. Empty in lap mode, where the whole track *is* one lap.
    public var lapTicks: [Double] {
        guard mode == .session else { return [] }
        let picked = selectedSegments
        if !picked.isEmpty {
            let length = timelineLength
            guard length > 0 else { return [] }
            var before = 0.0
            return picked.dropLast().map { segment in
                before += segment.upperBound - segment.lowerBound
                return before / length
            }
        }
        guard let range = sessionRange else { return [] }
        let span = range.upperBound - range.lowerBound
        return laps.filter(\.hasValidDuration)
            .map(\.startTimeS)
            .filter { $0 > range.lowerBound && $0 < range.upperBound }
            .map { ($0 - range.lowerBound) / span }
    }

    /// The primary readout: which lap the cursor is in, how far into it, and how long
    /// that lap is — "Lap 2 · 15.00 s / 38.00 s".
    public var readout: String {
        // In lap mode the anchor lap is authoritative even if the cursor has been
        // dragged a hair past its end.
        let lap = mode == .lap ? anchor : currentLap
        guard let lap else { return Self.outsideLapsText }
        let offset = time - lap.startTimeS
        return "Lap \(Int(lap.index) + 1) · \(TimecodeFormatter.string(from: offset))"
            + " / \(TimecodeFormatter.string(from: lap.durationS))"
    }

    /// The equivalent cursor position in every selected lap, in selection order.
    /// Empty in session mode, where the cursor is a single absolute instant.
    ///
    /// A lap shorter than the offset is flagged ``LapScrubTime/isBeyondLap`` and
    /// clamped to its end rather than reported as a point it does not contain.
    public var alignedTimes: [LapScrubTime] {
        guard mode == .lap, let anchor else { return [] }
        let offset = time - anchor.startTimeS
        return selected.compactMap { index -> LapScrubTime? in
            guard let lap = laps.first(where: { Int($0.index) == index }), lap.hasValidDuration else {
                return nil
            }
            let beyond = offset > lap.durationS
            let clamped = min(max(offset, 0), lap.durationS)
            return LapScrubTime(lapNumber: Int(lap.index) + 1,
                                time: lap.startTimeS + clamped,
                                offset: offset, isBeyondLap: beyond)
        }
    }

    /// A one-line explanation of what dragging the scrubber does right now.
    public var help: String {
        switch mode {
        case .session where !selectedSegments.isEmpty:
            return "Drag to move the cursor through the selected laps, joined end to end. "
                + "Marks show where each lap begins."
        case .session:
            return "Drag to move the cursor through the whole session. "
                + "Marks show where each lap begins."
        case .lap:
            return "Drag to move the cursor to the same point in every selected lap, "
                + "measured from each lap's start."
        }
    }
}

@MainActor
public extension AnalysisWindowModel {
    /// The bottom scrubber's state in `mode`: what the slider spans, what its value
    /// means, where the lap boundaries fall, and — in lap mode — the equivalent
    /// cursor position in every selected lap.
    ///
    /// Lives here rather than on the model so ``AnalysisWindowModel`` stays inside the
    /// lint's file-length budget, and so the scrubber's whole surface is in one file.
    func scrub(mode: ScrubMode) -> LapScrub {
        LapScrub(laps: session.laps,
                 selected: selection.laps.selected.map(\.index),
                 reference: selection.laps.reference?.index,
                 mode: mode,
                 time: linkedCursor.timePosition)
    }

    /// Bring the shared cursor into the selected laps after the selection changes:
    /// when it sits outside every selected lap, move it to the earliest one's start.
    /// Otherwise the scrubber — which spans only the selected laps — would pin its
    /// thumb to an edge, and the track map would hide its marker, until the user
    /// happened to drag into a lap. A cursor already in a selected lap stays put,
    /// and with nothing selected it is left alone.
    internal func keepCursorInSelectedLaps() {
        let selectedLaps = selection.laps.selected.compactMap { lapByID[$0] }.filter(\.hasValidDuration)
        let time = linkedCursor.timePosition
        guard !selectedLaps.contains(where: { time >= $0.startTimeS && time <= $0.endTimeS }),
              let earliest = selectedLaps.min(by: { $0.startTimeS < $1.startTimeS }) else { return }
        linkedCursor.moveTime(earliest.startTimeS)
    }
}
