import Foundation

/// A pane of the Video + Data panel (issue 9.12) that the operator can hide.
/// The player is always shown.
public enum VideoDataPane: String, CaseIterable, Sendable {
    /// The lap strip plot under the player (speed and RPM over the lap).
    case plot
    /// The track map at the top of the side column.
    case map
    /// The lap list and sector grid under the map.
    case lapList
}

/// A divider of the Video + Data panel (issue 9.12) — what each split fraction
/// measures.
public enum VideoDataDivider: String, CaseIterable, Sendable {
    /// Between the player column and the side column: the side column's share
    /// of the panel's width.
    case side
    /// Between the player and the strip plot: the plot's share of the player
    /// column's height.
    case plot
    /// Between the track map and the lap list: the map's share of the side
    /// column's height.
    case map
}

/// How the Video + Data panel shares its space (issue 9.12): the split
/// fractions of its three dividers and which panes are shown. Saved with the
/// workspace (`.rsproj` v8), so a reopened project lays the panel out as it was
/// left.
///
/// Every fraction stays inside ``fractionLimits`` — no pane can be squeezed to
/// nothing or pushed off the panel — and hiding a pane keeps its split, so
/// showing it again restores it. Pure value type: no SwiftUI.
public struct VideoDataPaneLayout: Equatable, Sendable {

    /// The range every split fraction is held to.
    public static let fractionLimits: ClosedRange<Double> = 0.15...0.85

    /// A new workspace's layout: every pane shown, the player taking two thirds
    /// of the width and most of its column's height.
    public static let `default` = VideoDataPaneLayout()

    private var side = 0.34
    private var plot = 0.3
    private var map = 0.5
    private var hidden: Set<VideoDataPane> = []

    private init() {}

    // MARK: - Fractions

    /// The share of its length `divider` gives the pane it sizes (see
    /// ``VideoDataDivider``).
    public func fraction(_ divider: VideoDataDivider) -> Double {
        switch divider {
        case .side: return side
        case .plot: return plot
        case .map: return map
        }
    }

    /// Move `divider` so its pane takes `value` of its length, held inside
    /// ``fractionLimits``. A non-finite value is no position and is ignored.
    public mutating func setFraction(_ value: Double, for divider: VideoDataDivider) {
        guard value.isFinite else { return }
        let clamped = min(max(value, Self.fractionLimits.lowerBound), Self.fractionLimits.upperBound)
        switch divider {
        case .side: side = clamped
        case .plot: plot = clamped
        case .map: map = clamped
        }
    }

    /// Apply a divider drag: `translation` points (x right, y down) along a
    /// `length`-point split, from the fraction `start` the drag began at — so
    /// every update is measured from the same origin and never drifts. The side
    /// column and the plot grow as their divider moves left or up; the map, which
    /// sits over the lap list, grows as its divider moves down. A split with no
    /// length (not laid out yet) ignores the drag.
    public mutating func drag(_ divider: VideoDataDivider, from start: Double, by translation: Double,
                              across length: Double) {
        guard length.isFinite, length > 0 else { return }
        let share = translation / length
        setFraction(divider == .map ? start + share : start - share, for: divider)
    }

    // MARK: - Visibility

    /// Whether `pane` is shown.
    public func isVisible(_ pane: VideoDataPane) -> Bool {
        !hidden.contains(pane)
    }

    /// Show or hide `pane`, keeping its split.
    public mutating func setVisible(_ visible: Bool, for pane: VideoDataPane) {
        if visible {
            hidden.remove(pane)
        } else {
            hidden.insert(pane)
        }
    }

    /// Show `pane` if hidden, hide it if shown.
    public mutating func toggle(_ pane: VideoDataPane) {
        setVisible(!isVisible(pane), for: pane)
    }

    /// Whether the side column is shown — while the map or the lap list is.
    public var showsSideColumn: Bool {
        isVisible(.map) || isVisible(.lapList)
    }
}

extension VideoDataPaneLayout: Codable {

    private enum CodingKeys: String, CodingKey {
        case side, plot, map, showsPlot, showsMap, showsLapList
    }

    /// Reads each setting on its own — missing or malformed takes its default,
    /// an out-of-range fraction is clamped — so a hand edit costs only what it
    /// broke, never the workspace.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        let fractions: [(CodingKeys, VideoDataDivider)] = [(.side, .side), (.plot, .plot), (.map, .map)]
        for (key, divider) in fractions {
            if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
                setFraction(value, for: divider)
            }
        }
        let panes: [(CodingKeys, VideoDataPane)] = [(.showsPlot, .plot), (.showsMap, .map),
                                                    (.showsLapList, .lapList)]
        for (key, pane) in panes {
            if let visible = try? container.decodeIfPresent(Bool.self, forKey: key) {
                setVisible(visible, for: pane)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(side, forKey: .side)
        try container.encode(plot, forKey: .plot)
        try container.encode(map, forKey: .map)
        try container.encode(isVisible(.plot), forKey: .showsPlot)
        try container.encode(isVisible(.map), forKey: .showsMap)
        try container.encode(isVisible(.lapList), forKey: .showsLapList)
    }
}
