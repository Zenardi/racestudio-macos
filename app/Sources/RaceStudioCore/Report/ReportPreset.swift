import Foundation

/// A Channels Report "magic wand" preset (issue 8.10): one tap populates the
/// report with a relevant set of channels and a default statistic, so an analyst
/// gets a useful view without hand-picking channels.
///
/// The channel set is matched by **name** — each preset carries a list of
/// case-insensitive keyword fragments, and any session channel whose name
/// contains one is included (in the session's own order). Matching by name keeps
/// the preset independent of a fixed channel schema, so it degrades gracefully on
/// a logger that names things differently: a preset that matches nothing simply
/// selects nothing rather than failing.
public enum ReportPreset: String, CaseIterable, Sendable, Identifiable {
    /// Engine/vehicle health — temperatures, pressures, voltages, fuel: the peaks
    /// that flag a problem, so it defaults to the **maximum**.
    case vehicleHealth
    /// Driver inputs — throttle, brake, steering, gears, revs: their typical level
    /// over the lap, so it defaults to the **average**.
    case racer
    /// Vehicle dynamics — speed, accelerations, GPS, slip: the peak envelope, so it
    /// defaults to the **maximum**.
    case vehiclePerformance

    public var id: String { rawValue }

    /// The button label in the magic-wand menu.
    public var title: String {
        switch self {
        case .vehicleHealth: return "Vehicle Health"
        case .racer: return "Racer"
        case .vehiclePerformance: return "Vehicle Performance"
        }
    }

    /// The statistic the preset selects when applied.
    public var defaultStatistic: ReportStatistic {
        switch self {
        case .vehicleHealth: return .maximum
        case .racer: return .average
        case .vehiclePerformance: return .maximum
        }
    }

    /// The lower-cased name fragments a channel must contain to be included.
    public var channelHints: [String] {
        switch self {
        case .vehicleHealth: return ["temp", "press", "oil", "water", "volt", "batt", "fuel", "lambda"]
        case .racer: return ["throttle", "brake", "steer", "rpm", "gear", "clutch", "pedal"]
        case .vehiclePerformance: return ["speed", "acc", "lat", "long", "gps", "gyro", "yaw", "slip"]
        }
    }

    /// The channels from `names` relevant to this preset (case-insensitive keyword
    /// match), in the input order and de-duplicated (first occurrence wins).
    public func matchingChannels(in names: [String]) -> [ChannelID] {
        let hints = channelHints
        var seen = Set<String>()
        return names.compactMap { name -> ChannelID? in
            let lowered = name.lowercased()
            guard hints.contains(where: { lowered.contains($0) }) else { return nil }
            guard seen.insert(name).inserted else { return nil }
            return ChannelID(name)
        }
    }
}
