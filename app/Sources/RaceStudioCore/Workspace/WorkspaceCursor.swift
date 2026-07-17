import Foundation
import Combine

/// The shared workspace cursor (issue 4.7): one canonical position, in the time
/// domain, that every linked view reads on its own x-basis.
///
/// The time↔distance correspondence is the 3.8 resampled `(time, distance)`
/// mapping supplied at construction; ``distancePosition`` and ``set(distance:)``
/// interpolate through it (reusing the 4.4 ``ValueAtCursor``), so a time-based
/// plot and a distance-based plot agree on the same physical point. Every setter
/// clamps into the session bounds, so the two positions never disagree and a
/// broadcast never carries an out-of-bounds cursor.
///
/// `@MainActor` so `@Published` mutations are observed on the main actor (like
/// the sibling view-models); the package targets macOS 13, where the
/// `@Observable` macro is unavailable, so it uses `ObservableObject`.
@MainActor
public final class WorkspaceCursor: ObservableObject {

    /// The cursor's time position (seconds) — the canonical, in-bounds value.
    @Published public private(set) var timePosition: Double

    /// The mapping in each direction, as ascending `(x → value)` series.
    private let timeToDistance: ChannelSeries
    private let distanceToTime: ChannelSeries

    /// - Parameters:
    ///   - times: the sample times (seconds) from the 3.8 mapping.
    ///   - distances: the cumulative distance at each of `times`, the same length
    ///     as `times`.
    ///   - time: the initial cursor time (clamped into bounds; a non-finite value
    ///     falls back to the first sample).
    /// - Precondition: `times` and `distances` are **parallel, strictly ascending**
    ///   arrays — a monotonic basis such as a single lap or a session whose
    ///   distance never resets/reverses. The conversion binary-searches them, so a
    ///   non-monotonic or mismatched-length basis yields an unspecified position
    ///   (the same contract as ``ValueAtCursor``).
    public init(times: [Double], distances: [Double], time: Double = 0) {
        self.timeToDistance = ChannelSeries(xs: times, values: distances)
        self.distanceToTime = ChannelSeries(xs: distances, values: times)
        // Sanitize the initial value here too: the setters guard non-finite input,
        // but init assigns `timePosition` directly and must not let a NaN through.
        let start = time.isFinite ? time : (timeToDistance.xs.first ?? 0)
        self.timePosition = Self.clamp(start, into: timeToDistance.xs)
    }

    /// The cursor's distance position, interpolated from ``timePosition`` through
    /// the mapping. Falls back to the time value when there is no mapping.
    public var distancePosition: Double {
        ValueAtCursor.value(at: timePosition, in: timeToDistance).value ?? timePosition
    }

    /// Move the cursor to a time position, clamped into the session bounds
    /// (ignoring a non-finite value).
    public func set(time: Double) {
        guard time.isFinite else { return }
        timePosition = Self.clamp(time, into: timeToDistance.xs)
    }

    /// Move the cursor to a distance position, converting it to the canonical
    /// time through the mapping and clamping into bounds (ignoring a non-finite
    /// value).
    public func set(distance: Double) {
        guard distance.isFinite else { return }
        let time = ValueAtCursor.value(at: distance, in: distanceToTime).value ?? distance
        timePosition = Self.clamp(time, into: timeToDistance.xs)
    }

    /// Clamp ``timePosition`` into the session's `[firstTime, lastTime]` bounds.
    /// Idempotent — the setters already clamp — and a no-op when there is no
    /// mapping (no bounds to clamp to).
    public func clampToBounds() {
        timePosition = Self.clamp(timePosition, into: timeToDistance.xs)
    }

    /// Clamp `time` into `[times.first, times.last]`, or return it unchanged when
    /// there are no bounds.
    private static func clamp(_ time: Double, into times: [Double]) -> Double {
        guard let low = times.first, let high = times.last, low <= high else { return time }
        return time.clamped(to: low...high)
    }
}
