import Foundation

/// How the Time/Distance plot arranges N channels into graphs (issue 8.12) — the
/// RaceStudio-3 display modes. The mode → graph mapping is pure Core math; the
/// view binds the chosen mode and stacks the resulting ``PlotGraph``s. Builds on
/// the analysis-window shell (issue 8.3).
public enum PlotArrangementMode: String, CaseIterable, Sendable, Identifiable {
    /// Every channel overlaid in a single graph on one shared Y axis.
    case overlapped
    /// Channels distributed across up to ``PlotArrangement/maxMixedGraphs`` graphs,
    /// several per graph — each graph on its own Y axis.
    case mixed
    /// One channel per graph — every channel on its own Y axis.
    case tiled
    /// Corner-bound families (dampers / wheel speeds / brakes / tyres) auto-grouped
    /// into one graph each; the remaining channels overlaid together in one graph.
    case smart
    /// Like ``smart`` but each remaining (non-family) channel gets its own tiled graph.
    case smartTiled

    public var id: String { rawValue }

    /// The label the mode picker shows.
    public var title: String {
        switch self {
        case .overlapped: return "Overlapped"
        case .mixed: return "Mixed"
        case .tiled: return "Tiled"
        case .smart: return "Smart"
        case .smartTiled: return "Smart Tiled"
        }
    }

    /// An SF Symbol that evokes the arrangement, for a compact segmented control.
    public var systemImageName: String {
        switch self {
        case .overlapped: return "square.stack.3d.up"
        case .mixed: return "rectangle.split.1x2"
        case .tiled: return "rectangle.split.3x1"
        case .smart: return "wand.and.stars"
        case .smartTiled: return "wand.and.rays"
        }
    }
}

/// One graph in a ``PlotArrangement`` — an ordered set of channel names drawn
/// together on a single Y axis (issue 8.12). A graph with a single member is a
/// tile; a graph with several is an overlaid group.
public struct PlotGraph: Equatable, Sendable, Identifiable {
    /// Stable index of the graph within its arrangement, so the view can `ForEach`.
    public let id: Int
    /// The channels this graph draws, in arrangement order.
    public let channelNames: [String]

    public init(id: Int, channelNames: [String]) {
        self.id = id
        self.channelNames = channelNames
    }
}

/// The result of applying a ``PlotArrangementMode`` to a channel list: the ordered
/// graphs to stack, and whether a single shared Y axis spans every channel
/// (issue 8.12).
public struct PlotArrangement: Equatable, Sendable {
    /// The upper bound on graphs the ``PlotArrangementMode/mixed`` mode produces.
    public static let maxMixedGraphs = 6

    /// The mode this arrangement was built for.
    public let mode: PlotArrangementMode
    /// The graphs to draw, top-to-bottom.
    public let graphs: [PlotGraph]

    /// True when one shared Y axis spans every channel — a single overlaid graph;
    /// false when each graph carries its own Y axis (per-graph Y).
    public var sharedY: Bool { graphs.count <= 1 }

    /// The number of graphs the view stacks.
    public var graphCount: Int { graphs.count }

    private init(mode: PlotArrangementMode, groups: [[String]]) {
        self.mode = mode
        self.graphs = groups.enumerated().map { PlotGraph(id: $0.offset, channelNames: $0.element) }
    }

    /// Arranges `channels` (in their session order) into graphs for `mode`. Empty
    /// input yields no graphs in every mode; a single channel is always one graph.
    public static func arrange(mode: PlotArrangementMode, channels: [String]) -> PlotArrangement {
        switch mode {
        case .overlapped:
            return PlotArrangement(mode: mode, groups: channels.isEmpty ? [] : [channels])
        case .tiled:
            return PlotArrangement(mode: mode, groups: channels.map { [$0] })
        case .mixed:
            return PlotArrangement(mode: mode, groups: distribute(channels, into: maxMixedGraphs))
        case .smart:
            let (families, leftovers) = smartGroups(channels)
            let groups = leftovers.isEmpty ? families : families + [leftovers]
            return PlotArrangement(mode: mode, groups: groups)
        case .smartTiled:
            let (families, leftovers) = smartGroups(channels)
            return PlotArrangement(mode: mode, groups: families + leftovers.map { [$0] })
        }
    }

    /// Partitions `names` into at most `maxGraphs` contiguous, order-preserving
    /// groups as evenly as possible; the leading groups absorb the remainder (so 8
    /// into 6 → 2,2,1,1,1,1). Empty input yields no groups.
    static func distribute(_ names: [String], into maxGraphs: Int) -> [[String]] {
        guard !names.isEmpty else { return [] }
        let count = names.count
        let n = min(count, max(maxGraphs, 1))
        var groups: [[String]] = []
        groups.reserveCapacity(n)
        var start = 0
        for index in 0..<n {
            let width = count / n + (index < count % n ? 1 : 0)
            groups.append(Array(names[start..<(start + width)]))
            start += width
        }
        return groups
    }

    /// Splits `names` into corner-bound family groups and the leftover channels that
    /// belong to no family. Families are emitted in ``PlotChannelFamily/allCases``
    /// order, each carrying its members in session order; a family with no member is
    /// omitted. Leftovers keep session order.
    static func smartGroups(_ names: [String]) -> (families: [[String]], leftovers: [String]) {
        var members: [PlotChannelFamily: [String]] = [:]
        var leftovers: [String] = []
        for name in names {
            if let family = PlotChannelFamily.family(of: name) {
                members[family, default: []].append(name)
            } else {
                leftovers.append(name)
            }
        }
        let families = PlotChannelFamily.allCases.compactMap { members[$0] }
        return (families, leftovers)
    }
}

/// A corner-bound channel family smart mode auto-groups (issue 8.12): the
/// four-corner sensors that read together, so an analyst sees all four dampers (or
/// wheel speeds, brakes, tyres) overlaid on one graph. Matched case-insensitively
/// by name fragment — schema-independent, like the Channels Report presets — so a
/// logger that names things differently simply groups nothing rather than failing.
public enum PlotChannelFamily: String, CaseIterable, Sendable, Identifiable {
    case damper
    case wheelSpeed
    case brake
    case tyre

    public var id: String { rawValue }

    /// A human label for the family (unused by the arrangement math itself, but
    /// handy for a future legend / tooltip).
    public var title: String {
        switch self {
        case .damper: return "Dampers"
        case .wheelSpeed: return "Wheel Speeds"
        case .brake: return "Brakes"
        case .tyre: return "Tyres"
        }
    }

    /// The lower-cased name fragments a channel must contain to join this family.
    /// `wheelSpeed` keys on "wheel" (never bare "speed") so GPS Speed is not
    /// mistaken for a wheel-speed sensor.
    public var hints: [String] {
        switch self {
        case .damper: return ["damper", "damp"]
        case .wheelSpeed: return ["wheel"]
        case .brake: return ["brake"]
        case .tyre: return ["tyre", "tire"]
        }
    }

    /// The family `name` belongs to (case-insensitive keyword match), or `nil` when
    /// it is not corner-bound. The first family in ``allCases`` order that matches
    /// wins, so the classification is deterministic.
    public static func family(of name: String) -> PlotChannelFamily? {
        let lowered = name.lowercased()
        return allCases.first { family in family.hints.contains { lowered.contains($0) } }
    }
}

/// The stroke styling knobs for plotted traces (issue 8.12): line width and the
/// optional per-sample dot size. Both are clamped to sane on-screen ranges at
/// construction — a zero, negative, or non-finite input can never reach the
/// renderer — so the view carries no validation of its own.
public struct PlotLineStyle: Equatable, Sendable {
    /// The thinnest drawable line, in points.
    public static let minLineWidth = 0.5
    /// The thickest sensible line, in points.
    public static let maxLineWidth = 8.0
    /// The largest sensible per-sample dot diameter, in points.
    public static let maxDotSize = 20.0

    /// Stroke width in points, clamped to `minLineWidth...maxLineWidth`.
    public let lineWidth: Double
    /// Per-sample dot diameter in points; `0` hides dots. Clamped to `0...maxDotSize`.
    public let dotSize: Double

    /// Creates a line style, clamping both knobs; a non-finite value falls back to
    /// its floor (the min line width, or no dots).
    public init(lineWidth: Double = 1.5, dotSize: Double = 0) {
        self.lineWidth = lineWidth.isFinite
            ? lineWidth.clamped(to: Self.minLineWidth...Self.maxLineWidth)
            : Self.minLineWidth
        self.dotSize = dotSize.isFinite ? dotSize.clamped(to: 0...Self.maxDotSize) : 0
    }

    /// Whether per-sample dots should be drawn.
    public var showsDots: Bool { dotSize > 0 }
}

/// Snaps the visible x-window to whole-lap boundaries (issue 8.12). With snap on,
/// zooming/panning constrains the window so both edges land on lap boundaries — you
/// always frame whole laps. `boundaries` are the lap-edge x-positions on the current
/// x-basis (any order; non-finite entries are ignored). Returns `visible` unchanged
/// when fewer than two finite boundaries survive (nothing to snap to). When both
/// edges collapse onto one boundary, the single adjacent lap is framed instead.
public func snapToLapBoundaries(_ visible: ClosedRange<Double>, boundaries: [Double]) -> ClosedRange<Double> {
    let sorted = boundaries.filter(\.isFinite).sorted()
    guard sorted.count >= 2 else { return visible }

    let lower = nearestBoundary(in: sorted, to: visible.lowerBound)
    let upper = nearestBoundary(in: sorted, to: visible.upperBound)
    if lower < upper { return lower...upper }

    // Collapsed onto a single boundary → frame the whole lap next to it.
    guard let index = sorted.firstIndex(of: lower) else { return sorted[0]...sorted[sorted.count - 1] }
    if index + 1 < sorted.count { return sorted[index]...sorted[index + 1] }
    return sorted[index - 1]...sorted[index]
}

/// The value in the ascending `sorted` nearest to `x` (ties to the lower). `sorted`
/// is non-empty at every call site.
private func nearestBoundary(in sorted: [Double], to x: Double) -> Double {
    guard let index = hitTest(x: x, in: sorted) else { return x }
    return sorted[index]
}

/// The lap-edge positions on the **time** basis for the whole-lap snap (issue
/// 8.12): each valid lap's start time followed by the final lap's end, ascending.
/// Laps with an invalid (zero / negative / non-finite) duration are skipped so a
/// bogus boundary never enters the snap set; an empty or all-invalid list yields no
/// boundaries (snap is then a no-op).
public func lapTimeBoundaries(_ laps: [Lap]) -> [Double] {
    let valid = laps.filter { $0.hasValidDuration && $0.startTimeS.isFinite && $0.endTimeS.isFinite }
    guard let last = valid.last else { return [] }
    return valid.map(\.startTimeS) + [last.endTimeS]
}

/// Per-lap time offsets that align overlaid laps to a common local-time origin
/// (issue 8.12). With local-time on, each lap is shifted so it starts at
/// `reference`, so identical track sections — the same elapsed time into the lap —
/// line up. Returns one offset per input start; a non-finite start yields `0` (no
/// shift) rather than a `NaN` that would corrupt the downstream plot math.
public func localTimeOffsets(lapStartTimes: [Double], reference: Double = 0) -> [Double] {
    lapStartTimes.map { start in start.isFinite ? reference - start : 0 }
}

public extension ChannelTrace {
    /// A copy of this trace with every sample's time shifted by `delta` (its
    /// distance and value untouched) — the per-lap local-time alignment (issue
    /// 8.12). A `delta` of `0` returns an equal trace.
    func timeShifted(by delta: Double) -> ChannelTrace {
        guard delta != 0 else { return self }
        let shifted = samples.map { PlotSample(time: $0.time + delta, distance: $0.distance, value: $0.value) }
        return ChannelTrace(name: name, samples: shifted)
    }
}
