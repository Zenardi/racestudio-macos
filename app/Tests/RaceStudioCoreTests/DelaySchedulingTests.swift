import Foundation
import Testing
@testable import RaceStudioCore

/// The app's delay scheduler (issue 9.14): the work runs on the main actor
/// once the delay has passed, unless it is cancelled first.
@MainActor
@Suite struct TaskDelaySchedulerTests {

    @Test func test_scheduled_work_runs_after_the_delay() async {
        let ran = Flag()

        let token = TaskDelayScheduler().schedule(after: .milliseconds(1)) { ran.set() }
        await ran.wait()

        #expect(ran.isSet)
        token.cancel()
    }

    @Test func test_cancelled_work_never_runs() async throws {
        let ran = Flag()

        TaskDelayScheduler().schedule(after: .milliseconds(20)) { ran.set() }.cancel()
        try await Task.sleep(for: .milliseconds(120))

        #expect(!ran.isSet)
    }
}

/// A flag set once from the main actor, awaitable.
@MainActor
final class Flag {
    private(set) var isSet = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func set() {
        isSet = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func wait() async {
        guard !isSet else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
