import Foundation

/// The visible x-window of a plot and the pure zoom/pan math over it
/// (issue 4.1). Immutable: every gesture returns a new viewport. All accessors
/// are robust to non-finite gesture inputs — a `NaN`/`±∞` factor, anchor, or pan
/// delta returns the viewport unchanged rather than trapping `ClosedRange`.
public struct PlotViewport: Equatable, Sendable {
    /// Fraction of the bounds span used as the default zoom-in floor.
    private static let defaultMinSpanFraction = 1e-6

    /// The full data extent — the clamp target for pan and zoom-out.
    public let bounds: ClosedRange<Double>
    /// The currently visible sub-window of ``bounds``.
    public let visible: ClosedRange<Double>
    /// The smallest span the window may zoom in to (never collapses below it).
    /// Clamped to `0...boundsSpan` at construction so it can never exceed the
    /// extent it must fit inside.
    public let minSpan: Double

    /// Creates a viewport. `visible` defaults to the full `bounds`; `minSpan`
    /// defaults to a millionth of the bounds span and is clamped to
    /// `0...boundsSpan` so the zoom-in floor is always achievable.
    public init(bounds: ClosedRange<Double>, visible: ClosedRange<Double>? = nil, minSpan: Double? = nil) {
        self.bounds = bounds
        self.visible = visible ?? bounds
        let boundsSpan = bounds.upperBound - bounds.lowerBound
        let requested = minSpan ?? boundsSpan * Self.defaultMinSpanFraction
        self.minSpan = requested.isFinite ? requested.clamped(to: 0...max(boundsSpan, 0)) : 0
    }

    /// The width of the visible window in domain units.
    public var span: Double { visible.upperBound - visible.lowerBound }

    /// The domain value at fractional position `f` (0 = leading edge, 1 =
    /// trailing edge) of the visible window.
    public func value(atFraction f: Double) -> Double {
        visible.lowerBound + f * span
    }

    /// Zooms by `factor` (`< 1` in, `> 1` out) keeping the value under the
    /// `anchor` fraction fixed; the new span is clamped to
    /// `minSpan...boundsSpan` so it never inverts or collapses, and the window
    /// is clamped back inside ``bounds``. A non-finite `factor`/`anchor` (or a
    /// non-finite result) leaves the viewport unchanged.
    public func zoom(factor: Double, anchor: Double) -> PlotViewport {
        guard factor.isFinite, anchor.isFinite else { return self }
        let clampedAnchor = anchor.clamped(to: 0...1)
        let focus = value(atFraction: clampedAnchor)
        let maxSpan = bounds.upperBound - bounds.lowerBound
        let newSpan = (span * factor).clamped(to: minSpan...max(maxSpan, minSpan))

        var lower = focus - clampedAnchor * newSpan
        var upper = lower + newSpan
        if lower < bounds.lowerBound {
            lower = bounds.lowerBound
            upper = lower + newSpan
        }
        if upper > bounds.upperBound {
            upper = bounds.upperBound
            lower = upper - newSpan
        }
        guard lower.isFinite, upper.isFinite, lower <= upper else { return self }
        return PlotViewport(bounds: bounds, visible: lower...upper, minSpan: minSpan)
    }

    /// Shifts the visible window by `delta` domain units without resizing it,
    /// clamped so it stays inside ``bounds``. A non-finite `delta` (or result)
    /// leaves the viewport unchanged.
    public func pan(by delta: Double) -> PlotViewport {
        guard delta.isFinite else { return self }
        let width = span
        let maxLower = max(bounds.upperBound - width, bounds.lowerBound)
        let lower = (visible.lowerBound + delta).clamped(to: bounds.lowerBound...maxLower)
        let upper = lower + width
        guard lower.isFinite, upper.isFinite, lower <= upper else { return self }
        return PlotViewport(bounds: bounds, visible: lower...upper, minSpan: minSpan)
    }

    /// Returns the viewport zoomed all the way out to the full ``bounds``.
    public func reset() -> PlotViewport {
        PlotViewport(bounds: bounds, visible: bounds, minSpan: minSpan)
    }
}
