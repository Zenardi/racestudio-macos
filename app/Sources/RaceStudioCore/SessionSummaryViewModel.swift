import Foundation

/// The metadata panel: vehicle/track/driver as-is (with an em-dash fallback for
/// empty fields) and a stably-formatted session date (issue 2.4).
public struct MetadataPanelModel: Equatable, Sendable {
    public let vehicle: String
    public let track: String
    public let driver: String
    public let date: String

    init(_ metadata: SessionMetadata) {
        self.vehicle = ChannelFormatting.orEmDash(metadata.vehicle)
        self.track = ChannelFormatting.orEmDash(metadata.track)
        self.driver = ChannelFormatting.orEmDash(metadata.driver)
        self.date = ChannelFormatting.date(epochSeconds: metadata.datetimeUtc)
    }
}

/// One row in the channel list: name, unit (em-dash when dimensionless), and a
/// formatted sample rate (e.g. `"100 Hz"`, or em-dash when unknown).
public struct ChannelRowModel: Equatable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let unit: String
    public let rate: String

    public init(id: Int, name: String, unit: String, rate: String) {
        self.id = id
        self.name = name
        self.unit = unit
        self.rate = rate
    }
}

/// One row in the lap list: a 1-based number, a `m:ss.mmm` lap time, and whether
/// it is the fastest lap.
public struct LapRowModel: Equatable, Identifiable, Sendable {
    public let id: Int
    public let number: Int
    public let time: String
    public let isBest: Bool

    public init(id: Int, number: Int, time: String, isBest: Bool) {
        self.id = id
        self.number = number
        self.time = time
        self.isBest = isBest
    }
}

/// The presentation model for the session summary screen (issue 2.4): a metadata
/// panel, a channel list, and a lap list, derived purely from a decoded
/// ``Session``.
///
/// All formatting/fallback/best-lap logic lives here so the SwiftUI views in the
/// shell are trivial bindings.
public struct SessionSummaryViewModel: Equatable, Sendable {
    public let metadata: MetadataPanelModel
    public let channels: [ChannelRowModel]
    public let laps: [LapRowModel]

    public init(session: Session) {
        self.metadata = MetadataPanelModel(session.metadata)
        self.channels = session.channels.enumerated().map { index, channel in
            ChannelRowModel(
                id: index,
                name: channel.name,
                unit: ChannelFormatting.orEmDash(channel.unit),
                rate: ChannelFormatting.rate(hz: channel.sampleRateHz))
        }
        let bestIndex = Self.bestLapIndex(session.laps)
        self.laps = session.laps.enumerated().map { index, lap in
            LapRowModel(
                id: index,
                number: index + 1,
                time: LapTimeFormatter.string(from: lap.durationS),
                isBest: index == bestIndex)
        }
    }

    /// The index of the fastest valid lap (minimum duration; ties resolve to the
    /// earliest lap), or `nil` when there is no valid lap.
    private static func bestLapIndex(_ laps: [Lap]) -> Int? {
        laps.enumerated()
            .filter { $0.element.durationS.isFinite && $0.element.durationS >= 0 }
            .min { $0.element.durationS < $1.element.durationS }?
            .offset
    }
}
