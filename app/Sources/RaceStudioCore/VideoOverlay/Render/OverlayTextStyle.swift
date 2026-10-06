import CoreGraphics
import CoreText
import Foundation
import os

/// Where a line of overlay text sits in its slot, horizontally.
enum OverlayTextAlignment: Sendable {
    case leading
    case center
    case trailing
}

/// How the video overlay draws text (issue 9.11).
///
/// - **One face:** DIN Condensed Bold — compact, legible at a glance, and a
///   font every Mac ships. Its digits all share one advance, so `1:11.111` and
///   `0:58.093` are the same width and a running time never jitters; CoreText's
///   *monospaced numbers* feature is requested too, for a face that falls back
///   in its place.
/// - **Sized from the slot:** capitals fill ``capHeightFraction`` of the slot's
///   height (scaled by the widget's size class), shrunk only if the widest text
///   the slot shows would not fit (``shrunk(toFit:width:)``) — decided once per
///   output size, never per frame.
/// - **Outlined:** every glyph is drawn over a dark outline ``outline`` pixels
///   wide, so it reads over bright footage even without a plate.
/// - **Deterministic:** glyphs are drawn as filled outlines (no font smoothing,
///   no glyph bitmaps) from a line origin on a whole pixel, each at the face's
///   own advance, so the same text renders the same pixels every time, in the
///   HUD and in the export alike. A character the face lacks is drawn in the
///   face CoreText falls back to, which may differ between macOS versions; the
///   formatter writes only characters the face has (digits, `:`, `.`, `,`,
///   `+`, `−`, `—`, `·`, `°`).
///
/// Safe to share between threads: the font is immutable and the glyph outlines
/// are cached behind a lock.
struct OverlayTextStyle: @unchecked Sendable {

    /// The face every overlay text is drawn in.
    static let fontName = "DINCondensed-Bold"
    /// How much of its slot's height a line's capitals fill.
    static let capHeightFraction: CGFloat = 0.62

    /// The font, at the size that gives ``capHeight``.
    let font: CTFont
    /// The height of the capitals (and digits), in pixels.
    let capHeight: CGFloat
    /// The dark outline's width outside each glyph, in pixels.
    let outline: CGFloat

    private let attributes: [NSAttributedString.Key: Any]
    private let outlines: GlyphOutlineCache

    /// A style whose capitals are `capHeight` pixels tall, outlined `outline` pixels.
    init(capHeight: CGFloat, outline: CGFloat) {
        let size = max(capHeight, 0.5) / Self.capHeightRatio
        let font = CTFontCreateWithFontDescriptor(Self.descriptor, size, nil)
        self.font = font
        self.capHeight = capHeight
        self.outline = max(outline, 0)
        self.attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        self.outlines = GlyphOutlineCache(font: font, outline: self.outline)
    }

    /// The style for a slot `height` pixels tall: capitals fill
    /// ``capHeightFraction`` of it, scaled by `sizeClass`.
    static func fitting(height: CGFloat, sizeClass: OverlaySizeClass = .medium, outline: CGFloat) -> OverlayTextStyle {
        OverlayTextStyle(capHeight: height * capHeightFraction * CGFloat(sizeClass.textScale), outline: outline)
    }

    /// This style, shrunk just enough for `template` — the widest text the slot
    /// shows — to fit in `width` pixels; unchanged when it already fits.
    func shrunk(toFit template: String, width: CGFloat) -> OverlayTextStyle {
        let needed = self.width(of: template)
        guard needed > width, needed > 0 else { return self }
        // Advances scale with the point size; the margin absorbs rounding.
        return OverlayTextStyle(capHeight: capHeight * width / needed * 0.995, outline: outline)
    }

    /// How wide `text` is set in this style, in pixels (outline excluded).
    func width(of text: String) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line(text), nil, nil, nil))
    }

    /// Draw `text` in `rect`: aligned horizontally, its capitals centred
    /// vertically, the outline under the fill.
    func draw(_ text: String, in rect: CGRect, alignment: OverlayTextAlignment = .center, color: CGColor,
              outlineColor: CGColor, in context: CGContext) {
        guard !text.isEmpty else { return }
        let line = line(text)
        let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let left: CGFloat
        switch alignment {
        case .leading: left = rect.minX + outline
        case .center: left = rect.midX - width / 2
        case .trailing: left = rect.maxX - outline - width
        }
        let origin = CGPoint(x: left.rounded(), y: (rect.midY - capHeight / 2).rounded())
        let fills = CGMutablePath()
        let strokes = CGMutablePath()
        for run in CTLineGetGlyphRuns(line) as? [CTRun] ?? [] {
            add(run, at: origin, fills: fills, strokes: strokes)
        }
        if outline > 0, !strokes.isEmpty {
            context.setFillColor(outlineColor)
            context.addPath(strokes)
            context.fillPath()
        }
        context.setFillColor(color)
        context.addPath(fills)
        context.fillPath()
    }

    // MARK: - Internals

    /// The face with monospaced numbers, at any size.
    private static let descriptor: CTFontDescriptor = {
        let features: [[CFString: Any]] = [[
            kCTFontFeatureTypeIdentifierKey: kNumberSpacingType,
            kCTFontFeatureSelectorIdentifierKey: kMonospacedNumbersSelector
        ]]
        let attributes: [CFString: Any] = [kCTFontNameAttribute: fontName, kCTFontFeatureSettingsAttribute: features]
        return CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
    }()

    /// The face's cap height per point.
    private static let capHeightRatio: CGFloat = {
        let reference = CTFontCreateWithFontDescriptor(descriptor, 100, nil)
        let ratio = CTFontGetCapHeight(reference) / 100
        return ratio > 0 ? ratio : 0.7
    }()

    private func line(_ text: String) -> CTLine {
        CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Add one run's glyph outlines, placed on the line, to the paths.
    private func add(_ run: CTRun, at origin: CGPoint, fills: CGMutablePath, strokes: CGMutablePath) {
        let count = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: count)
        var positions = [CGPoint](repeating: .zero, count: count)
        CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
        let runFont = Self.font(of: run) ?? font
        for (glyph, position) in zip(glyphs, positions) {
            guard let shape = outlines.outline(of: glyph, in: runFont) else { continue }
            let place = CGAffineTransform(translationX: origin.x + position.x, y: origin.y + position.y)
            fills.addPath(shape.fill, transform: place)
            if let stroke = shape.stroke { strokes.addPath(stroke, transform: place) }
        }
    }

    /// The font CoreText set `run` in — another face when ours lacks a glyph.
    private static func font(of run: CTRun) -> CTFont? {
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let value = attributes[kCTFontAttributeName],
              CFGetTypeID(value as CFTypeRef) == CTFontGetTypeID() else { return nil }
        return unsafeBitCast(value as AnyObject, to: CTFont.self)
    }
}

/// A glyph's filled shape and its outline (the shape grown by the outline
/// width), cached per glyph of one font: built the first time a glyph is drawn,
/// shared by every thread after.
final class GlyphOutlineCache: @unchecked Sendable {

    struct Outline {
        let fill: CGPath
        let stroke: CGPath?
    }

    private let font: CTFont
    private let outline: CGFloat
    private let cache = OSAllocatedUnfairLock(uncheckedState: [CGGlyph: Outline?]())

    init(font: CTFont, outline: CGFloat) {
        self.font = font
        self.outline = outline
    }

    /// `glyph`'s shapes in `runFont`; cached when that is this cache's font.
    /// `nil` for a glyph with no shape (a space).
    func outline(of glyph: CGGlyph, in runFont: CTFont) -> Outline? {
        guard CFEqual(runFont, font) else { return Self.make(glyph, in: runFont, outline: outline) }
        if let cached = cache.withLockUnchecked({ $0[glyph] }) { return cached }
        let made = Self.make(glyph, in: font, outline: outline)
        cache.withLockUnchecked { $0[glyph] = made }
        return made
    }

    private static func make(_ glyph: CGGlyph, in font: CTFont, outline: CGFloat) -> Outline? {
        guard let fill = CTFontCreatePathForGlyph(font, glyph, nil), !fill.isEmpty else { return nil }
        let stroke = outline > 0
            ? fill.copy(strokingWithWidth: outline * 2, lineCap: .round, lineJoin: .round, miterLimit: 10)
            : nil
        return Outline(fill: fill, stroke: stroke)
    }
}
