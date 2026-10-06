import Foundation

/// A video overlay (issue 9.10): a named layout of telemetry widgets drawn over
/// the footage — the one value that drives both the live HUD in the Video + Data
/// view and the burned-in MP4 export, so what is previewed is what is exported.
///
/// Widgets are placed in the 16:9 reference frame; ``resolved(for:)`` re-places
/// them for any output aspect. ``availability(for:)`` says which widgets the
/// session can feed. The layout persists with the project (`.rsproj` v7) and in
/// the user preset library (``OverlayPresetStore``); whatever is read is
/// ``validated()``, and what is written is validated first, so a stored layout
/// is always one the renderer can draw.
///
/// Pure value type: no AppKit, SwiftUI or AVFoundation.
public struct OverlayLayout: Equatable, Sendable {

    /// The layout format this build reads and writes.
    public static let currentSchema = 1
    /// The title-safe margin every widget stays inside, as a fraction of each
    /// axis — 3%, in every output aspect.
    public static let safeMargin = 0.03
    /// The smallest a widget may be on either axis, as a fraction of the frame.
    public static let minimumWidgetSize = 0.03

    /// The layout format: always ``currentSchema``. Whatever format a layout is
    /// read from, it is read into — and written as — this build's, so a layout
    /// re-saved here never claims a newer format whose rules it did not follow.
    public var schema: Int { Self.currentSchema }
    /// The name shown in the preset menu.
    public var name: String
    /// The widgets, in layout order (the draw order among equal ``OverlayWidget/z``).
    public var widgets: [OverlayWidget]
    /// The units every widget shows unless it sets its own.
    public var units: UnitSystem
    public var theme: OverlayTheme
    /// Whether the overlay is shown — *Show HUD*. Off hides it, layout kept.
    public var isEnabled: Bool

    public init(name: String, widgets: [OverlayWidget] = [], units: UnitSystem = .metric,
                theme: OverlayTheme = .raceStudio, isEnabled: Bool = true) {
        self.name = name
        self.widgets = widgets
        self.units = units
        self.theme = theme
        self.isEnabled = isEnabled
    }

    /// The units `widget` shows: its own, else the layout's.
    public func units(for widget: OverlayWidget) -> UnitSystem {
        widget.units ?? units
    }

    // MARK: - Drawing

    /// What the renderer draws for an output of `aspect`, back to front: every
    /// visible widget of the ``validated()`` layout, ordered by ``OverlayWidget/z``
    /// (ties in layout order), each in its rect re-placed for that aspect
    /// (``NormalizedRect/resolved(in:anchor:safeMargin:)``). Empty while the
    /// overlay is off. Widgets the session cannot feed are left in; the renderer
    /// draws ``drawable(for:session:)``, which skips them. Each call validates
    /// the layout, so resolve once per layout and output size, not per frame.
    public func resolved(for aspect: OverlayAspect) -> [ResolvedOverlayWidget] {
        guard isEnabled else { return [] }
        return validated().widgets.enumerated()
            .filter { $0.element.isVisible }
            .sorted { ($0.element.z, $0.offset) < ($1.element.z, $1.offset) }
            .map { ResolvedOverlayWidget(widget: $0.element,
                                         frame: $0.element.frame.resolved(in: aspect, anchor: $0.element.anchor)) }
    }

    // MARK: - Validation

    /// This layout made drawable, whatever it held:
    ///
    /// - a widget whose rect has a NaN or infinity is dropped (it has no place);
    /// - every rect is sized to at least ``minimumWidgetSize`` and moved inside
    ///   the ``safeMargin`` safe area;
    /// - opacity is clamped to `0…1` (NaN reads as opaque) and the options are
    ///   ``OverlayWidgetOptions/validated()``;
    /// - a blank id takes the kind's key, and a repeated id is renamed
    ///   (`speed` → `speed-2`) — never an id another widget already holds — so
    ///   no widget the operator placed is lost.
    ///
    /// A valid layout comes back unchanged, so validating twice is validating once.
    public func validated() -> OverlayLayout {
        let safeArea = NormalizedRect.safeArea(margin: Self.safeMargin)
        var copy = self
        copy.widgets = Self.uniquingIDs(widgets.filter(\.frame.isFinite).map { widget in
            var valid = widget
            valid.frame = widget.frame.clamped(to: safeArea, minimumSize: Self.minimumWidgetSize)
            valid.opacity = widget.opacity.isNaN ? 1 : min(max(widget.opacity, 0), 1)
            valid.options = widget.options.validated()
            return valid
        })
        return copy
    }

    /// `widgets` with every id unique: the first holder of an id keeps it, and a
    /// later one takes the first free `id-2`, `id-3`, … that no widget asked for.
    private static func uniquingIDs(_ widgets: [OverlayWidget]) -> [OverlayWidget] {
        let wanted = widgets.map { widget in
            widget.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? widget.kind.key : widget.id
        }
        var reserved = Set(wanted)
        var taken = Set<String>()
        return zip(widgets, wanted).map { widget, id in
            var unique = widget
            unique.id = id
            if !taken.insert(id).inserted {
                var suffix = 2
                while reserved.contains("\(id)-\(suffix)") { suffix += 1 }
                unique.id = "\(id)-\(suffix)"
                reserved.insert(unique.id)
                taken.insert(unique.id)
            }
            return unique
        }
    }
}

/// One widget placed for an output (issue 9.10): the widget, and its rect in
/// that output's normalized frame.
public struct ResolvedOverlayWidget: Equatable, Sendable {
    public let widget: OverlayWidget
    /// Where to draw it, in the output's frame (origin top-left).
    public let frame: NormalizedRect

    public init(widget: OverlayWidget, frame: NormalizedRect) {
        self.widget = widget
        self.frame = frame
    }

    public var id: OverlayWidget.ID { widget.id }
}

extension OverlayLayout: Codable {

    private enum CodingKeys: String, CodingKey {
        case schema, name, widgets, units, theme, isEnabled
    }

    /// Reads leniently, then validates: a widget this build can't read is
    /// skipped, a missing or malformed setting takes its default, and whatever
    /// geometry a hand edit left is made drawable (``validated()``). There is one
    /// format so far, so the stored `schema` needs no migration.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = OverlayLayout(
            name: container.lenient(String.self, forKey: .name) ?? "",
            widgets: container.lenient(LossyList<OverlayWidget>.self, forKey: .widgets)?.elements ?? [],
            units: container.lenient(UnitSystem.self, forKey: .units) ?? .metric,
            theme: container.lenient(OverlayTheme.self, forKey: .theme) ?? .raceStudio,
            isEnabled: container.lenient(Bool.self, forKey: .isEnabled) ?? true)
        self = raw.validated()
    }

    /// Writes the ``validated()`` layout in ``currentSchema`` — JSON cannot hold
    /// a NaN, so a widget with a non-finite rect is left out rather than failing
    /// the save.
    public func encode(to encoder: Encoder) throws {
        let valid = validated()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchema, forKey: .schema)
        try container.encode(valid.name, forKey: .name)
        try container.encode(valid.widgets, forKey: .widgets)
        try container.encode(valid.units, forKey: .units)
        try container.encode(valid.theme, forKey: .theme)
        try container.encode(valid.isEnabled, forKey: .isEnabled)
    }
}
