import Foundation

/// A widget's kind-specific settings (issue 9.10). Each applies to the kinds
/// that draw it and is ignored by the rest, so one value type serves every
/// widget and persists the same way.
public struct OverlayWidgetOptions: Equatable, Hashable, Sendable {

    /// The RPM bar's default full scale — a 2-stroke kart's range.
    public static let defaultMaxRPM = 16_000.0
    /// The default shift-light threshold.
    public static let defaultShiftLightRPM = 14_000.0
    /// The delta bar's default span, ± seconds.
    public static let defaultDeltaRange = 1.0
    /// The G-ball's default outer ring, in g.
    public static let defaultGForceMax = 2.0

    /// The RPM bar's full scales it can draw.
    public static let maxRPMLimits: ClosedRange<Double> = 1_000...30_000
    /// The delta bar's spans it can draw, seconds.
    public static let deltaRangeLimits: ClosedRange<Double> = 0.1...10
    /// The G-ball's outer rings it can draw, g.
    public static let gForceMaxLimits: ClosedRange<Double> = 0.5...5

    /// RPM bar: the rpm at the full bar.
    public var maxRPM: Double
    /// RPM bar: the shift light comes on at or above this rpm.
    public var shiftLightRPM: Double
    /// Delta bar: the ± seconds a full half-bar stands for.
    public var deltaRange: Double
    /// G-ball: the g at the outer ring.
    public var gForceMax: Double
    /// Track map: degrees clockwise from north-up, `0..<360`.
    public var trackMapRotation: Double

    public init(maxRPM: Double = OverlayWidgetOptions.defaultMaxRPM,
                shiftLightRPM: Double = OverlayWidgetOptions.defaultShiftLightRPM,
                deltaRange: Double = OverlayWidgetOptions.defaultDeltaRange,
                gForceMax: Double = OverlayWidgetOptions.defaultGForceMax,
                trackMapRotation: Double = 0) {
        self.maxRPM = maxRPM
        self.shiftLightRPM = shiftLightRPM
        self.deltaRange = deltaRange
        self.gForceMax = gForceMax
        self.trackMapRotation = trackMapRotation
    }

    /// These options with every value drawable: a non-finite value takes its
    /// default, a finite one is clamped to its limits, the shift light to the
    /// bar's scale, and the rotation into one turn.
    public func validated() -> OverlayWidgetOptions {
        let maxRPM = Self.usable(maxRPM, default: Self.defaultMaxRPM, in: Self.maxRPMLimits)
        return OverlayWidgetOptions(
            maxRPM: maxRPM,
            shiftLightRPM: Self.usable(shiftLightRPM, default: Self.defaultShiftLightRPM, in: 0...maxRPM),
            deltaRange: Self.usable(deltaRange, default: Self.defaultDeltaRange, in: Self.deltaRangeLimits),
            gForceMax: Self.usable(gForceMax, default: Self.defaultGForceMax, in: Self.gForceMaxLimits),
            trackMapRotation: Self.oneTurn(trackMapRotation))
    }

    /// `degrees` as an angle in `0..<360`; a non-finite one is `0`. A hair below
    /// zero can round up to a full `360`, which is the same angle as `0`.
    private static func oneTurn(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        let remainder = degrees.truncatingRemainder(dividingBy: 360)
        let positive = remainder < 0 ? remainder + 360 : remainder
        return positive < 360 ? positive : 0
    }

    /// `value` clamped to `limits`, or `fallback` (clamped too) when not finite.
    private static func usable(_ value: Double, default fallback: Double, in limits: ClosedRange<Double>) -> Double {
        min(max(value.isFinite ? value : fallback, limits.lowerBound), limits.upperBound)
    }
}

extension OverlayWidgetOptions: Codable {

    private enum CodingKeys: String, CodingKey {
        case maxRPM, shiftLightRPM, deltaRange, gForceMax, trackMapRotation
    }

    /// Each option is read on its own — missing or malformed takes its default —
    /// so options added later, or one a hand edit broke, cost nothing else.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxRPM: container.lenient(Double.self, forKey: .maxRPM) ?? Self.defaultMaxRPM,
                  shiftLightRPM: container.lenient(Double.self, forKey: .shiftLightRPM) ?? Self.defaultShiftLightRPM,
                  deltaRange: container.lenient(Double.self, forKey: .deltaRange) ?? Self.defaultDeltaRange,
                  gForceMax: container.lenient(Double.self, forKey: .gForceMax) ?? Self.defaultGForceMax,
                  trackMapRotation: container.lenient(Double.self, forKey: .trackMapRotation) ?? 0)
    }
}
