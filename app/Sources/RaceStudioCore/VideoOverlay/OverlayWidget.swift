import Foundation

/// The channel a ``OverlayWidgetKind/channelValue(_:)`` readout shows (issue
/// 9.10): one of the overlay's resolved roles, or any session channel by name.
public enum OverlayChannelSource: Equatable, Hashable, Sendable {
    /// The channel bound to this role (``TelemetryChannelMap``).
    case role(TelemetryRole)
    /// The session channel with this name.
    case channel(String)
}

/// What a widget draws (issue 9.10).
public enum OverlayWidgetKind: Equatable, Hashable, Sendable {
    /// Big speed digits with the unit.
    case speed
    /// The RPM bar with its shift light.
    case rpm
    case gear
    /// The running lap time.
    case lapTimer
    /// Lap number · last lap · best lap.
    case lapInfo
    /// The delta bar against the reference lap.
    case delta
    /// The G-ball with its trail.
    case gForce
    /// The mini track map with the kart's position.
    case trackMap
    /// Throttle and brake.
    case pedals
    /// Water and exhaust temperature.
    case temperature
    /// The current lap's sector times.
    case sectorTimes
    /// One channel's value.
    case channelValue(OverlayChannelSource)
    /// The kart from the garage: "F4 · Thunder · RBC Honda · 18 HP".
    case kartBadge
    /// Venue, date and session name.
    case sessionInfo

    /// The kind's stable key: the `type` it persists under, and the id a new
    /// widget of this kind takes.
    public var key: String {
        switch self {
        case .speed: return "speed"
        case .rpm: return "rpm"
        case .gear: return "gear"
        case .lapTimer: return "lapTimer"
        case .lapInfo: return "lapInfo"
        case .delta: return "delta"
        case .gForce: return "gForce"
        case .trackMap: return "trackMap"
        case .pedals: return "pedals"
        case .temperature: return "temperature"
        case .sectorTimes: return "sectorTimes"
        case .channelValue: return "channelValue"
        case .kartBadge: return "kartBadge"
        case .sessionInfo: return "sessionInfo"
        }
    }

    /// The kinds without a parameter, by key — what a persisted `type` reads back as.
    private static let plainKinds: [String: OverlayWidgetKind] = Dictionary(
        uniqueKeysWithValues: [OverlayWidgetKind.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce,
                               .trackMap, .pedals, .temperature, .sectorTimes, .kartBadge, .sessionInfo]
            .map { ($0.key, $0) })
}

extension OverlayWidgetKind: Codable {

    private enum CodingKeys: String, CodingKey {
        case type, role, channel
    }

    /// Reads `{"type": "speed"}`, or `{"type": "channelValue", "role": "rpm"}` /
    /// `{"type": "channelValue", "channel": "Oil Temp"}`. Throws for a kind this
    /// build doesn't know, which the layout then skips.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        if let plain = Self.plainKinds[type] {
            self = plain
        } else if type == "channelValue", let role = try container.decodeIfPresent(TelemetryRole.self, forKey: .role) {
            self = .channelValue(.role(role))
        } else if type == "channelValue", let name = try container.decodeIfPresent(String.self, forKey: .channel) {
            self = .channelValue(.channel(name))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container,
                                                   debugDescription: "unknown overlay widget kind \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .type)
        switch self {
        case .channelValue(.role(let role)): try container.encode(role, forKey: .role)
        case .channelValue(.channel(let name)): try container.encode(name, forKey: .channel)
        default: break
        }
    }
}

/// How large a widget's text is drawn within its rect (issue 9.10).
public enum OverlaySizeClass: String, Codable, CaseIterable, Sendable {
    case small
    case medium
    case large

    /// The text size relative to ``medium``.
    public var textScale: Double {
        switch self {
        case .small: return 0.8
        case .medium: return 1
        case .large: return 1.25
        }
    }
}

/// One element of a video overlay (issue 9.10): what it draws, where, and how.
///
/// The ``frame`` is a ``NormalizedRect`` in the 16:9 reference frame; the
/// ``anchor`` says which edge it keeps its margin to in other aspects, and ``z``
/// orders the draw (higher on top). An ``OverlayLayout`` keeps every widget
/// valid (``OverlayLayout/validated()``).
public struct OverlayWidget: Equatable, Hashable, Identifiable, Sendable {

    /// Unique within its layout.
    public var id: String
    public var kind: OverlayWidgetKind
    /// Where it sits in the 16:9 reference frame.
    public var frame: NormalizedRect
    /// The corner or edge it keeps its margin to in other aspects.
    public var anchor: OverlayAnchor
    /// Draw order: higher draws on top; ties draw in layout order.
    public var z: Int
    /// The whole widget's opacity, `0…1`.
    public var opacity: Double
    public var plate: OverlayPlateStyle
    public var sizeClass: OverlaySizeClass
    /// This widget's units, or `nil` to follow the layout's.
    public var units: UnitSystem?
    /// Whether it is drawn — a widget toggled off keeps its place.
    public var isVisible: Bool
    /// Kind-specific settings (shift light, delta range, …).
    public var options: OverlayWidgetOptions

    /// - Parameter id: the widget's id; `nil` takes the kind's ``OverlayWidgetKind/key``.
    public init(id: String? = nil, kind: OverlayWidgetKind, frame: NormalizedRect, anchor: OverlayAnchor = .topLeading,
                z: Int = 0, opacity: Double = 1, plate: OverlayPlateStyle = .translucent,
                sizeClass: OverlaySizeClass = .medium, units: UnitSystem? = nil, isVisible: Bool = true,
                options: OverlayWidgetOptions = OverlayWidgetOptions()) {
        self.id = id ?? kind.key
        self.kind = kind
        self.frame = frame
        self.anchor = anchor
        self.z = z
        self.opacity = opacity
        self.plate = plate
        self.sizeClass = sizeClass
        self.units = units
        self.isVisible = isVisible
        self.options = options
    }
}

extension OverlayWidget: Codable {

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, anchor, z, opacity, plate, sizeClass, units, isVisible, options
    }

    /// Only the kind and the rect are required; anything else missing or
    /// malformed takes its default (a missing id, the kind's key), so a setting a
    /// hand edit broke costs that setting, not the widget.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The required fields first: a widget that can't be read is skipped (and
        // counted) as one entry, before any of its settings are counted.
        let kind = try container.decode(OverlayWidgetKind.self, forKey: .kind)
        let frame = try container.decode(NormalizedRect.self, forKey: .frame)
        self.init(id: container.lenient(String.self, forKey: .id),
                  kind: kind,
                  frame: frame,
                  anchor: container.lenient(OverlayAnchor.self, forKey: .anchor) ?? .topLeading,
                  z: container.lenient(Int.self, forKey: .z) ?? 0,
                  opacity: container.lenient(Double.self, forKey: .opacity) ?? 1,
                  plate: container.lenient(OverlayPlateStyle.self, forKey: .plate) ?? .translucent,
                  sizeClass: container.lenient(OverlaySizeClass.self, forKey: .sizeClass) ?? .medium,
                  units: container.lenient(UnitSystem.self, forKey: .units),
                  isVisible: container.lenient(Bool.self, forKey: .isVisible) ?? true,
                  options: container.lenient(OverlayWidgetOptions.self, forKey: .options) ?? OverlayWidgetOptions())
    }
}

extension KeyedDecodingContainer {
    /// The value at `key`, or `nil` when it is missing or malformed — for
    /// settings whose loss should cost only themselves. A value that is there but
    /// unreadable is reported to the decode's ``SkippedElementCounter``, if any.
    func lenient<Value: Decodable>(_ type: Value.Type, forKey key: Key) -> Value? {
        do {
            return try decodeIfPresent(type, forKey: key)
        } catch {
            SkippedElementCounter.record(in: try? superDecoder(forKey: key))
            return nil
        }
    }
}

/// An array read element by element, skipping any element that fails to decode
/// — so one widget or preset this build can't read never loses its neighbours.
/// The skips are reported to a ``SkippedElementCounter`` when the decoder
/// carries one, so a caller can tell a complete read from a lossy one.
struct LossyList<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        var skipped = 0
        while !container.isAtEnd {
            if let element = try? container.decode(Element.self) {
                elements.append(element)
            } else {
                // A failed decode leaves the cursor in place; step over the element.
                _ = try container.decode(Skipped.self)
                skipped += 1
            }
        }
        self.elements = elements
        if skipped > 0 { SkippedElementCounter.record(skipped, in: decoder) }
    }

    /// Consumes any one element.
    private struct Skipped: Decodable {
        init(from decoder: Decoder) throws {}
    }
}

/// Counts what one decode could not read — elements a ``LossyList`` skipped,
/// settings that fell back to their default — at any depth, when placed in the
/// decoder's `userInfo` under ``key``; so a caller can tell a complete read
/// from a lossy one before it writes the value back.
final class SkippedElementCounter {
    /// Where a decoder carries the counter.
    static let key = CodingUserInfoKey(rawValue: "com.racestudio.skippedElements")

    /// How many entries could not be read so far.
    private(set) var total = 0

    /// Count `entries` unread on the counter `decoder` carries, if any.
    static func record(_ entries: Int = 1, in decoder: Decoder?) {
        guard let key, let counter = decoder?.userInfo[key] as? SkippedElementCounter else { return }
        counter.total += entries
    }
}
