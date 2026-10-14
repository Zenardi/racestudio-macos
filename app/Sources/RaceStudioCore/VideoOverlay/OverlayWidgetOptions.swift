import Foundation

/// How the RPM and speed widgets draw their value (issue 9.15).
public enum OverlayGaugeStyle: String, Codable, CaseIterable, Sendable {
    /// The RPM bar with its shift light; the speed in big digits.
    case classic
    /// A dial with a needle and the value in digits inside it, like a car's
    /// instrument cluster.
    case needle
}

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
    /// A pedal's default full scale: a percentage of travel.
    public static let defaultPedalFullScale = 100.0
    /// The speed dial's default full scale, km/h — room above a fast kart's top speed.
    public static let defaultMaxSpeed = 160.0

    /// The RPM bar's full scales it can draw.
    public static let maxRPMLimits: ClosedRange<Double> = 1_000...30_000
    /// The delta bar's spans it can draw, seconds.
    public static let deltaRangeLimits: ClosedRange<Double> = 0.1...10
    /// The G-ball's outer rings it can draw, g.
    public static let gForceMaxLimits: ClosedRange<Double> = 0.5...5
    /// The pedal full scales it can draw, in the pedal channel's unit.
    public static let pedalFullScaleLimits: ClosedRange<Double> = 0.1...10_000
    /// The speed dial's full scales it can draw, km/h.
    public static let maxSpeedLimits: ClosedRange<Double> = 20...400
    /// How many characters the kart badge's own text keeps (issue 9.23).
    public static let badgeTextLimit = 60
    /// How many code points it keeps, whatever marks are stacked on them.
    public static let badgeTextScalarLimit = 240

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
    /// Pedals: the throttle reading at a full bar, in its channel's unit — `100`
    /// for a percentage, the travel for a throttle logged in mm (issue 9.11).
    public var throttleFullScale: Double
    /// Pedals: the brake reading at a full bar, in its channel's unit — `100`
    /// for a percentage, the pressure at full braking for one logged in bar.
    public var brakeFullScale: Double
    /// RPM and speed: the classic bar and digits, or a needle dial (issue 9.15).
    public var gaugeStyle: OverlayGaugeStyle
    /// Speed dial: the speed at full scale, km/h (shown in the layout's units).
    public var maxSpeed: Double
    /// The kart badge's own text (issue 9.23) — what it says instead of the
    /// kart's, or `nil` for the kart's. Kept to one line of ``badgeTextLimit``
    /// characters, trimmed; blank is `nil`.
    public var badgeText: String?

    public init(maxRPM: Double = OverlayWidgetOptions.defaultMaxRPM,
                shiftLightRPM: Double = OverlayWidgetOptions.defaultShiftLightRPM,
                deltaRange: Double = OverlayWidgetOptions.defaultDeltaRange,
                gForceMax: Double = OverlayWidgetOptions.defaultGForceMax,
                trackMapRotation: Double = 0,
                throttleFullScale: Double = OverlayWidgetOptions.defaultPedalFullScale,
                brakeFullScale: Double = OverlayWidgetOptions.defaultPedalFullScale,
                gaugeStyle: OverlayGaugeStyle = .classic,
                maxSpeed: Double = OverlayWidgetOptions.defaultMaxSpeed,
                badgeText: String? = nil) {
        self.maxRPM = maxRPM
        self.shiftLightRPM = shiftLightRPM
        self.deltaRange = deltaRange
        self.gForceMax = gForceMax
        self.trackMapRotation = trackMapRotation
        self.throttleFullScale = throttleFullScale
        self.brakeFullScale = brakeFullScale
        self.gaugeStyle = gaugeStyle
        self.maxSpeed = maxSpeed
        self.badgeText = badgeText
    }

    /// These options with every value drawable: a non-finite value takes its
    /// default, a finite one is clamped to its limits, the shift light to the
    /// bar's scale, the rotation into one turn, and the badge's text to one
    /// tidy line (``badgeText``).
    public func validated() -> OverlayWidgetOptions {
        let maxRPM = Self.usable(maxRPM, default: Self.defaultMaxRPM, in: Self.maxRPMLimits)
        return OverlayWidgetOptions(
            maxRPM: maxRPM,
            shiftLightRPM: Self.usable(shiftLightRPM, default: Self.defaultShiftLightRPM, in: 0...maxRPM),
            deltaRange: Self.usable(deltaRange, default: Self.defaultDeltaRange, in: Self.deltaRangeLimits),
            gForceMax: Self.usable(gForceMax, default: Self.defaultGForceMax, in: Self.gForceMaxLimits),
            trackMapRotation: Self.oneTurn(trackMapRotation),
            throttleFullScale: Self.usable(throttleFullScale, default: Self.defaultPedalFullScale,
                                           in: Self.pedalFullScaleLimits),
            brakeFullScale: Self.usable(brakeFullScale, default: Self.defaultPedalFullScale,
                                        in: Self.pedalFullScaleLimits),
            gaugeStyle: gaugeStyle,
            maxSpeed: Self.usable(maxSpeed, default: Self.defaultMaxSpeed, in: Self.maxSpeedLimits),
            badgeText: Self.oneLine(badgeText))
    }

    /// `text` as one tidy line: direction overrides dropped, so it can't flip
    /// what follows; line breaks, tabs and other controls turned to spaces;
    /// trimmed; cut to ``badgeTextLimit`` characters and
    /// ``badgeTextScalarLimit`` code points. One with nothing visible — blank,
    /// or only invisible marks — is `nil`.
    private static func oneLine(_ text: String?) -> String? {
        guard let text else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: text.unicodeScalars.filter { !directionControls.contains($0.value) })
        let pieces = String(scalars).split { character in
            character.isNewline || character.unicodeScalars.allSatisfy { $0.properties.generalCategory == .control }
        }
        var kept = String(pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(badgeTextLimit))
        while kept.unicodeScalars.count > badgeTextScalarLimit { kept.removeLast() }
        kept = kept.trimmingCharacters(in: .whitespacesAndNewlines)
        return kept.contains(where: isVisible) ? kept : nil
    }

    /// The direction embedding, override and isolate controls.
    private static let directionControls: Set<UInt32> = [0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                         0x2066, 0x2067, 0x2068, 0x2069]

    /// Whether `character` shows: anything but white space and invisible marks.
    private static func isVisible(_ character: Character) -> Bool {
        character.unicodeScalars.contains { !$0.properties.isWhitespace && !$0.properties.isDefaultIgnorableCodePoint }
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
        case maxRPM, shiftLightRPM, deltaRange, gForceMax, trackMapRotation, throttleFullScale, brakeFullScale
        case gaugeStyle, maxSpeed, badgeText
    }

    /// Each option is read on its own — missing or malformed takes its default —
    /// so options added later, or one a hand edit broke, cost nothing else. A
    /// widget saved before the gauge style existed keeps the classic look.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(maxRPM: container.lenient(Double.self, forKey: .maxRPM) ?? Self.defaultMaxRPM,
                  shiftLightRPM: container.lenient(Double.self, forKey: .shiftLightRPM) ?? Self.defaultShiftLightRPM,
                  deltaRange: container.lenient(Double.self, forKey: .deltaRange) ?? Self.defaultDeltaRange,
                  gForceMax: container.lenient(Double.self, forKey: .gForceMax) ?? Self.defaultGForceMax,
                  trackMapRotation: container.lenient(Double.self, forKey: .trackMapRotation) ?? 0,
                  throttleFullScale: container.lenient(Double.self, forKey: .throttleFullScale)
                    ?? Self.defaultPedalFullScale,
                  brakeFullScale: container.lenient(Double.self, forKey: .brakeFullScale) ?? Self.defaultPedalFullScale,
                  gaugeStyle: container.lenient(OverlayGaugeStyle.self, forKey: .gaugeStyle) ?? .classic,
                  maxSpeed: container.lenient(Double.self, forKey: .maxSpeed) ?? Self.defaultMaxSpeed,
                  badgeText: container.lenient(String.self, forKey: .badgeText))
    }
}
