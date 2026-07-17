import SwiftUI
import RaceStudioCore

extension Color {
    /// Bridges a render-agnostic `RaceStudioCore.PlotColor` (issue 4.2) to a
    /// SwiftUI `Color`. The palette itself is defined and tested in the core.
    init(_ plotColor: PlotColor) {
        self.init(.sRGB,
                  red: plotColor.red,
                  green: plotColor.green,
                  blue: plotColor.blue,
                  opacity: plotColor.alpha)
    }
}
