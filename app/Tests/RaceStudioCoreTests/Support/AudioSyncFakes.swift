import Foundation

@testable import RaceStudioCore

/// A canned clip of three samples at the requested rate starting at
/// `startTime`, reported in two progress steps — or a failure, a read that
/// reports half its progress and then never ends, or one that takes `delay`.
struct FakeSource: AudioPCMSource {
    var startTime: Double = 0
    var failure: Error?
    var hangs = false
    var delay: UInt64 = 0

    func monoPCM(targetRate: Int, progress: @escaping @Sendable (Double) -> Void) async throws -> MonoPCM {
        if hangs {
            progress(0.5)
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        if let failure { throw failure }
        progress(0.5)
        progress(1)
        return MonoPCM(samples: [0.1, 0.2, 0.3], sampleRate: targetRate, startTime: startTime)
    }
}

/// Wait until `condition` holds or `seconds` of wall time pass — a deadline,
/// so a loaded CI runner waits as long as it needs to.
func waitUntil(within seconds: Int = 10, _ condition: @Sendable () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// What the fake estimator returns.
enum FakeOutcome {
    case confident(offset: Double)
    case weak(offset: Double)

    var estimate: AudioSyncEstimate {
        switch self {
        case .confident(let offset):
            return AudioSyncEstimate(offset: offset, score: 3, peakRatio: 3.5, pitchPerRPM: 1.0 / 120,
                                     isConfident: true, confidence: 0.9)
        case .weak(let offset):
            return AudioSyncEstimate(offset: offset, score: 0.8, peakRatio: 1.1, pitchPerRPM: 1.0 / 120,
                                     isConfident: false, confidence: 0.2)
        }
    }
}

/// An estimator that records its calls and returns `result`.
final class FakeEstimator: AudioSyncEstimating, @unchecked Sendable {
    struct Call: Equatable {
        let samples: Int
        let sampleRate: Int
        let rpmChannel: String
        let searchRange: ClosedRange<Double>
    }

    private let result: Result<FakeOutcome, Error>
    private let lock = NSLock()
    private var recorded: [Call] = []

    init(result: Result<FakeOutcome, Error>) {
        self.result = result
    }

    var calls: [Call] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func estimate(pcm: [Float], sampleRate: Int, rpmChannel: String,
                  searchRange: ClosedRange<Double>) throws -> AudioSyncEstimate {
        lock.lock()
        recorded.append(Call(samples: pcm.count, sampleRate: sampleRate, rpmChannel: rpmChannel,
                             searchRange: searchRange))
        lock.unlock()
        return try result.get().estimate
    }
}

/// A coordinator over a ``FakeSource`` and a ``FakeEstimator``.
func fakeCoordinator(_ source: any AudioPCMSource = FakeSource(),
                     _ outcome: FakeOutcome = .confident(offset: -10)) -> AudioSyncCoordinator {
    AudioSyncCoordinator(source: source, estimator: FakeEstimator(result: .success(outcome)), rpmChannel: "RPM")
}

/// A thread-safe record of progress phases.
final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [AudioSyncPhase] = []

    func record(_ phase: AudioSyncPhase) {
        lock.lock()
        stored.append(phase)
        lock.unlock()
    }

    var values: [AudioSyncPhase] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
