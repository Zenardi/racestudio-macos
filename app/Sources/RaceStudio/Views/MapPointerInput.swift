import AppKit
import SwiftUI
import RaceStudioCore

/// The track map's mouse-wheel, middle-button and pinch input, which SwiftUI has
/// no gestures for on macOS 13: the wheel zooms about the pointer, dragging with the
/// wheel pressed (the middle button) moves the map, and a trackpad pinch zooms about
/// the pointer.
///
/// Placed behind the map, sized to it. It never takes part in hit testing, so plain
/// clicks and drags still reach SwiftUI (they move the cursor); it watches the
/// window's events instead and only claims those over its own bounds.
struct MapPointerInput: NSViewRepresentable {
    /// Zoom by a factor about a point in the map's coordinates (top-left origin).
    var onZoom: (_ factor: Double, _ anchor: CGPoint) -> Void
    /// Move the map by a drag of this many points.
    var onPan: (_ translation: CGSize) -> Void

    func makeNSView(context: Context) -> InputView {
        let view = InputView()
        view.onZoom = onZoom
        view.onPan = onPan
        return view
    }

    func updateNSView(_ view: InputView, context: Context) {
        view.onZoom = onZoom
        view.onPan = onPan
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class InputView: NSView {
        var onZoom: (Double, CGPoint) -> Void = { _, _ in }
        var onPan: (CGSize) -> Void = { _ in }
        private var monitor: Any?
        /// Where the middle-button drag was last seen, while one is in progress.
        private var dragLocation: CGPoint?
        /// The button number AppKit gives a pressed mouse wheel.
        private static let wheelButton = 2

        override var isFlipped: Bool { true }

        /// Invisible to hit testing: the map's own gestures get every click.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .magnify, .otherMouseDown, .otherMouseDragged, .otherMouseUp]
            ) { [weak self] event in
                guard let self else { return event }
                return self.handle(event) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            dragLocation = nil
        }

        /// `true` when the event was the map's, so no other view acts on it too.
        private func handle(_ event: NSEvent) -> Bool {
            guard let window, event.windowNumber == window.windowNumber, !isHiddenOrHasHiddenAncestor else {
                return false
            }
            let location = convert(event.locationInWindow, from: nil)
            switch event.type {
            case .scrollWheel, .magnify:
                guard bounds.contains(location) else { return false }
                zoom(with: event, at: location)
                return true
            // The wheel button only: a mouse's back / forward buttons are
            // "other" buttons too, and must keep their own meaning.
            case .otherMouseDown, .otherMouseDragged, .otherMouseUp:
                guard event.buttonNumber == Self.wheelButton else { return false }
                return drag(event.type, at: location)
            default:
                return false
            }
        }

        private func zoom(with event: NSEvent, at location: CGPoint) {
            if event.type == .magnify {
                onZoom(1 + Double(event.magnification), location)
                return
            }
            // The physical direction: "natural" scrolling inverts the delta, but
            // rolling the wheel away should zoom in either way.
            let delta = Double(event.scrollingDeltaY) * (event.isDirectionInvertedFromDevice ? -1 : 1)
            guard delta != 0 else { return }
            onZoom(MapViewport.scrollZoomFactor(delta: delta, isPrecise: event.hasPreciseScrollingDeltas), location)
        }

        /// A middle-button drag: it must start over the map, and then follows the
        /// pointer anywhere until the button is released.
        private func drag(_ type: NSEvent.EventType, at location: CGPoint) -> Bool {
            switch type {
            case .otherMouseDown:
                guard bounds.contains(location) else { return false }
                dragLocation = location
            case .otherMouseDragged:
                guard let last = dragLocation else { return false }
                dragLocation = location
                onPan(CGSize(width: location.x - last.x, height: location.y - last.y))
            default:
                guard dragLocation != nil else { return false }
                dragLocation = nil
            }
            return true
        }
    }
}
