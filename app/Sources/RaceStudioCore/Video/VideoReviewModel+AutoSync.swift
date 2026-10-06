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

    /// What VoiceOver hears when a run finishes — the result's headline and
    /// detail — or `nil` while nothing has finished.
    public func announcement(locale: Locale = .current) -> String? {
        proposal.map { proposal in
            [proposal.headline(locale: locale), proposal.detail(locale: locale)]
                .compactMap { $0 }
                .joined(separator: ". ")
        }
    }
}

/// The auto-sync run (issue 9.8): a ``AudioSyncCoordinator`` driven from the
/// review, its progress and result published as ``VideoReviewModel/autoSyncState``.
/// Nothing here touches the alignment — only
/// ``VideoReviewModel/applyAudioSync(_:)`` does, on the operator's word.
public extension VideoReviewModel {

    /// Start a run the review owns, retiring (and cancelling) any run in flight.
    /// The state turns to running at once; ``cancelAutoSync()``,
    /// ``dismissAutoSync()``, applying a proposal and detaching the footage all
    /// cancel it.
    ///
    /// - Returns: the run, for a caller that wants to await it.
    @discardableResult
    func startAutoSync(_ coordinator: AudioSyncCoordinator, searchRange: ClosedRange<Double>) -> Task<Void, Never> {
        stopAutoSync()
        let generation = beginAutoSync()
        let task = Task { await self.autoSync(coordinator, searchRange: searchRange, generation: generation) }
        autoSyncTask = task
        return task
    }

    /// Run `coordinator` over `searchRange` in the calling task, publishing its
    /// phases and then its proposal; any run in flight is retired first. For
    /// tests, which await the run directly — the app uses ``startAutoSync(_:searchRange:)``.
    ///
    /// Cancelling the calling task stops the run at its next check and returns to
    /// ``AutoSyncState/idle``. ``cancelAutoSync()`` returns to idle at once and
    /// drops whatever this run later returns, but does not stop its work — the
    /// caller owns this task.
    internal func runAutoSync(_ coordinator: AudioSyncCoordinator, searchRange: ClosedRange<Double>) async {
        stopAutoSync()
        await autoSync(coordinator, searchRange: searchRange, generation: beginAutoSync())
    }

    /// The Cancel button: back to idle now; a late result is dropped.
    func cancelAutoSync() {
        stopAutoSync()
    }

    /// Dismiss a finished run's result without applying it. Only a result is
    /// dismissed: a run started meanwhile (the popover's close can land after
    /// a new click) carries on.
    func dismissAutoSync() {
        guard autoSyncState.proposal != nil else { return }
        stopAutoSync()
    }

    /// Return to idle, cancel the run the review owns, and retire whichever run
    /// is in flight.
    internal func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
        autoSyncGeneration += 1
        autoSyncState = .idle
    }

    /// Enter the running state under a new generation, and return it.
    private func beginAutoSync() -> Int {
        autoSyncGeneration += 1
        autoSyncState = .running(.reading(0))
        return autoSyncGeneration
    }

    /// Run `generation`: the decoding and matching go to a detached task, never
    /// the main actor (they block a cooperative thread while they read and
    /// match — one run at a time), and only a run still current writes its
    /// result. A cancelled run returns to idle; any other escape reads as
    /// "could not estimate".
    private func autoSync(_ coordinator: AudioSyncCoordinator, searchRange: ClosedRange<Double>,
                          generation: Int) async {
        let report: @Sendable (AudioSyncPhase) -> Void = { [weak self] phase in
            Task { @MainActor in self?.report(phase, generation: generation) }
        }
        let work = Task.detached(priority: .userInitiated) {
            try await coordinator.run(searchRange: searchRange, progress: report)
        }
        let proposal: AudioSyncProposal?
        do {
            proposal = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        } catch is CancellationError {
            proposal = nil
        } catch {
            proposal = .unavailable(.estimationFailed)
        }
        guard generation == autoSyncGeneration else { return }
        autoSyncState = proposal.map(AutoSyncState.finished) ?? .idle
        autoSyncTask = nil
    }

    /// A progress report from run `generation` — ignored once it was retired
    /// or has finished, and never moving backwards: reading progress only
    /// grows, and nothing returns from matching to reading. (Each report hops
    /// to the main actor on its own task, so the order is not guaranteed.)
    internal func report(_ phase: AudioSyncPhase, generation: Int) {
        guard generation == autoSyncGeneration, case .running(let current) = autoSyncState else { return }
        switch (current, phase) {
        case (.matching, .reading):
            return
        case (.reading(let done), .reading(let now)) where now <= done:
            return
        default:
            autoSyncState = .running(phase)
        }
    }
}
