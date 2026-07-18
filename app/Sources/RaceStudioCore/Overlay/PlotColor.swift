import Foundation

/// A render-agnostic RGBA color for a plotted trace (issue 4.2).
///
/// Kept independent of SwiftUI so the deterministic overlay palette can be
/// assigned and asserted in the tested core; the thin views map it to a
/// `SwiftUI.Color`.
public struct PlotColor: Hashable, Sendable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    /// The neutral color for a lap that is not currently selected.
    public static let unselected = PlotColor(red: 0.6, green: 0.6, blue: 0.6)

    /// The distinct, ordered overlay palette. Laps are colored by their position
    /// in the selection, wrapping around when there are more laps than colors.
    public static let palette: [PlotColor] = [
        PlotColor(red: 0.20, green: 0.60, blue: 0.98), // blue
        PlotColor(red: 0.96, green: 0.42, blue: 0.22), // orange
        PlotColor(red: 0.26, green: 0.74, blue: 0.44), // green
        PlotColor(red: 0.85, green: 0.30, blue: 0.55), // magenta
        PlotColor(red: 0.60, green: 0.45, blue: 0.90), // purple
        PlotColor(red: 0.90, green: 0.75, blue: 0.20)  // gold
    ]

    /// The colour for an item at `selectionIndex` in the selection: the palette
    /// colour at that position (wrapping past the palette), or ``unselected`` when
    /// the item is not selected (`nil`). The single rule the window's panels use
    /// to colour laps and channels by selection order (issues 4.2 / 8.4).
    public static func selectionColor(at selectionIndex: Int?) -> PlotColor {
        guard let index = selectionIndex else { return .unselected }
        return palette[index % palette.count]
    }
}
