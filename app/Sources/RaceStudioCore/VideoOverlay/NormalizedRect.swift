import Foundation

/// A rectangle in a video frame's normalized space (issue 9.10): fractions of
/// the frame on each axis, origin at the **top-left** corner and `y` growing
/// downwards — the way an operator reads a frame and drags a widget. The
/// renderer flips it into CoreGraphics' bottom-up space when it draws.
///
/// The axes are normalized independently, so the same numbers are a different
/// *shape* in a different frame: `0.18 × 0.32` is square in 16:9 and tall in
/// 1:1 (``aspectRatio(in:)``). An ``OverlayLayout`` is authored in the 16:9
/// reference frame, re-placed per output by ``resolved(in:anchor:safeMargin:)``
/// and mapped back by ``reference(from:in:anchor:safeMargin:)``.
public struct NormalizedRect: Codable, Equatable, Hashable, Sendable {
    /// The left edge, as a fraction of the frame's width.
    public var x: Double
    /// The top edge, as a fraction of the frame's height.
    public var y: Double
    /// The width, as a fraction of the frame's width.
    public var width: Double
    /// The height, as a fraction of the frame's height.
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The whole frame.
    public static let unit = NormalizedRect(x: 0, y: 0, width: 1, height: 1)

    /// The frame inset by `margin` on every side — the title-safe area a widget
    /// must stay inside.
    public static func safeArea(margin: Double) -> NormalizedRect {
        NormalizedRect(x: margin, y: margin, width: 1 - 2 * margin, height: 1 - 2 * margin)
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }

    /// Whether every component is a finite number.
    public var isFinite: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
    }

    /// Whether this rect lies inside `other`, touching its edges allowed (with
    /// `tolerance` for rounding).
    public func isContained(in other: NormalizedRect, tolerance: Double = roundingTolerance) -> Bool {
        minX >= other.minX - tolerance && minY >= other.minY - tolerance
            && maxX <= other.maxX + tolerance && maxY <= other.maxY + tolerance
    }

    /// The area this rect shares with `other`; `0` when they only touch or are
    /// apart.
    public func overlapArea(with other: NormalizedRect) -> Double {
        let overlapWidth = min(maxX, other.maxX) - max(minX, other.minX)
        let overlapHeight = min(maxY, other.maxY) - max(minY, other.minY)
        return overlapWidth > 0 && overlapHeight > 0 ? overlapWidth * overlapHeight : 0
    }

    /// The rect's width ÷ height in the pixels of a frame of `aspect`.
    public func aspectRatio(in aspect: OverlayAspect) -> Double {
        width * aspect.ratio / height
    }

    /// Where this rect sits relative to `anchor`, per axis — what
    /// ``resolved(in:anchor:safeMargin:)`` keeps.
    public func offsets(from anchor: OverlayAnchor) -> OverlayAnchorOffsets {
        func offset(_ start: Double, _ length: Double, _ axis: OverlayAxisAnchor) -> Double {
            switch axis {
            case .start: return start
            case .center: return start + length / 2
            case .end: return 1 - (start + length)
            }
        }
        return OverlayAnchorOffsets(horizontal: offset(x, width, anchor.horizontal),
                                    vertical: offset(y, height, anchor.vertical))
    }

    /// This rect sized to between `minimumSize` and `bounds`' size on each axis,
    /// then moved (never resized) to lie inside `bounds`.
    ///
    /// A value within rounding (``roundingTolerance``) of its limit is left bit
    /// for bit — `0.65 + 0.32` lands one rounding error past `0.97` — so a layout
    /// snapped to round numbers survives validation, and so a save, unchanged.
    /// Total: a NaN component takes the low end of its range and an infinity its
    /// limit, so the result is always finite and inside — though a non-finite
    /// rect has no meaningful place, which is why ``OverlayLayout/validated()``
    /// drops it first.
    public func clamped(to bounds: NormalizedRect, minimumSize: Double = 0) -> NormalizedRect {
        let width = Self.clamp(width, min(minimumSize, bounds.width), bounds.width)
        let height = Self.clamp(height, min(minimumSize, bounds.height), bounds.height)
        return NormalizedRect(x: Self.clamp(x, bounds.minX, bounds.maxX - width),
                              y: Self.clamp(y, bounds.minY, bounds.maxY - height),
                              width: width, height: height)
    }

    /// This rect, authored in the 16:9 reference frame, re-placed for an output of
    /// `aspect`:
    ///
    /// - **size** — the widget keeps its pixel shape. In a frame narrower than
    ///   16:9 (4:3, 1:1, 9:16) it keeps its share of the frame's *width* and gives
    ///   up height; in a wider one, its share of the *height*. Either way it only
    ///   ever shrinks;
    /// - **position** — on each axis it keeps its margin to its `anchor` edge
    ///   (or, centred, its centre), so it shrinks toward its anchor, inside its
    ///   authored rect. A layout inside the safe area with no two widgets
    ///   overlapping at 16:9 is therefore inside it, without overlaps, in every
    ///   aspect;
    /// - **bounds** — a rect too big for the `safeMargin` safe area (one
    ///   ``OverlayLayout/validated()`` would have fixed) shrinks, shape kept, to
    ///   fit, and is kept inside it.
    ///
    /// At the reference aspect a rect inside the safe area comes back bit for bit.
    /// ``reference(from:in:anchor:safeMargin:)`` maps a resolved rect back.
    public func resolved(in aspect: OverlayAspect, anchor: OverlayAnchor,
                         safeMargin: Double = OverlayLayout.safeMargin) -> NormalizedRect {
        let scale = Self.scale(for: aspect)
        var newWidth = width * scale.horizontal
        var newHeight = height * scale.vertical
        let available = 1 - 2 * safeMargin
        let fit = min(1, available / newWidth, available / newHeight)
        newWidth *= fit
        newHeight *= fit
        let placed = NormalizedRect(
            x: Self.place(start: x, length: width, newLength: newWidth, anchor: anchor.horizontal),
            y: Self.place(start: y, length: height, newLength: newHeight, anchor: anchor.vertical),
            width: newWidth, height: newHeight)
        return placed.clamped(to: .safeArea(margin: safeMargin))
    }

    /// The 16:9 reference rect that ``resolved(in:anchor:safeMargin:)`` places at
    /// `rect` in an output of `aspect` — how an editor that drags a widget on the
    /// output's own frame stores what it dragged. Kept inside the safe area.
    ///
    /// Exact for every rect the forward map can produce. In an output of
    /// another aspect a widget shrinks toward its anchor, so it can't reach the
    /// last stretch of the frame on its anchor's side (a bottom-anchored widget
    /// in 9:16 can't touch the top): a rect dragged there maps to the nearest
    /// reference rect inside the safe area, which resolves back short of it. An
    /// editor working in such an output should re-anchor the widget toward
    /// where it is dragged, or edit in the 16:9 reference frame.
    public static func reference(from rect: NormalizedRect, in aspect: OverlayAspect, anchor: OverlayAnchor,
                                 safeMargin: Double = OverlayLayout.safeMargin) -> NormalizedRect {
        let scale = scale(for: aspect)
        let width = rect.width / scale.horizontal
        let height = rect.height / scale.vertical
        let authored = NormalizedRect(
            x: place(start: rect.x, length: rect.width, newLength: width, anchor: anchor.horizontal),
            y: place(start: rect.y, length: rect.height, newLength: height, anchor: anchor.vertical),
            width: width, height: height)
        return authored.clamped(to: .safeArea(margin: safeMargin))
    }

    // MARK: - Internals

    /// What a rect's width and height are multiplied by for an output of
    /// `aspect`: a narrower frame keeps the width share and scales the height, a
    /// wider one keeps the height share and scales the width — the pixel shape is
    /// kept, and neither factor exceeds `1`.
    private static func scale(for aspect: OverlayAspect) -> (horizontal: Double, vertical: Double) {
        let relative = aspect.ratio / OverlayAspect.reference.ratio
        return (min(1, 1 / relative), min(1, relative))
    }

    /// The new start of a span resized from `length` to `newLength` that keeps
    /// its margin to its anchored edge (or its centre). Exact when the length is
    /// unchanged; it is its own inverse with the lengths swapped.
    private static func place(start: Double, length: Double, newLength: Double,
                              anchor: OverlayAxisAnchor) -> Double {
        switch anchor {
        case .start: return start
        case .center: return start + (length - newLength) / 2
        case .end: return start + (length - newLength) // the end edge, so its margin, stays put
        }
    }

    /// How far past a limit a value may sit and still count as on it — far below
    /// a pixel at 8K, far above the rounding of sums like `0.65 + 0.32`.
    public static let roundingTolerance = 1e-9

    /// `value` clamped to `low…high`, left as it is within ``roundingTolerance``
    /// of the range; NaN reads as `low`.
    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        if value.isNaN || value < low - roundingTolerance { return low }
        if value > high + roundingTolerance { return high }
        return value
    }
}
