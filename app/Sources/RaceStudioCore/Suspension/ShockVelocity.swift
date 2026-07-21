import Foundation

/// Shock (damper) velocity: the time-derivative of a suspension-position channel
/// (issue 8.17). Given a shock-travel channel, the derived velocity is what a
/// damper histogram/FFT is actually read against, so it is offered as a plottable
/// derived channel.
///
/// The differentiation policy mirrors the Rust `derived.rs` `guarded_dt` used for
/// the GPS-derived channels: a backward difference in *units per second*, the
/// first sample `0` (it has no predecessor to difference against), and a
/// non-positive `dt` — a duplicated or back-stepped timecode — guarded to `0`
/// rather than dividing by zero into ±∞/NaN.
public enum ShockVelocity {

    /// The per-sample time derivative of `position` (input value units per second).
    /// Sample times are seconds (``DataSample/time``). The result is index-aligned
    /// with the input and preserves each sample's time; an empty input yields an
    /// empty series and a lone sample yields a single `0`.
    public static func derivative(of position: [DataSample]) -> [DataSample] {
        guard position.count >= 2 else {
            // No predecessor to difference against — velocity is 0 (or nothing).
            return position.map { DataSample(time: $0.time, value: 0) }
        }
        var out: [DataSample] = []
        out.reserveCapacity(position.count)
        out.append(DataSample(time: position[0].time, value: 0))
        for i in 1..<position.count {
            let dt = position[i].time - position[i - 1].time
            let dv = position[i].value - position[i - 1].value
            // Guard a non-positive dt (duplicate/back-stepped timecode) to 0.
            let velocity = dt > 0 ? dv / dt : 0
            out.append(DataSample(time: position[i].time, value: velocity))
        }
        return out
    }

    /// A plottable derived trace of `channel`'s shock velocity, named
    /// "`<channel>` Velocity". Like every math channel it is time-keyed, so its
    /// distance basis mirrors time (see ``ChannelTrace/mathChannel(named:samples:)``)
    /// and it drops straight into the Time/Distance plot.
    public static func trace(channel: String, position: [DataSample]) -> ChannelTrace {
        let velocity = derivative(of: position)
        return .mathChannel(named: "\(channel) Velocity",
                            samples: velocity.map { MathSample(time: $0.time, value: $0.value) })
    }
}
