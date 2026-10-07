import Combine
import Foundation

/// Runs work on the main actor after a delay (issue 9.14) — how the export
/// sheet debounces its live estimate. The app sleeps a task
/// (``TaskDelayScheduler``); the tests advance a manual clock, so a debounce
/// is checked without waiting.
public protocol DelayScheduling {
    /// Run `work` once `delay` has passed, unless the returned token is
    /// cancelled — or released — first.
    @MainActor func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable
}

/// The app's ``DelayScheduling``: a task that sleeps, then runs the work on
/// the main actor.
public struct TaskDelayScheduler: DelayScheduling {
    public init() {}

    @MainActor
    public func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        let task = Task { @MainActor in
            guard (try? await Task.sleep(for: delay)) != nil, !Task.isCancelled else { return }
            work()
        }
        return AnyCancellable { task.cancel() }
    }
}
