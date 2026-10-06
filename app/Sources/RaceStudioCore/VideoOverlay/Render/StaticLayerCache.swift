import CoreGraphics
import Foundation
import os

/// An output size in whole pixels, as the renderer draws it.
struct OverlayPixelSize: Hashable, Sendable {
    let width: Int
    let height: Int

    /// `size` rounded to whole pixels, or `nil` when the renderer does not draw
    /// it (not finite, under a pixel, or past ``OverlayRenderer/maximumDimension``).
    init?(_ size: CGSize) {
        // Range-checked as doubles first: converting a huge finite value to
        // `Int` traps, and NaN is in no range.
        let drawable = 1...Double(OverlayRenderer.maximumDimension)
        let width = Double(size.width).rounded(), height = Double(size.height).rounded()
        guard drawable.contains(width), drawable.contains(height) else { return nil }
        self.width = Int(width)
        self.height = Int(height)
    }

    var rect: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
}

/// One widget ready to draw at one output size: its rect, its opacity, its
/// pre-rendered static layer and the closure that draws a frame's values.
struct PreparedOverlayWidget: @unchecked Sendable {
    /// The widget's rect, whole pixels, drawing space.
    let rect: CGRect
    let opacity: CGFloat
    /// The plate, guides and labels, rendered once at the rect's size.
    let staticLayer: CGImage?
    /// Draws a frame's values (layout and fonts already resolved).
    let drawDynamic: @Sendable (TelemetryFrame, CGContext) -> Void
}

/// Everything the renderer draws at one output size, back to front.
struct OverlayScene: Sendable {
    let widgets: [PreparedOverlayWidget]
}

/// The renderer's static layers, per output size (issue 9.11).
///
/// What never changes from frame to frame — plates, gauge tracks, ring guides,
/// the track map's line and ticks, labels — is laid out and rendered **once
/// per output size**, together with each widget's text styles; every frame then
/// only blits those layers and draws the values.
///
/// **Thread safety.** One cache belongs to one ``OverlayRenderer`` (copies of
/// the renderer share it) and may be used from any number of threads at once —
/// the HUD's render queue and the export's workers alike. It is a `final class`
/// behind an `OSAllocatedUnfairLock`: a size's scene is built *under* the lock,
/// so a second thread asking for the same size waits for the first build
/// instead of repeating it, and is immutable afterwards (images, fonts, glyph
/// outlines behind their own lock), so frames are drawn outside the lock. (The
/// renderer also serializes whole draws process-wide, working round a
/// CoreGraphics race — see ``OverlayRenderer`` — but the cache does not rely on
/// it.) The most recent ``capacity`` sizes are kept, so a window being resized
/// does not pile up layers.
final class StaticLayerCache: @unchecked Sendable {

    /// How many output sizes are kept.
    static let capacity = 4

    private struct State {
        /// Least recently used first.
        var scenes: [(size: OverlayPixelSize, scene: OverlayScene)] = []
        var builds = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    /// The scene for `size`, built by `build` the first time that size is asked for.
    func scene(for size: OverlayPixelSize, build: () -> OverlayScene) -> OverlayScene {
        state.withLockUnchecked { state in
            if let index = state.scenes.firstIndex(where: { $0.size == size }) {
                let hit = state.scenes.remove(at: index)
                state.scenes.append(hit)
                return hit.scene
            }
            let scene = build()
            state.builds += 1
            state.scenes.append((size, scene))
            if state.scenes.count > Self.capacity { state.scenes.removeFirst() }
            return scene
        }
    }

    /// How many scenes have been built — once per size, unless evicted.
    var buildCount: Int {
        state.withLockUnchecked { $0.builds }
    }
}
