import Testing
import Foundation
import Combine
@testable import RaceStudioCore

/// Tests for the `SessionStore` progress/cancellation additions (issue 2.5):
/// `.loading(DecodeProgress)` threading, `cancel()`, and new-load-cancels-prior.
@Suite struct SessionStoreCancellationTests {

    /// A loader that emits scripted progress, optionally suspends until the task
    /// is cancelled, then returns/throws a preset result — no real Rust decode.
    private final class ScriptedLoader: SessionLoading, @unchecked Sendable {
        var progresses: [Double]
        var result: Result<Session, Error>
        var suspendUntilCancelled: Bool

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

    private func session() throws -> Session { try GoldenSession.load("aim_official_test") }
    private var anyURL: URL { URL(fileURLWithPath: "/tmp/x.xrk") }

    /// Spin until the store reports `.loading` (the scripted loader is suspended).
    @MainActor private func waitUntilLoading(_ store: SessionStore) async {
        while true {
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

    @MainActor @Test func test_new_load_cancels_previous_load() async throws {
        let first = try session()
        let second = try session()
        let loader = ScriptedLoader(result: .success(first), suspendUntilCancelled: true)
        let store = SessionStore(loader: loader)
        let firstLoad = Task { await store.load(url: anyURL) }
        await waitUntilLoading(store)

        // Second load cancels the suspended first and completes.
        loader.suspendUntilCancelled = false
        loader.result = .success(second)
        await store.load(url: URL(fileURLWithPath: "/tmp/second.xrk"))
        await firstLoad.value

        #expect(store.state == .loaded(SessionViewModel(session: second)))
    }
}
