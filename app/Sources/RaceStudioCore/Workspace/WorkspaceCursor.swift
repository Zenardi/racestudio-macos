import Foundation
import Combine

/// The shared workspace cursor (issue 4.7): one canonical position, in the time
/// domain, that every linked view reads on its own x-basis.
///
/// The time↔distance correspondence is the 3.8 resampled `(time, distance)`
/// mapping supplied at construction; ``distancePosition`` and ``set(distance:)``
/// interpolate through it (reusing the 4.4 ``ValueAtCursor``), so a time-based
/// plot and a distance-based plot agree on the same physical point.
///
/// The package targets macOS 13, where the `@Observable` macro is unavailable,
/// so this uses `ObservableObject` like the other view-models. Cursor moves are
/// synchronous and driven from the UI thread, so no actor isolation is needed.
public final class WorkspaceCursor: ObservableObject {

    /// The cursor's time position (seconds) — the canonical value.
    @Published public private(set) var timePosition: Double

    /// The mapping in each direction, as ascending `(x → value)` series.
    private let timeToDistance: ChannelSeries
    private let distanceToTime: ChannelSeries

    /// - Parameters:
    ///   - times: ascending sample times (seconds) from the 3.8 mapping.
    ///   - distances: the cumulative distance at each of `times` (parallel).
    ///   - time: the initial cursor time.
    public init(times: [Double], distances: [Double], time: Double = 0) {
        self.timeToDistance = ChannelSeries(xs: times, values: distances)
        self.distanceToTime = ChannelSeries(xs: distances, values: times)
        self.timePosition = time
    }

    /// The cursor's distance position, interpolated from ``timePosition`` through
    /// the mapping. Falls back to the time value when there is no mapping.
    public var distancePosition: Double {
        ValueAtCursor.value(at: timePosition, in: timeToDistance).value ?? timePosition
    }

    /// Move the cursor to a time position (ignoring a non-finite value).
    public func set(time: Double) {
        guard time.isFinite else { return }
        timePosition = time
    }

    /// Move the cursor to a distance position, converting it to the canonical
    /// time through the mapping (ignoring a non-finite value).
    public func set(distance: Double) {
        guard distance.isFinite else { return }
        timePosition = ValueAtCursor.value(at: distance, in: distanceToTime).value ?? distance
    }

    /// Clamp ``timePosition`` into the session's `[firstTime, lastTime]` bounds.
    /// A no-op when there is no mapping (no bounds to clamp to).
    public func clampToBounds() {
        guard let low = timeToDistance.xs.first, let high = timeToDistance.xs.last, low <= high else { return }
        timePosition = timePosition.clamped(to: low...high)
    }
}
