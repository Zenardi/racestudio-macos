import Foundation

/// Surfaces a channel's min/max-decimated envelope to the plot layer for the
/// *current viewport* (issue 7.2).
///
/// A logged endurance channel can hold millions of samples; handing them all to
/// the renderer on every layout pass stalls the UI and paints far more points
/// than the plot has pixels. This view model owns a channel's ``ChannelTrace`` and
/// vends the decimated polyline for the current x-basis, visible window, and
/// viewport width — one min/max pair per pixel column — by delegating to the
/// shared ``plotPolyline(trace:mode:visible:columns:)`` (issue 4.1), so it draws
/// the identical shape as the Metal/Swift-Charts renderers.
///
/// The last result is memoized: re-reading it while the viewport is unchanged is
/// free, and panning, zooming, switching axis, or resizing invalidates the cache.
///
/// Main-actor isolated (like ``DevicePanelModel``) so its mutable cache is never
/// raced — the plot layer that drives it already lives on the main actor.
@MainActor
public final class ChannelViewModel {
    /// The channel this view model decimates.
    public let trace: ChannelTrace

    /// Upper bound on the column count, so a pathological viewport width can't ask
    /// for an unbounded envelope. Far beyond any real display width. `nonisolated`
    /// so the `nonisolated` ``columns(forWidth:)`` can read it without tripping
    /// the Swift 6 actor-isolation check.
    public nonisolated static let maxColumns = 8192

    /// The number of envelope columns to request for a plot `width` in points —
    /// one min/max pair per pixel column. A non-positive (or non-finite) width
    /// yields no columns (nothing to draw); any positive width yields **at least
    /// one** column so a visible viewport is always decimated rather than handed
    /// the raw trace; an absurd width is clamped to ``maxColumns``.
    public nonisolated static func columns(forWidth width: Double) -> Int {
        guard width > 0, width.isFinite else { return 0 }
        // Clamp as a Double *before* the Int conversion, so a huge-but-finite width
        // (e.g. a `.greatestFiniteMagnitude` sentinel) can't trap `Int(_:)`; and
        // never round a positive width down to zero columns, which would fall
        // through to plotPolyline's "return the whole raw trace" branch.
        return max(1, Int(min(width.rounded(), Double(maxColumns))))
    }

    private struct Request: Equatable {
        let mode: XAxisMode
        let visible: ClosedRange<Double>
        let columns: Int
    }

    private var cached: (request: Request, points: [PlotPoint])?

    /// Creates a view model for `trace`.
    public init(trace: ChannelTrace) {
        self.trace = trace
    }

    /// The decimated polyline for the given x-basis, visible x-window, and viewport
    /// width (in points). Returns the memoized result when the request matches the
    /// previous call; otherwise recomputes via ``plotPolyline(trace:mode:visible:columns:)``
    /// and caches it.
    public func decimated(
        mode: XAxisMode,
        visible: ClosedRange<Double>,
        viewportWidth: Double
    ) -> [PlotPoint] {
        let request = Request(mode: mode, visible: visible, columns: Self.columns(forWidth: viewportWidth))
        if let cached, cached.request == request {
            return cached.points
        }
        let points = plotPolyline(trace: trace, mode: mode, visible: visible, columns: request.columns)
        cached = (request, points)
        return points
    }

    /// Whether a result for `mode`/`visible`/`viewportWidth` is already memoized —
    /// lets a caller (or a test) tell a cache hit from a recompute without forcing
    /// one.
    public func isCached(mode: XAxisMode, visible: ClosedRange<Double>, viewportWidth: Double) -> Bool {
        let request = Request(mode: mode, visible: visible, columns: Self.columns(forWidth: viewportWidth))
        return cached?.request == request
    }

    // MARK: - Accessibility (issue 7.3)

    /// The VoiceOver label naming this channel's plot, localized for `locale`.
    public func accessibilityLabel(locale: Locale = .current) -> String {
        L10n.format(.accessibilityChannelLabel, locale: locale, trace.name)
    }

    /// The VoiceOver value summarizing the plotted channel — its name, `unit`, and
    /// min → max range over the trace — so a VoiceOver user gets the data without
    /// sight. An empty trace reads as a localized "no data".
    public func accessibilityValue(unit: String, locale: Locale = .current) -> String {
        AccessibilitySummary.channel(
            name: trace.name,
            unit: unit,
            values: trace.samples.map(\.value),
            locale: locale)
    }
}
