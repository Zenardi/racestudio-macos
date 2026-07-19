import Foundation
@testable import RaceStudioCore

/// An in-memory ``SessionDataSource`` for the M8 analysis tests (issue 8.1): it
/// serves canned per-channel sample banks and pre-seeded stats **without the
/// xcframework**, so `AnalysisSession`'s windowing/clamping logic is covered
/// FFI-free.
///
/// It records the last `samples(...)` request so a test can assert that
/// `AnalysisSession` clamped the window itself (rather than relying on a real
/// FFI's bounded read to hide an over-read). Like a real handle it also bounds
/// its own read defensively, so an unclamped request never traps here.
final class FakeSessionDataSource: SessionDataSource, @unchecked Sendable {

    /// Full samples per channel, indexed by `channelIndex`.
    private let banks: [[DataSample]]
    /// Stats keyed by channel name; a name that is absent throws ``unknownChannel``.
    private let stats: [String: ChannelStats]
    /// When set, every `statistics(...)` call throws it (the error path).
    private let statsError: Error?
    /// The whole GPS track this fake serves (issue 8.6); windowed reads slice it.
    private let gps: [GPSTrackPoint]

    /// One recorded `samples(...)` request, so a test can assert the window
    /// `AnalysisSession` actually issued across the seam.
    struct SampleRequest: Equatable {
        let channelIndex: UInt32
        let start: UInt32
        let count: UInt32
    }

    /// The most recent `samples(...)` call, or `nil` when it was never invoked
    /// (e.g. a zero-width window that `AnalysisSession` short-circuits).
    private(set) var lastRequest: SampleRequest?

    /// One recorded `statistics(...)` call, so a test can assert the exact
    /// `TimeWindow` bounds `AnalysisSession` forwarded (not swapped, not `.all`).
    struct StatsRequest: Equatable {
        let channel: String
        let start: Double
        let end: Double
    }

    /// The most recent `statistics(...)` call, or `nil` if never invoked.
    private(set) var lastStatsRequest: StatsRequest?

    /// The most recent `gpsTrack(...)` call, so a test can assert the window
    /// `AnalysisSession` forwarded across the seam.
    struct GPSRequest: Equatable {
        let start: UInt32
        let count: UInt32
    }

    /// The most recent `gpsTrack(...)` call, or `nil` when it was never invoked.
    private(set) var lastGPSRequest: GPSRequest?

    struct UnknownChannel: Error {}

    init(banks: [[DataSample]], stats: [String: ChannelStats] = [:], statsError: Error? = nil,
         gps: [GPSTrackPoint] = []) {
        self.banks = banks
        self.stats = stats
        self.statsError = statsError
        self.gps = gps
    }

    func samples(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DataSample] {
        lastRequest = SampleRequest(channelIndex: channelIndex, start: start, count: count)
        guard Int(channelIndex) < banks.count else { return [] }
        let bank = banks[Int(channelIndex)]
        let lo = min(Int(start), bank.count)
        let hi = min(lo + Int(count), bank.count)
        return Array(bank[lo..<hi])
    }

    func statistics(channel: String, start: Double, end: Double) throws -> ChannelStats {
        lastStatsRequest = StatsRequest(channel: channel, start: start, end: end)
        if let statsError { throw statsError }
        guard let value = stats[channel] else { throw UnknownChannel() }
        return value
    }

    func gpsTrack(start: UInt32, count: UInt32) -> [GPSTrackPoint] {
        lastGPSRequest = GPSRequest(start: start, count: count)
        // Bound the window to the real fix count exactly as a live handle would,
        // so an unclamped `.all` (count `.max`) request never traps here.
        let lo = min(Int(start), gps.count)
        let take = min(Int(count), gps.count - lo)
        return Array(gps[lo..<(lo + take)])
    }
}
