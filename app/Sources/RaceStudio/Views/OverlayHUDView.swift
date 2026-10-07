import SwiftUI
import AppKit
import AVKit
import RaceStudioCore

/// The Video + Data player with the live telemetry HUD drawn over its footage
/// (issue 9.12).
///
/// An `AVPlayerView` (no built-in controls — the panel's transport, the strip
/// plot and the measures bar drive it) with two layer-backed views over it,
/// both laid on the **visible video rect** — the footage's presentation size
/// fitted into the view, as the aspect-fit player draws it — so the HUD sits on
/// the picture, not the letterbox or pillarbox bars, and the preview's
/// geometry is the export's:
///
/// - a dimming plate, shown while the footage doesn't cover the cursor;
/// - the HUD, whose `CALayer.contents` is an image from the shared
///   ``OverlayRenderer``, drawn on a private serial queue at the rect's size in
///   pixels — never 4K — with only the `contents` swap on the main thread.
///
/// Thin: what to draw and when comes from ``VideoDataViewModel``; this view
/// only renders it. The visible rect is reported back for the overlay editor.
struct OverlayHUDView: NSViewRepresentable {
    let player: AVPlayer
    /// The HUD's renderer, or `nil` to draw no HUD.
    let renderer: OverlayRenderer?
    /// The frame the HUD shows.
    let frame: TelemetryFrame?
    /// Whether to dim the footage — it doesn't cover the cursor.
    let dimsFootage: Bool
    /// Told the visible video rect (top-left origin, in points) as it changes.
    let onVideoRect: (CGRect) -> Void

    func makeNSView(context: Context) -> PlayerHUDContainer {
        let view = PlayerHUDContainer(player: player)
        view.onVideoRect = onVideoRect
        return view
    }

    func updateNSView(_ view: PlayerHUDContainer, context: Context) {
        view.onVideoRect = onVideoRect
        if view.playerView.player !== player { view.playerView.player = player }
        view.dimView.isHidden = !dimsFootage
        view.hudView.show(frame, with: renderer)
    }

    static func dismantleNSView(_ view: PlayerHUDContainer, coordinator: ()) {
        view.stopObserving()
    }
}

/// The player, the dimming plate and the HUD, the last two kept on the visible
/// video rect.
final class PlayerHUDContainer: NSView {
    let playerView = AVPlayerView()
    let dimView = NSView()
    let hudView = HUDLayerView()
    var onVideoRect: (CGRect) -> Void = { _ in }
    private var observations: [NSKeyValueObservation] = []
    private var reportedRect: CGRect = .null

    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerView.player = player
        playerView.controlsStyle = .none
        playerView.videoGravity = .resizeAspect
        dimView.wantsLayer = true
        dimView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        dimView.isHidden = true
        for view in [playerView, dimView, hudView] as [NSView] { addSubview(view) }
        // The picture's size arrives once the item is ready (documented KVO);
        // the player view's own video bounds are watched too.
        let relayout: () -> Void = { [weak self] in DispatchQueue.main.async { self?.needsLayout = true } }
        observations = [
            player.observe(\.currentItem?.presentationSize, options: [.new]) { _, _ in relayout() },
            playerView.observe(\.videoBounds, options: [.new]) { _, _ in relayout() }
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func stopObserving() {
        observations.forEach { $0.invalidate() }
        observations = []
    }

    /// Clicks go to the SwiftUI overlays (the editor), never to the player.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        playerView.frame = bounds
        let video = visibleVideoRect
        dimView.frame = video
        hudView.frame = video
        // SwiftUI lays out top-down; report the rect that way.
        let topLeft = CGRect(x: video.minX, y: isFlipped ? video.minY : bounds.height - video.maxY,
                             width: video.width, height: video.height)
        if topLeft != reportedRect {
            reportedRect = topLeft
            let report = onVideoRect
            DispatchQueue.main.async { report(topLeft) }
        }
    }

    /// Where the footage is drawn: its presentation size fitted into the view
    /// (the player's aspect-fit gravity), else the player's own video bounds,
    /// else the whole view until the footage has a size.
    private var visibleVideoRect: CGRect {
        if let size = playerView.player?.currentItem?.presentationSize, size.width > 0, size.height > 0 {
            return AVMakeRect(aspectRatio: size, insideRect: bounds)
        }
        let video = playerView.videoBounds
        guard video.width > 0, video.height > 0 else { return bounds }
        return playerView.convert(video, to: self)
    }
}

/// A layer-backed view showing the HUD image. Rendering runs on a private
/// serial queue at the view's size in pixels; only the newest frame is drawn
/// (frames arriving mid-render replace each other), and only the `contents`
/// swap happens on the main thread. A render that finishes after the layout or
/// the size changed is still shown — the newer one is already queued — so a
/// fast drag never leaves the HUD frozen; only a cleared HUD drops it.
final class HUDLayerView: NSView {
    private let renderQueue = DispatchQueue(label: "com.aim.racestudio.hud", qos: .userInteractive)
    private var renderer: OverlayRenderer?
    private var frameToShow: TelemetryFrame?
    private var isRendering = false
    private var needsAnotherRender = false
    /// Bumped whenever the HUD is cleared (no renderer or no frame), so a render
    /// begun before never brings a hidden HUD back.
    private var clearings = 0
    /// The pixel size the renderer's static layers were last prepared for.
    private var preparedSize: CGSize = .zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer?.contentsGravity = .resize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Show `frame` drawn by `renderer` (no HUD for a `nil` renderer).
    func show(_ frame: TelemetryFrame?, with renderer: OverlayRenderer?) {
        // A renderer drawing something else (a layout or session change) is
        // prepared afresh; an equal one keeps the warm static layers.
        let newRenderer = !Self.sameRenderer(renderer, self.renderer)
        if newRenderer {
            self.renderer = renderer
            preparedSize = .zero
        }
        guard newRenderer || frame != frameToShow else { return }
        frameToShow = frame
        scheduleRender()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scheduleRender()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        scheduleRender()
    }

    /// The view's size in whole pixels, held to what the renderer draws.
    private var pixelSize: CGSize {
        let scale = window?.backingScaleFactor ?? 2
        let limit = CGFloat(OverlayRenderer.maximumDimension)
        return CGSize(width: min((bounds.width * scale).rounded(), limit),
                      height: min((bounds.height * scale).rounded(), limit))
    }

    private func scheduleRender() {
        guard let renderer, let frame = frameToShow, bounds.width >= 1, bounds.height >= 1 else {
            clearings += 1
            layer?.contents = nil
            return
        }
        guard !isRendering else {
            needsAnotherRender = true
            return
        }
        isRendering = true
        let size = pixelSize, clearing = clearings, prepare = preparedSize != size
        preparedSize = size
        renderQueue.async { [weak self] in
            if prepare { renderer.prepare(for: size) }
            let image = renderer.makeImage(frame, size: size)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRendering = false
                if clearing == self.clearings {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self.layer?.contents = image
                    CATransaction.commit()
                }
                if self.needsAnotherRender {
                    self.needsAnotherRender = false
                    self.scheduleRender()
                }
            }
        }
    }

    /// Whether two renderers draw the same thing — the same layout, theme,
    /// units, formatter, session, track and sectors.
    private static func sameRenderer(_ lhs: OverlayRenderer?, _ rhs: OverlayRenderer?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?):
            return lhs.layout == rhs.layout && lhs.theme == rhs.theme && lhs.formatter == rhs.formatter
                && lhs.session == rhs.session && lhs.track == rhs.track && lhs.sectors == rhs.sectors
        default: return false
        }
    }
}
