import Foundation

/// Where an *Auto-sync from engine sound* stands (issue 9.8).
public enum AutoSyncState: Equatable, Sendable {
    /// Nothing running, nothing to show.
    case idle
    /// Running: decoding the audio or matching it.
    case running(AudioSyncPhase)
    /// Finished with a proposal for the operator to apply or dismiss.
    case finished(AudioSyncProposal)

    /// Whether a run is in progress (the panel shows its progress and Cancel).
    public var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    /// The finished run's proposal, if there is one.
    public var proposal: AudioSyncProposal? {
        if case .finished(let proposal) = self { return proposal }
        return nil
    }
}

/// The auto-sync run (issue 9.8): a ``AudioSyncCoordinator`` driven from the
/// review, its progress and result published as ``VideoReviewModel/autoSyncState``.
/// Nothing here touches the alignment — only
/// ``VideoReviewModel/applyAudioSync(_:)`` does, on the operator's word.
public extension VideoReviewModel {

    /// Run `coordinator` over `searchRange`, publishing its phases and then its
    /// proposal. The decoding and matching run off the main actor.
    ///
    /// Cancelling the calling task stops the run at its next check and returns to
    /// ``AutoSyncState/idle``; so does ``cancelAutoSync()`` at once, dropping
    /// whatever the run later returns. Either way the sync is left as it was.
    func runAutoSync(_ coordinator: AudioSyncCoordinator, searchRange: ClosedRange<Double>) async {
        autoSyncGeneration += 1
        let generation = autoSyncGeneration
        autoSyncState = .running(.reading(0))
        let proposal = try? await coordinator.run(searchRange: searchRange) { phase in
            Task { @MainActor [weak self] in self?.report(phase, generation: generation) }
        }
        guard generation == autoSyncGeneration else { return }
        autoSyncState = proposal.map(AutoSyncState.finished) ?? .idle
    }

    /// The Cancel button: back to idle now; a late result is dropped.
    func cancelAutoSync() {
        stopAutoSync()
    }

    /// Dismiss a finished run's result without applying it.
    func dismissAutoSync() {
        stopAutoSync()
    }

    /// Return to idle and retire the run in flight.
    internal func stopAutoSync() {
        autoSyncGeneration += 1
        autoSyncState = .idle
    }

    /// A progress report from run `generation` — ignored once it was retired
    /// or has finished.
    private func report(_ phase: AudioSyncPhase, generation: Int) {
        guard generation == autoSyncGeneration, autoSyncState.isRunning else { return }
        autoSyncState = .running(phase)
    }
}
