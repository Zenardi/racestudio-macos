import CoreGraphics

/// A one-dimensional affine map between a value ``domain`` and a pixel
/// ``range`` — the geometric heart of every plot axis (issue 4.1).
///
/// ``map(_:)`` and ``invert(_:)`` are exact inverses (`invert(map(v)) == v`
/// within floating-point tolerance) and extrapolate linearly outside their
/// intervals; the `…Clamped` variants pin out-of-range inputs to the edges.
public struct LinearScale: Equatable, Sendable {
    /// The value-space interval, e.g. an RPM span `800...7200`.
    public let domain: ClosedRange<Double>
    /// The pixel-space interval the domain maps onto, e.g. `0...640`.
    public let range: ClosedRange<CGFloat>

    public init(domain: ClosedRange<Double>, range: ClosedRange<CGFloat>) {
        self.domain = domain
        self.range = range
    }

    /// Maps a domain `value` to its pixel position (linear extrapolation
    /// outside the domain; use ``mapClamped(_:)`` to pin at the edges). A
    /// zero-span domain has no gradient, so it maps everything to `range`'s start.
    public func map(_ value: Double) -> CGFloat {
        let domainSpan = domain.upperBound - domain.lowerBound
        guard domainSpan != 0 else { return range.lowerBound }
        let fraction = (value - domain.lowerBound) / domainSpan
        return range.lowerBound + CGFloat(fraction) * (range.upperBound - range.lowerBound)
    }

    /// The inverse of ``map(_:)``: a pixel back to a domain value. A zero-span
    /// range cannot be inverted, so it maps everything to `domain`'s start.
    public func invert(_ pixel: CGFloat) -> Double {
        let rangeSpan = range.upperBound - range.lowerBound
        guard rangeSpan != 0 else { return domain.lowerBound }
        let fraction = Double((pixel - range.lowerBound) / rangeSpan)
        return domain.lowerBound + fraction * (domain.upperBound - domain.lowerBound)
    }

    /// Like ``map(_:)`` but clamps `value` into the domain first, so
    /// out-of-range inputs pin to the range endpoints.
    public func mapClamped(_ value: Double) -> CGFloat {
        map(min(max(value, domain.lowerBound), domain.upperBound))
    }

    /// Like ``invert(_:)`` but clamps `pixel` into the range first, so
    /// out-of-range pixels pin to the domain endpoints.
    public func invertClamped(_ pixel: CGFloat) -> Double {
        invert(min(max(pixel, range.lowerBound), range.upperBound))
    }
}
