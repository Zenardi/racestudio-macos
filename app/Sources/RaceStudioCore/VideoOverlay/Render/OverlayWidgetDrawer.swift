import CoreGraphics
import Foundation

/// Draws one kind of overlay widget (issue 9.11) in two parts, so the renderer
/// redraws only what moves:
///
/// - ``drawStatic(_:in:context:)`` — the plate, guides and labels: drawn once
///   per output size into the renderer's static-layer cache;
/// - ``drawDynamic(_:_:in:context:)`` — the frame's values, every frame.
///
/// ``layout(in:)`` places the parts (slots, sized fonts) once per output size;
/// both draws reuse it. Drawers draw in the context's drawing space (origin
/// bottom-left, `y` up, one unit a pixel), inside ``OverlayWidgetContext/rect``.
protocol OverlayWidgetDrawer: Sendable {
    /// Where the widget's parts sit in its rect, and the text styles they use.
    associatedtype Layout: Sendable

    /// Place the widget's parts in `context`'s rect.
    func layout(in context: OverlayWidgetContext) -> Layout

    /// Draw what never changes from frame to frame.
    func drawStatic(_ layout: Layout, in graphics: CGContext, context: OverlayWidgetContext)

    /// The texts ``drawDynamic(_:_:in:context:)`` writes for `frame`, in
    /// drawing order — a missing value is `—`, never a stale or zero one.
    func readouts(_ frame: TelemetryFrame, context: OverlayWidgetContext) -> [String]

    /// Draw `frame`'s values over the static part.
    func drawDynamic(_ frame: TelemetryFrame, _ layout: Layout, in graphics: CGContext,
                     context: OverlayWidgetContext)
}

/// Everything a widget drawer draws with (issue 9.11): the widget, its rect in
/// the output, the colours, the formatter and units, and what the session can
/// say beyond one frame (the kart, the venue, the track map, the sectors).
/// Fixed for one renderer, widget and output size.
struct OverlayWidgetContext: Sendable {
    let widget: OverlayWidget
    /// The widget's rect in the output, in whole pixels, drawing space.
    let rect: CGRect
    /// The output's height in pixels — what line widths scale with.
    let outputHeight: CGFloat
    let palette: OverlayPalette
    let formatter: OverlayFormatter
    /// The units this widget shows.
    let units: UnitSystem
    let session: OverlaySessionContext
    let track: OverlayTrackMap
    let sectors: LapSectorTimeline

    init(widget: OverlayWidget, rect: CGRect, outputHeight: CGFloat, theme: OverlayTheme,
         formatter: OverlayFormatter, units: UnitSystem, session: OverlaySessionContext,
         track: OverlayTrackMap, sectors: LapSectorTimeline) {
        self.widget = widget
        self.rect = rect
        self.outputHeight = outputHeight
        self.palette = OverlayPalette(theme: theme, plate: widget.plate)
        self.formatter = formatter
        self.units = units
        self.session = session
        self.track = track
        self.sectors = sectors
    }

    /// The widget's kind-specific settings.
    var options: OverlayWidgetOptions { widget.options }

    /// Output pixels per pixel of a 1080-line frame — what strokes scale by.
    var scale: CGFloat { max(outputHeight, 1) / 1080 }

    /// The dark legibility outline round text and marks: one pixel at 1080p,
    /// never thinner than a pixel.
    var outline: CGFloat { max(1, scale) }

    /// The gap between the plate's edge and the widget's content.
    var padding: CGFloat { (min(rect.width, rect.height) * 0.1).rounded() }

    /// The rect the widget's content is laid out in.
    var content: CGRect { rect.insetBy(dx: padding, dy: padding) }

    /// A text style for `slot`: capitals fill their share of its height (by the
    /// widget's size class), shrunk so `template` — the widest text the slot
    /// shows — fits its width.
    func style(for slot: CGRect, fitting template: String) -> OverlayTextStyle {
        OverlayTextStyle.fitting(height: slot.height, sizeClass: widget.sizeClass, outline: outline)
            .shrunk(toFit: template, width: max(slot.width - 2 * outline, 1))
    }

    /// A label in the export language (the formatter's locale).
    func label(_ key: L10n.Key) -> String {
        L10n.string(key, locale: formatter.locale)
    }

    /// Fill the widget's plate, if it has one: a rounded rect over the whole rect.
    ///
    /// The plate is the first thing in a static layer, drawn over nothing, so
    /// it is *copied* rather than blended — the same pixels. Blending a wide
    /// translucent fill was seen to race inside CoreGraphics (macOS 26) with
    /// translucent fills on other threads: its last few columns took the other
    /// fill's colour. Copying takes another path, and keeps renders on several
    /// threads at once byte-identical (`OverlayRendererTests`).
    func drawPlate(in graphics: CGContext) {
        guard let plate = palette.plate else { return }
        let radius = min(min(rect.width, rect.height) * 0.14, 14 * scale)
        graphics.saveGState()
        graphics.setBlendMode(.copy)
        graphics.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        graphics.setFillColor(plate)
        graphics.fillPath()
        graphics.restoreGState()
    }

    /// Write `text` in `slot` with `style`: in `color` (the readout colour by
    /// default), a missing value's `—` always in the secondary colour.
    func draw(_ text: String, _ style: OverlayTextStyle, in slot: CGRect, alignment: OverlayTextAlignment = .center,
              color: CGColor? = nil, in graphics: CGContext) {
        let ink = text == OverlayFormatter.missing ? palette.secondary : color ?? palette.text
        style.draw(text, in: slot, alignment: alignment, color: ink, outlineColor: palette.outline, in: graphics)
    }
}

/// The overlay theme's colours, made once per widget (issue 9.11).
struct OverlayPalette: @unchecked Sendable {
    /// Readouts.
    let text: CGColor
    /// Labels, units and missing values.
    let secondary: CGColor
    /// The RPM bar and the position dots.
    let accent: CGColor
    /// Gaining time.
    let gain: CGColor
    /// Losing time.
    let loss: CGColor
    /// The shift light.
    let warning: CGColor
    /// The dark outline round text and marks — the plate's colour, opaque.
    let outline: CGColor
    /// Unlit bars, guides and rings.
    let guide: CGColor
    /// The widget's plate, or `nil` for none.
    let plate: CGColor?
    private let accentColor: BrandColor

    init(theme: OverlayTheme, plate style: OverlayPlateStyle) {
        accentColor = theme.accent
        text = Self.color(theme.text)
        secondary = Self.color(theme.secondaryText)
        accent = Self.color(theme.accent)
        gain = Self.color(theme.gain)
        loss = Self.color(theme.loss)
        warning = Self.color(theme.warning)
        outline = Self.color(theme.plate.withAlpha(1))
        guide = Self.color(theme.secondaryText.withAlpha(0.35))
        plate = theme.plateFill(style).map(Self.color)
    }

    /// The accent at `alpha` — the G-ball trail's fading dots.
    func accent(alpha: CGFloat) -> CGColor {
        Self.color(accentColor.withAlpha(Double(alpha)))
    }

    /// `color` as an sRGB `CGColor`.
    static func color(_ color: BrandColor) -> CGColor {
        CGColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }
}

extension CGRect {
    /// This rect with its edges rounded to whole pixels — fills land on pixel
    /// boundaries, so a bar's length is exact and renders the same everywhere.
    var pixelAligned: CGRect {
        let left = minX.rounded(), right = maxX.rounded(), bottom = minY.rounded(), top = maxY.rounded()
        return CGRect(x: left, y: bottom, width: max(right - left, 0), height: max(top - bottom, 0))
    }
}
