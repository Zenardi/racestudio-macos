import Foundation

/// One sub-panel the RS3 Suspension Analysis layout composes (issue 8.17).
public enum SuspensionPanelKind: String, CaseIterable, Sendable, Identifiable {
    /// The shock channels' Time/Distance trace.
    case timeDistance
    /// The shock-travel distribution histogram.
    case histogram
    /// The damper-frequency FFT spectrum (issue 8.16).
    case spectrum
    /// The suspension settings readout drawn from the log sheet (issue 8.17).
    case settings

    public var id: String { rawValue }

    /// The sub-panel's section header.
    public var title: String {
        switch self {
        case .timeDistance: return "Time / Distance"
        case .histogram: return "Histogram"
        case .spectrum: return "FFT"
        case .settings: return "Settings"
        }
    }
}

/// The ordered set of sub-panels the RS3 Suspension Analysis layout stacks into a
/// single view (issue 8.17): shock time/distance + travel histogram + damper FFT +
/// settings. A pure value type so the composition — which panels, in what order —
/// is unit-tested independently of the SwiftUI view that renders it.
public struct SuspensionComposition: Equatable, Sendable {
    /// The composed panels, in top-to-bottom render order.
    public let panels: [SuspensionPanelKind]

    public init(panels: [SuspensionPanelKind]) {
        self.panels = panels
    }

    /// The standard RS3 arrangement: time/distance, then histogram, then FFT, then
    /// the settings readout.
    public static let standard = SuspensionComposition(
        panels: [.timeDistance, .histogram, .spectrum, .settings])

    /// Whether `kind` is part of this composition.
    public func contains(_ kind: SuspensionPanelKind) -> Bool {
        panels.contains(kind)
    }
}
