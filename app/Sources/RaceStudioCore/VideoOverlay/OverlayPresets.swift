import Foundation

/// The built-in video overlays (issue 9.10), defined in code so they always
/// match this build's widgets. Each is laid out in the 16:9 reference frame
/// inside the 3% safe area with no two widgets overlapping, and anchored so it
/// re-places sensibly in 4:3, 1:1 and 9:16 (see `docs/handbook` — *Video
/// overlay layouts* — for the annotated diagram).
public enum OverlayPreset: String, CaseIterable, Sendable {
    /// Speed, the lap timer and the delta — the least on screen.
    case minimal
    /// Speed, RPM bar, delta bar, lap info, G-ball, mini map and the kart badge.
    case kartCoaching
    /// Kart coaching plus session info, sector times, temperatures and pedals.
    case fullTelemetry

    /// The preset's name in `locale`, as the preset menu shows it.
    public func title(locale: Locale = .current) -> String {
        switch self {
        case .minimal: return L10n.string(.overlayPresetMinimal, locale: locale)
        case .kartCoaching: return L10n.string(.overlayPresetKartCoaching, locale: locale)
        case .fullTelemetry: return L10n.string(.overlayPresetFullTelemetry, locale: locale)
        }
    }

    /// The preset as a layout named in `locale`: shown, metric, in the RaceStudio
    /// theme. Widgets the session cannot feed (pedals on a kart without pedal
    /// sensors, say) stay in the layout and are skipped when drawn.
    public func layout(locale: Locale = .current) -> OverlayLayout {
        OverlayLayout(name: title(locale: locale), widgets: widgets)
    }

    /// Every built-in, in menu order.
    public static func builtIns(locale: Locale = .current) -> [OverlayLayout] {
        allCases.map { $0.layout(locale: locale) }
    }

    // MARK: - Geometry (16:9, origin top-left)

    private var widgets: [OverlayWidget] {
        switch self {
        case .minimal: return [Self.speed, Self.lapTimer, Self.delta]
        case .kartCoaching: return Self.coaching
        case .fullTelemetry: return Self.coaching + [Self.sessionInfo, Self.sectorTimes, Self.temperature, Self.pedals]
        }
    }

    private static let coaching = [kartBadge, delta, lapInfo, gForce, speed, rpm, trackMap]

    // Top row: the kart, the delta bar centred, the lap readouts on the right.
    private static let kartBadge = widget(.kartBadge, .topLeading, box(0.03, 0.03, 0.24, 0.06), plate: .solid)
    private static let delta = widget(.delta, .top, box(0.35, 0.03, 0.30, 0.07))
    private static let lapTimer = widget(.lapTimer, .topTrailing, box(0.79, 0.03, 0.18, 0.09))
    private static let lapInfo = widget(.lapInfo, .topTrailing, box(0.75, 0.03, 0.22, 0.12))
    // Under them: session details on the left, sectors and temperatures on the right.
    private static let sessionInfo = widget(.sessionInfo, .topLeading, box(0.03, 0.10, 0.24, 0.05))
    private static let sectorTimes = widget(.sectorTimes, .topTrailing, box(0.79, 0.17, 0.18, 0.16))
    private static let temperature = widget(.temperature, .topTrailing, box(0.85, 0.35, 0.12, 0.10))
    // Bottom row: G-ball over the speed and pedals, the RPM bar centred, the map.
    private static let gForce = widget(.gForce, .bottomLeading, box(0.03, 0.59, 0.12, 0.21))
    private static let speed = widget(.speed, .bottomLeading, box(0.03, 0.82, 0.14, 0.15))
    private static let pedals = widget(.pedals, .bottomLeading, box(0.19, 0.82, 0.06, 0.15))
    private static let rpm = widget(.rpm, .bottom, box(0.30, 0.89, 0.40, 0.08))
    private static let trackMap = widget(.trackMap, .bottomTrailing, box(0.79, 0.65, 0.18, 0.32))

    private static func widget(_ kind: OverlayWidgetKind, _ anchor: OverlayAnchor, _ frame: NormalizedRect,
                               plate: OverlayPlateStyle = .translucent) -> OverlayWidget {
        OverlayWidget(kind: kind, frame: frame, anchor: anchor, plate: plate)
    }

    private static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}
