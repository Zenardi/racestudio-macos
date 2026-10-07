import Foundation

/// The Video + Data panel's strip plot (issue 9.12): speed and RPM across one
/// lap, under the player, with the cursor on it.
///
/// Sampled from the same ``TelemetryTimeline`` the HUD draws from, at evenly
/// spread instants (both ends included), so the plot and the HUD can never
/// disagree. Each trace is scaled to its own range — speed and RPM share the
/// strip's height without sharing an axis. ``fraction(atTime:)`` places the
/// cursor and ``time(atFraction:)`` turns a scrub back into a session time.
///
/// Pure value type: the view only strokes ``Trace/level(at:)`` across its width.
public struct LapStripPlot: Equatable, Sendable {

    /// The samples a lap is plotted with unless asked otherwise — finer than a
    /// strip's width in points, coarse enough to rebuild on every lap change.
    public static let defaultSampleCount = 600

    /// One plotted channel.
    public struct Trace: Equatable, Sendable {
        /// What the trace shows.
        public let role: TelemetryRole
        /// One value per sample instant, in the role's frame unit; `nil` in a gap.
        public let values: [Double?]
        /// The lowest…highest value, or `nil` without any value.
        public let domain: ClosedRange<Double>?

        public init(role: TelemetryRole, values: [Double?]) {
            self.role = role
            self.values = values
            let present = values.compactMap { $0 }.filter(\.isFinite)
            if let low = present.min(), let high = present.max() {
                self.domain = low...high
            } else {
                self.domain = nil
            }
        }

        /// How high sample `index` sits, `0` (the trace's lowest value) to `1`
        /// (its highest); a flat trace sits at `0.5`. `nil` in a gap or past the
        /// samples.
        public func level(at index: Int) -> Double? {
            guard values.indices.contains(index), let value = values[index], value.isFinite,
                  let domain else { return nil }
            let span = domain.upperBound - domain.lowerBound
            return span > 0 ? (value - domain.lowerBound) / span : 0.5
        }

        /// The trace's range for its axis label — `"80–161 km/h"`, `"8,000–13,500 rpm"`
        /// — speed in `units`, whole numbers in `locale`'s digits; `nil` without
        /// any value.
        public func rangeLabel(units: UnitSystem, locale: Locale = .current) -> String? {
            guard let domain else { return nil }
            let convert: (Double) -> Double = role == .speed ? units.speed(fromKilometresPerHour:) : { $0 }
            let unit = role == .speed ? units.speedUnit : (role.canonicalUnit ?? "")
            let low = L10n.formattedNumber(convert(domain.lowerBound).rounded(), fractionDigits: 0, locale: locale)
            let high = L10n.formattedNumber(convert(domain.upperBound).rounded(), fractionDigits: 0, locale: locale)
            return unit.isEmpty ? "\(low)–\(high)" : "\(low)–\(high) \(unit)"
        }
    }

    /// The lap plotted.
    public let lap: LapID
    /// Its session-time window.
    public let span: SessionTimeSpan
    /// The sample instants, evenly spread from the lap's start to its end.
    public let times: [Double]
    /// Speed, then RPM — each only when the session has a channel for it.
    public let traces: [Trace]

    /// Sample `timeline` across `span` (lap `lap`) at `samples` instants (at
    /// least two), tracing each of `roles` the session has a channel for.
    public init(timeline: TelemetryTimeline, lap: LapID, span: SessionTimeSpan,
                roles: [TelemetryRole] = [.speed, .rpm], samples: Int = LapStripPlot.defaultSampleCount) {
        self.lap = lap
        self.span = span
        let count = max(2, samples)
        let times = (0..<count).map { span.start + span.duration * Double($0) / Double(count - 1) }
        self.times = times
        var cursor = SamplingCursor()
        let frames = times.map { timeline.frame(at: $0, cursor: &cursor) }
        self.traces = roles
            .filter { timeline.channelMap.isAvailable($0) }
            .map { role in Trace(role: role, values: frames.map { $0[role] }) }
    }

    /// Where `time` sits across the strip — `0` at the lap's start, `1` at its
    /// end — or `nil` outside the lap (the cursor is then off the strip).
    public func fraction(atTime time: Double) -> Double? {
        guard time.isFinite, span.duration > 0, time >= span.start, time <= span.end else { return nil }
        return (time - span.start) / span.duration
    }

    /// The session time at `fraction` across the strip — a scrub — held to the
    /// lap (a non-finite fraction reads as its start).
    public func time(atFraction fraction: Double) -> Double {
        let held = fraction.isFinite ? min(max(fraction, 0), 1) : 0
        return span.start + span.duration * held
    }
}
