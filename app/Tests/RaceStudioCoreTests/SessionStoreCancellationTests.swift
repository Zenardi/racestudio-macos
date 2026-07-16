import Testing
import Foundation
import Combine
@testable import RaceStudioCore

/// Tests for the `SessionStore` progress/cancellation additions (issue 2.5):
/// `.loading(DecodeProgress)` threading, `cancel()`, and new-load-cancels-prior.
@Suite struct SessionStoreCancellationTests {

    /// A loader that emits scripted progress, optionally suspends until the task
    /// is cancelled, then returns/throws a preset result — no real Rust decode.
    /// Immutable (all `let`), so it is safely `Sendable` across the executor hop.
    private final class ScriptedLoader: SessionLoading, Sendable {
        let progresses: [Double]
        let result: Result<Session, Error>
        let suspendUntilCancelled: Bool

        init(progresses: [Double] = [], result: Result<Session, Error>, suspendUntilCancelled: Bool = false) {
            self.progresses = progresses
            self.result = result
            self.suspendUntilCancelled = suspendUntilCancelled
        }

        func load(_ url: URL, onProgress: @escaping @MainActor (DecodeProgress) -> Void) async throws -> Session {
            for fraction in progresses {
                await onProgress(DecodeProgress(fraction: fraction, phase: .decoding))
            }
            if suspendUntilCancelled {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            }
            return try result.get()
        }
    }

    /// A loader that routes by URL — `suspendingURL` suspends until cancelled and
    /// would return `first`, any other URL returns `second` immediately. Immutable,
    /// so no mid-flight mutation / data race when a second load supersedes the first.
    private final class RoutingLoader: SessionLoading, Sendable {
        let suspendingURL: URL
        let first: Session
        let second: Session

        init(suspendingURL: URL, first: Session, second: Session) {
            self.suspendingURL = suspendingURL
            self.first = first
            self.second = second
        }

        func load(_ url: URL, onProgress: @escaping @MainActor (DecodeProgress) -> Void) async throws -> Session {
            if url == suspendingURL {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return first
            }
            return second
        }
    }

    private func session() throws -> Session { try GoldenSession.load("aim_official_test") }
    private var anyURL: URL { URL(fileURLWithPath: "/tmp/x.xrk") }

    /// Spin (bounded) until the store reports `.loading` — the scripted loader is
    /// suspended, so this returns almost immediately; the bound prevents a hang if
    /// a load ever races past `.loading` without being observed.
    @MainActor private func waitUntilLoading(_ store: SessionStore) async {
        for _ in 0..<100_000 {
            if case .loading = store.state { return }
            await Task.yield()
        }
    }

    // MARK: - Progress

    @MainActor @Test func test_loading_ends_at_full_before_loaded() async throws {
        let decoded = try session()
        let store = SessionStore(loader: ScriptedLoader(progresses: [0.2, 0.6], result: .success(decoded)))
        var observed: [LoadState] = []
        let subscription = store.$state.sink { observed.append($0) }

        await store.load(url: anyURL)
        subscription.cancel()

        let fractions = observed.compactMap { state -> Double? in
            if case let .loading(progress) = state { return progress.fraction }
            return nil
        }
        #expect(fractions == fractions.sorted())   // monotonic
        #expect(fractions.last == 1.0)             // ends at full
        #expect(observed.last == .loaded(SessionViewModel(session: decoded)))
    }

    // MARK: - Cancellation

    @MainActor @Test func test_cancel_returns_to_idle_without_loaded() async throws {
        let store = SessionStore(
            loader: ScriptedLoader(progresses: [0.5], result: .success(try session()), suspendUntilCancelled: true))
        let loadTask = Task { await store.load(url: anyURL) }
        await waitUntilLoading(store)

        store.cancel()
        await loadTask.value

        #expect(store.state == .idle)
        #expect(store.viewModel == nil)
    }

    @MainActor @Test func test_cancel_when_not_loading_keeps_loaded_session() async throws {
        let store = SessionStore(loader: ScriptedLoader(result: .success(try session())))
        await store.load(url: anyURL)
        #expect(store.viewModel != nil)

        store.cancel() // nothing in flight → must not discard the loaded session

        guard case .loaded = store.state else {
            Issue.record("cancel() discarded the loaded session, got \(store.state)")
            return
        }
    }

    @MainActor @Test func test_new_load_cancels_previous_load() async throws {
        let first = try session()
        // A distinct session so the final assertion actually distinguishes the
        // second load's result from the (cancelled) first's.
        let second = Session(
            metadata: SessionMetadata(
                vehicle: "", track: "", driver: "SECOND-LOAD", session: "",
                series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
        let suspendingURL = anyURL
        let secondURL = URL(fileURLWithPath: "/tmp/second.xrk")
        let store = SessionStore(
            loader: RoutingLoader(suspendingURL: suspendingURL, first: first, second: second))
        let firstLoad = Task { await store.load(url: suspendingURL) }
        await waitUntilLoading(store)

        // A second load cancels the suspended first and completes with `second`.
        await store.load(url: secondURL)
        await firstLoad.value

        #expect(store.state == .loaded(SessionViewModel(session: second)))
        #expect(store.viewModel?.metadata.driver == "SECOND-LOAD")
    }
}
