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
    /// Distance-paired samples per channel (issue 8.7); windowed reads slice them.
    private let distanceBanks: [[DistanceSample]]
    /// Delta-t series keyed by `(reference, comparison)` lap index (issue 8.7).
    private let deltas: [DeltaKey: [DeltaSample]]
    /// When set, every `deltaT(...)` call throws it (the error path).
    private let deltaError: Error?
    /// The canned per-lap split times this fake serves (issue 8.11).
    private let segments: [LapSegments]
    /// Spectra keyed by `(channel, window function)` (issue 8.16); an absent key
    /// throws ``UnknownChannel``, so a test can seed a different spectrum per taper.
    private let spectra: [SpectrumKey: ChannelSpectrum]
    /// When set, every `spectrum(...)` call throws it (the error path).
    private let spectrumError: Error?
    /// The canned track detection this fake serves (issue 9.2); `nil` models a
    /// session that matched no bundled track (the beacon fallback).
    private let detectedTrack: DetectedTrackInfo?

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

    /// A `(reference, comparison)` lap-index key for a canned delta-t series.
    struct DeltaKey: Hashable {
        let reference: UInt32
        let comparison: UInt32
    }

    /// One recorded `deltaT(...)` call, so a test can assert the pair + distance
    /// window `AnalysisSession` forwarded across the seam.
    struct DeltaRequest: Equatable {
        let reference: UInt32
        let comparison: UInt32
        let start: Double
        let end: Double
    }

    /// The most recent `deltaT(...)` call, or `nil` when it was never invoked.
    private(set) var lastDeltaRequest: DeltaRequest?

    /// The `splits` of the most recent `segmentTimes(...)` call, or `nil` when it
    /// was never invoked (issue 8.11).
    private(set) var lastSegmentSplits: UInt32?

    /// A `(channel, window function)` key for a canned spectrum (issue 8.16).
    struct SpectrumKey: Hashable {
        let channel: String
        let windowFunction: SpectrumWindowKind
    }

    /// One recorded `spectrum(...)` call, so a test can assert the channel, taper,
    /// and window bounds `AnalysisSession` forwarded across the seam (issue 8.16).
    struct SpectrumRequest: Equatable {
        let channel: String
        let windowFunction: SpectrumWindowKind
        let start: Double
        let end: Double
    }

    /// The most recent `spectrum(...)` call, or `nil` when it was never invoked.
    private(set) var lastSpectrumRequest: SpectrumRequest?

    struct UnknownChannel: Error {}

    init(banks: [[DataSample]], stats: [String: ChannelStats] = [:], statsError: Error? = nil,
         gps: [GPSTrackPoint] = [], distanceBanks: [[DistanceSample]] = [],
         deltas: [DeltaKey: [DeltaSample]] = [:], deltaError: Error? = nil,
         segments: [LapSegments] = [],
         spectra: [SpectrumKey: ChannelSpectrum] = [:], spectrumError: Error? = nil,
         detectedTrack: DetectedTrackInfo? = nil) {
        self.banks = banks
        self.stats = stats
        self.statsError = statsError
        self.gps = gps
        self.distanceBanks = distanceBanks
        self.deltas = deltas
        self.deltaError = deltaError
        self.segments = segments
        self.spectra = spectra
        self.spectrumError = spectrumError
        self.detectedTrack = detectedTrack
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

    func samplesWithDistance(channelIndex: UInt32, start: UInt32, count: UInt32) -> [DistanceSample] {
        guard Int(channelIndex) < distanceBanks.count else { return [] }
        let bank = distanceBanks[Int(channelIndex)]
        let lo = min(Int(start), bank.count)
        let take = min(Int(count), bank.count - lo)
        return Array(bank[lo..<(lo + take)])
    }

    func deltaT(referenceLap: UInt32, comparisonLap: UInt32, start: Double, end: Double) throws -> [DeltaSample] {
        lastDeltaRequest = DeltaRequest(reference: referenceLap, comparison: comparisonLap, start: start, end: end)
        if let deltaError { throw deltaError }
        return deltas[DeltaKey(reference: referenceLap, comparison: comparisonLap)] ?? []
    }

    func segmentTimes(splits: UInt32) -> [LapSegments] {
        lastSegmentSplits = splits
        return segments
    }

    func detectTrack() -> DetectedTrackInfo? {
        detectedTrack
    }

    func spectrum(channel: String, windowFunction: SpectrumWindowKind,
                  start: Double, end: Double) throws -> ChannelSpectrum {
        lastSpectrumRequest = SpectrumRequest(
            channel: channel, windowFunction: windowFunction, start: start, end: end)
        if let spectrumError { throw spectrumError }
        guard let value = spectra[SpectrumKey(channel: channel, windowFunction: windowFunction)] else {
            throw UnknownChannel()
        }
        return value
    }
}
