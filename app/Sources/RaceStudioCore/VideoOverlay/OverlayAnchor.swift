import Foundation

/// Where one axis of a widget is pinned (issue 9.10): to the frame's start edge
/// (left / top), its centre, or its end edge (right / bottom).
public enum OverlayAxisAnchor: Sendable {
    case start
    case center
    case end
}

/// The corner, edge or centre a widget is pinned to (issue 9.10). When a layout
/// is resolved for an output of another aspect, the widget keeps its margin to
/// this anchor — a lap timer in the top-right stays in the top-right — rather
/// than being stretched with the frame.
public enum OverlayAnchor: String, Codable, CaseIterable, Sendable {
    case topLeading
    case top
    case topTrailing
    case leading
    case center
    case trailing
    case bottomLeading
    case bottom
    case bottomTrailing

    /// The edge the widget's horizontal position is kept relative to.
    public var horizontal: OverlayAxisAnchor {
        switch self {
        case .topLeading, .leading, .bottomLeading: return .start
        case .top, .center, .bottom: return .center
        case .topTrailing, .trailing, .bottomTrailing: return .end
        }
    }

    /// The edge the widget's vertical position is kept relative to.
    public var vertical: OverlayAxisAnchor {
        switch self {
        case .topLeading, .top, .topTrailing: return .start
        case .leading, .center, .trailing: return .center
        case .bottomLeading, .bottom, .bottomTrailing: return .end
        }
    }
}

/// How far a rect sits from its ``OverlayAnchor`` on each axis (issue 9.10): the
/// margin to the anchored start or end edge, or — on a centred axis — the
/// centre's position. Resolving a layout for another aspect keeps these.
public struct OverlayAnchorOffsets: Equatable, Sendable {
    public let horizontal: Double
    public let vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// The shape of an output frame, width ÷ height (issue 9.10) — what a layout is
/// resolved for. Layouts are authored at ``reference`` (16:9).
public struct OverlayAspect: Equatable, Hashable, Sendable {
    /// Width ÷ height; always finite and positive.
    public let ratio: Double

    /// The aspect of a `width × height` frame (pixels or any unit). A size with
    /// no usable shape (zero, negative, not finite) is the 16:9 reference.
    public init(width: Double, height: Double) {
        let ratio = width / height
        self.ratio = ratio.isFinite && ratio > 0 ? ratio : 16.0 / 9.0
    }

    /// 16:9 landscape — HD and 4K footage.
    public static let widescreen = OverlayAspect(width: 16, height: 9)
    /// 4:3 — action cameras' full-sensor modes.
    public static let standard = OverlayAspect(width: 4, height: 3)
    /// 1:1 — square social posts.
    public static let square = OverlayAspect(width: 1, height: 1)
    /// 9:16 portrait — phone-first video.
    public static let vertical = OverlayAspect(width: 9, height: 16)

    /// The frame every layout is authored in.
    public static let reference = widescreen

    /// The output aspects a layout is proven against.
    public static let common: [OverlayAspect] = [.widescreen, .standard, .square, .vertical]
}
