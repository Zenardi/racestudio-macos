import Foundation
import Combine

/// The window-level shared cursor (issue 8.3): it promotes the 4.7
/// ``WorkspaceCursor`` (the canonical time↔distance position) and
/// ``LinkedViewRegistry`` (the broadcast fan-out) into one object every panel of
/// the analysis window links against.
///
/// SwiftUI panels observe ``timePosition`` — republished on every move — so a
/// measures bar or a plot redraws when the cursor changes. Imperative consumers
/// (e.g. the Metal renderer) ``register(_:)`` for an explicit callback; a move
/// fans out to every registered view *except* its originator, so a view that
/// moved the cursor never receives its own echo.
///
/// `@MainActor` because it mutates `@Published` state and delivers callbacks on
/// the UI thread; the package targets macOS 13, where `@Observable` is
/// unavailable, so it is an `ObservableObject`.
@MainActor
public final class LinkedCursor: ObservableObject {

    /// The canonical shared cursor: the in-bounds time position and the
    /// time↔distance mapping every panel reads on its own x-basis.
    public let cursor: WorkspaceCursor

    /// The cursor's time position (seconds), republished on every move so
    /// observing panels re-render.
    @Published public private(set) var timePosition: Double

    /// The `[first, last]` time extent of the basis, or `nil` when there is no
    /// basis (an empty session). The view maps a scrub position into this range.
    public let timeBounds: ClosedRange<Double>?

    private let registry = LinkedViewRegistry()

    /// - Parameters:
    ///   - times: the sample times (seconds) of the 3.8 mapping — the same
    ///     strictly-ascending basis ``WorkspaceCursor`` requires.
    ///   - distances: the cumulative distance at each of `times`.
    ///   - time: the initial cursor time (clamped into bounds).
    public init(times: [Double], distances: [Double], time: Double = 0) {
        let cursor = WorkspaceCursor(times: times, distances: distances, time: time)
        self.cursor = cursor
        self.timePosition = cursor.timePosition
        if let low = times.first, let high = times.last, low <= high {
            self.timeBounds = low...high
        } else {
            self.timeBounds = nil
        }
    }

    /// The cursor's distance position, interpolated through the mapping.
    public var distancePosition: Double { cursor.distancePosition }

    /// The cursor's usable scrub range — its ``timeBounds`` when they have
    /// positive width, else `nil` (a single-instant or basis-less session, where
    /// a slider over a zero-width range is meaningless). Kept in Core, not the
    /// view, so the empty/degenerate decision is covered by tests.
    public var scrubRange: ClosedRange<Double>? {
        guard let bounds = timeBounds, bounds.lowerBound < bounds.upperBound else { return nil }
        return bounds
    }

    /// Register `view` to receive cursor-move callbacks (idempotent by identity).
    public func register(_ view: CursorLinked) { registry.register(view) }

    /// Stop delivering cursor-move callbacks to `view`.
    public func unregister(_ view: CursorLinked) { registry.unregister(view) }

    /// Move the cursor to `time`, republish the (clamped) position, and fan the
    /// move out to every registered view except `origin`. Pass `origin` when the
    /// mover is itself a registered view (so it is not re-notified); omit it for a
    /// non-registered input, which then reaches every registered view.
    public func moveTime(_ time: Double, from origin: CursorLinked? = nil) {
        cursor.set(time: time)
        publishAndBroadcast(from: origin)
    }

    /// Move the cursor to a distance position (converted to the canonical time
    /// through the mapping), then republish and fan out as ``moveTime(_:from:)``.
    public func moveDistance(_ distance: Double, from origin: CursorLinked? = nil) {
        cursor.set(distance: distance)
        publishAndBroadcast(from: origin)
    }

    private func publishAndBroadcast(from origin: CursorLinked?) {
        timePosition = cursor.timePosition
        if let origin {
            registry.broadcast(cursor, from: origin)
        } else {
            registry.broadcastToAll(cursor)
        }
    }
}
