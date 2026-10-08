import Foundation

/// The built-in video overlays (issue 9.10), defined in code so they always
/// match this build's widgets. Each is laid out in the 16:9 reference frame
/// inside the 3% safe area with no two widgets overlapping, and anchored to its
/// corners and edges, so in 4:3, 1:1 and 9:16 every widget stays in its place,
/// inside the safe area, still without overlaps (see `docs/handbook` — *Video
/// overlay layouts* — for the annotated diagram).
public enum OverlayPreset: String, CaseIterable, Sendable {
    /// Speed, the lap timer and the delta — the least on screen.
    case minimal
    /// The speed and RPM dials side by side, delta bar, the running lap time
    /// over lap info, G-ball, mini map, the kart badge and the sector splits.
    case kartCoaching
    /// Kart coaching plus session info, temperatures and pedals.
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
        case .minimal: return [Self.speed, Self.lapTimerAlone, Self.delta]
        case .kartCoaching: return Self.coaching + [Self.sectorSplits]
        case .fullTelemetry:
            return Self.coaching + [Self.sessionInfo, Self.sectorSplitsUnderInfo, Self.temperature, Self.pedals]
        }
    }

    private static let coaching = [kartBadge, delta, lapTimer, lapInfo, gForce, speedDial, rpmDial, trackMap]

    // Top row: the kart, the delta bar centred, the lap readouts on the right —
    // the running lap time over lap info, in one column (issue 9.16). Minimal's
    // lap timer stands alone in the corner.
    private static let kartBadge = widget(.kartBadge, .topLeading, box(0.03, 0.03, 0.24, 0.06), plate: .solid)
    private static let delta = widget(.delta, .top, box(0.35, 0.03, 0.30, 0.07))
    private static let lapTimer = widget(.lapTimer, .topTrailing, box(0.75, 0.03, 0.22, 0.09))
    private static let lapInfo = widget(.lapInfo, .topTrailing, box(0.75, 0.13, 0.22, 0.12))
    private static let lapTimerAlone = widget(.lapTimer, .topTrailing, box(0.79, 0.03, 0.18, 0.09))
    // Down the left, in the kart badge's column: session details, then the F1-
    // style sector splits (issue 9.17) — right under the badge in Kart
    // coaching. Their box holds eight sectors; the plate fits the session's.
    // The temperatures sit under lap info on the right.
    private static let sessionInfo = widget(.sessionInfo, .topLeading, box(0.03, 0.10, 0.24, 0.05))
    private static let sectorSplits = widget(.sectorTimes, .topLeading, box(0.03, 0.10, 0.24, 0.30))
    private static let sectorSplitsUnderInfo = widget(.sectorTimes, .topLeading, box(0.03, 0.16, 0.24, 0.30))
    private static let temperature = widget(.temperature, .topTrailing, box(0.85, 0.27, 0.12, 0.10))
    // Bottom row: the G-ball and the pedals on the left, the speed and RPM dials
    // side by side in the centre like a car's instrument cluster (issue 9.15) —
    // each square at 16:9, so round — and the map on the right. The G-ball is
    // taller than wide: its numbers go under the ball (issue 9.18).
    private static let gForce = widget(.gForce, .bottomLeading, box(0.03, 0.66, 0.14, 0.31))
    private static let pedals = widget(.pedals, .bottomLeading, box(0.19, 0.82, 0.06, 0.15))
    private static let speedDial = widget(.speed, .bottom, box(0.315, 0.65, 0.18, 0.32), options: needle)
    private static let rpmDial = widget(.rpm, .bottom, box(0.505, 0.65, 0.18, 0.32), options: needle)
    private static let trackMap = widget(.trackMap, .bottomTrailing, box(0.79, 0.65, 0.18, 0.32))
    // Minimal's speed stays in digits, in the corner.
    private static let speed = widget(.speed, .bottomLeading, box(0.03, 0.82, 0.14, 0.15))

    private static let needle = OverlayWidgetOptions(gaugeStyle: .needle)

    private static func widget(_ kind: OverlayWidgetKind, _ anchor: OverlayAnchor, _ frame: NormalizedRect,
                               plate: OverlayPlateStyle = .translucent,
                               options: OverlayWidgetOptions = OverlayWidgetOptions()) -> OverlayWidget {
        OverlayWidget(kind: kind, frame: frame, anchor: anchor, plate: plate, options: options)
    }

    private static func box(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> NormalizedRect {
        NormalizedRect(x: x, y: y, width: width, height: height)
    }
}
