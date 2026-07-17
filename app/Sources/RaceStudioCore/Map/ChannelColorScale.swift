import CoreGraphics
import Foundation

/// Maps a channel value to a color along an evenly-spaced stop palette
/// (issue 4.3) — the racing line's color-by-channel gradient. Reuses the shared
/// ``PlotColor`` from the overlay palette so map and plots color consistently.
///
/// The gradient rises monotonically only between adjacent stops; supply
/// monotonic stops (as the two-stop initializer always does) for a globally
/// monotonic color.
public struct ChannelColorScale: Sendable {
    /// The channel value range: `domain.lowerBound` maps to the first stop,
    /// `domain.upperBound` to the last.
    public let domain: ClosedRange<Double>
    /// The color stops, spaced evenly across the domain (at least one).
    public let stops: [PlotColor]

    /// A two-stop scale from `low` (at the channel min) to `high` (at the max).
    public init(domain: ClosedRange<Double>, low: PlotColor, high: PlotColor) {
        self.domain = domain
        self.stops = [low, high]
    }

    /// A multi-stop scale; `stops` are placed at equal fractions of the domain.
    public init(domain: ClosedRange<Double>, stops: [PlotColor]) {
        self.domain = domain
        self.stops = stops.isEmpty ? [.unselected] : stops
    }

    /// The color for `value`, interpolated across the stops and clamped so
    /// out-of-range values pin to the end stops.
    public func color(for value: Double) -> PlotColor {
        // Both initializers guarantee at least one stop, so stops[0] is safe.
        guard stops.count > 1 else { return stops[0] }
        // A NaN value (a GPS dropout or a 0/0 math channel) has no position on
        // the gradient — pin it to the first stop rather than trapping Int(NaN).
        // (±∞ is fine: the LinearScale clamp maps it to an end stop.)
        guard !value.isNaN else { return stops[0] }
        // Reuse 4.1's LinearScale for the clamped domain→[0,1] map (incl. its
        // zero-span guard) rather than re-deriving the affine fraction here.
        let fraction = Double(LinearScale(domain: domain, range: 0...1).mapClamped(value))
        let position = fraction * Double(stops.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, stops.count - 1)
        return Self.blend(stops[lower], stops[upper], position - Double(lower))
    }

    /// Linear interpolation between two colors, component-wise.
    private static func blend(_ a: PlotColor, _ b: PlotColor, _ t: Double) -> PlotColor {
        PlotColor(red: a.red + (b.red - a.red) * t,
                  green: a.green + (b.green - a.green) * t,
                  blue: a.blue + (b.blue - a.blue) * t,
                  alpha: a.alpha + (b.alpha - a.alpha) * t)
    }
}
