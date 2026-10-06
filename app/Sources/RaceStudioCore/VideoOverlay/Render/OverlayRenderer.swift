import CoreGraphics
import Foundation

/// Draws a video overlay (issue 9.11): turns `(layout, frame, output size)` into
/// pixels with CoreGraphics and CoreText alone — the one routine shared by the
/// live HUD over the player and the per-frame compositor of the MP4 export, so
/// the preview matches the export pixel for pixel.
///
/// - **What:** every widget of ``OverlayLayout/drawable(for:session:)`` — the
///   visible widgets the session can feed — back to front, each in its rect
///   re-placed for the output's aspect, at its opacity.
/// - **Transparent elsewhere:** ``draw(_:in:size:)`` clears the whole output
///   first and paints only inside widget rects, so every other pixel has alpha 0
///   and the result is ready to alpha-blend over footage.
/// - **Deterministic:** no clock, no locale or other global state — numbers are
///   written by the injected ``formatter`` — and text is drawn as whole-pixel
///   glyph outlines, so the same inputs give the same bytes, run after run.
/// - **Fast:** plates, guides, the track map's line and labels are rendered once
///   per output size and cached (``StaticLayerCache``); a frame only blits them
///   and draws its values.
/// - **Shareable:** a `Sendable` value; copies share one thread-safe cache, so a
///   renderer can draw on several threads at once.
public struct OverlayRenderer: Sendable {

    /// The largest output edge the renderer draws, in pixels (8K).
    public static let maximumDimension = 8_192

    /// The layout drawn (with the renderer's units as its default units).
    public let layout: OverlayLayout
    /// The colours it is drawn in.
    public let theme: OverlayTheme
    /// How its numbers are written.
    public let formatter: OverlayFormatter
    /// What the session can feed — which widgets are drawn — and the kart and
    /// venue the badge and session info show.
    public let session: OverlaySessionContext
    /// The mini map's racing line and sector ticks.
    public let track: OverlayTrackMap
    /// The laps' sectors, for the sector times.
    public let sectors: LapSectorTimeline

    private let cache = StaticLayerCache()

    /// - Parameters:
    ///   - layout: the overlay to draw.
    ///   - theme: its colours; `nil` for the layout's own theme.
    ///   - units: the units its widgets show unless they set their own; `nil`
    ///     for the layout's.
    ///   - formatter: how numbers are written — fixed for an export.
    ///   - session: what the session can feed, its kart and its details.
    ///   - track: the mini map's racing line and sector ticks.
    ///   - sectors: the laps' sectors.
    public init(layout: OverlayLayout, theme: OverlayTheme? = nil, units: UnitSystem? = nil,
                formatter: OverlayFormatter = OverlayFormatter(), session: OverlaySessionContext,
                track: OverlayTrackMap = .empty, sectors: LapSectorTimeline = .empty) {
        var layout = layout
        if let units { layout.units = units }
        self.layout = layout
        self.theme = theme ?? layout.theme
        self.formatter = formatter
        self.session = session
        self.track = track
        self.sectors = sectors
    }

    /// Draw `frame` into `context`, a bitmap of `size` pixels in its default
    /// drawing space (origin bottom-left, one unit a pixel). The whole `size`
    /// is cleared to transparent first, so a reused buffer never shows a
    /// previous frame. A size the renderer does not draw (see
    /// ``maximumDimension``) leaves the context untouched.
    public func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        guard let pixels = OverlayPixelSize(size) else { return }
        let scene = cache.scene(for: pixels) { prepare(pixels) }
        context.saveGState()
        defer { context.restoreGState() }
        context.setBlendMode(.normal)
        context.setAlpha(1)
        context.setShouldAntialias(true)
        context.interpolationQuality = .none
        context.clear(pixels.rect)
        for widget in scene.widgets where widget.opacity > 0 {
            context.saveGState()
            context.clip(to: widget.rect)
            context.setAlpha(widget.opacity)
            if let layer = widget.staticLayer { context.draw(layer, in: widget.rect) }
            widget.drawDynamic(frame, context)
            context.restoreGState()
        }
    }

    /// `frame` drawn into a new transparent image of `size` pixels —
    /// premultiplied BGRA (the layout of `kCVPixelFormatType_32BGRA`), sRGB —
    /// or `nil` for a size the renderer does not draw.
    public func makeImage(_ frame: TelemetryFrame, size: CGSize) -> CGImage? {
        guard let pixels = OverlayPixelSize(size),
              let context = Self.makeBitmapContext(width: pixels.width, height: pixels.height) else { return nil }
        draw(frame, in: context, size: size)
        return context.makeImage()
    }

    // MARK: - Internals

    /// How many times the static layers have been built — once per output size.
    var staticLayerBuildCount: Int { cache.buildCount }

    /// A transparent bitmap in the renderer's format, or `nil` for a size it
    /// does not draw. Rows are padded to 64 bytes, the alignment CoreGraphics
    /// and CoreVideo buffers use.
    static func makeBitmapContext(width: Int, height: Int) -> CGContext? {
        guard (1...maximumDimension).contains(width), (1...maximumDimension).contains(height),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: (width * 4 + 63) / 64 * 64, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        return context
    }

    /// A widget's normalized rect (origin top-left) in a `width × height`
    /// output, as whole pixels in drawing space (origin bottom-left).
    static func pixelRect(of frame: NormalizedRect, width: Int, height: Int) -> CGRect {
        let outputWidth = Double(width), outputHeight = Double(height)
        let left = (frame.minX * outputWidth).rounded(), right = (frame.maxX * outputWidth).rounded()
        let top = (frame.minY * outputHeight).rounded(), bottom = (frame.maxY * outputHeight).rounded()
        return CGRect(x: left, y: outputHeight - bottom, width: right - left, height: bottom - top)
    }

    /// Lay out and pre-render every widget drawn at `size`.
    private func prepare(_ size: OverlayPixelSize) -> OverlayScene {
        let aspect = OverlayAspect(width: Double(size.width), height: Double(size.height))
        let widgets = layout.drawable(for: aspect, session: session).compactMap { resolved -> PreparedOverlayWidget? in
            let rect = Self.pixelRect(of: resolved.frame, width: size.width, height: size.height)
            guard rect.width >= 1, rect.height >= 1 else { return nil }
            let context = OverlayWidgetContext(widget: resolved.widget, rect: rect, outputHeight: CGFloat(size.height),
                                               theme: theme, formatter: formatter,
                                               units: layout.units(for: resolved.widget), session: session,
                                               track: track, sectors: sectors)
            return resolved.widget.kind.prepared(in: context)
        }
        return OverlayScene(widgets: widgets)
    }
}

extension OverlayWidgetKind {

    /// The drawer of every kind, by ``key`` — one per ``OverlayWidgetKind`` case
    /// (every channel readout shares one).
    static let drawers: [String: any OverlayWidgetDrawer] = [
        "speed": SpeedWidget(), "rpm": RPMWidget(), "gear": GearWidget(), "lapTimer": LapTimerWidget(),
        "lapInfo": LapInfoWidget(), "delta": DeltaWidget(), "gForce": GForceWidget(), "trackMap": TrackMapWidget(),
        "pedals": PedalsWidget(), "temperature": TemperatureWidget(), "sectorTimes": SectorTimesWidget(),
        "channelValue": ChannelValueWidget(), "kartBadge": KartBadgeWidget(), "sessionInfo": SessionInfoWidget()
    ]

    /// What draws a widget of this kind.
    var drawer: (any OverlayWidgetDrawer)? {
        Self.drawers[key]
    }

    /// A widget of this kind laid out and pre-rendered in `context`, or `nil`
    /// for a kind with no drawer.
    func prepared(in context: OverlayWidgetContext) -> PreparedOverlayWidget? {
        drawer.map { Self.prepare($0, in: context) }
    }

    private static func prepare<Drawer: OverlayWidgetDrawer>(
        _ drawer: Drawer, in context: OverlayWidgetContext
    ) -> PreparedOverlayWidget {
        let layout = drawer.layout(in: context)
        let rect = context.rect
        var staticLayer: CGImage?
        if let bitmap = OverlayRenderer.makeBitmapContext(width: Int(rect.width), height: Int(rect.height)) {
            bitmap.translateBy(x: -rect.minX, y: -rect.minY)
            drawer.drawStatic(layout, in: bitmap, context: context)
            staticLayer = bitmap.makeImage()
        }
        let drawDynamic: @Sendable (TelemetryFrame, CGContext) -> Void = { frame, graphics in
            drawer.drawDynamic(frame, layout, in: graphics, context: context)
        }
        return PreparedOverlayWidget(rect: rect, opacity: CGFloat(context.widget.opacity), staticLayer: staticLayer,
                                     drawDynamic: drawDynamic)
    }
}
