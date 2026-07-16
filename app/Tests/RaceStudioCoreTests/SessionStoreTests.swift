import Testing
import Foundation
import Combine
@testable import RaceStudioCore

/// Tests for `SessionStore` (issue 2.2) — the `@MainActor ObservableObject` that
/// drives every M2 screen via a `LoadState` machine
/// (`idle → loading → loaded / failed`).
///
/// Loading is injected through `SessionLoading`, so these tests use a
/// golden-backed fake and **never invoke the real Rust decode** — that path is
/// covered by `FFISessionLoaderTests`. State assertions rely on `LoadState`
/// being `Equatable`.
@Suite struct SessionStoreTests {

    private static let fixtureName = "aim_official_test"

    /// A loader that returns a preset result — no I/O, no Rust. Mutable so the
    /// reload test can change the outcome between calls.
    private final class FakeSessionLoader: SessionLoading, @unchecked Sendable {
        var result: Result<Session, Error>
        init(_ result: Result<Session, Error>) { self.result = result }
        func load(
            _ url: URL,
            onProgress: @escaping @MainActor (DecodeProgress) -> Void
        ) async throws -> Session {
            try result.get()
        }
    }

    private struct LoaderError: Error {}

    private func goldenSession() throws -> Session { try GoldenSession.load(Self.fixtureName) }
    private var anyURL: URL { URL(fileURLWithPath: "/tmp/ignored-by-fake.xrk") }

    // MARK: - Initial state

    @MainActor @Test func test_initial_state_is_idle() {
        let store = SessionStore(loader: FakeSessionLoader(.failure(LoaderError())))

        #expect(store.state == .idle)
    }

    // MARK: - Success path

    @MainActor @Test func test_load_transitions_idle_loading_loaded() async throws {
        let session = try goldenSession()
        let store = SessionStore(loader: FakeSessionLoader(.success(session)))
        var observed: [LoadState] = []
        let subscription = store.$state.sink { observed.append($0) }

        await store.load(url: anyURL)
        subscription.cancel()

        #expect(observed.first == .idle)
        #expect(observed.last == .loaded(SessionViewModel(session: session)))
        let sawLoading = observed.contains { if case .loading = $0 { return true } else { return false } }
        #expect(sawLoading)
    }

    @MainActor @Test func test_loaded_channel_count_matches_golden() async throws {
        let store = SessionStore(loader: FakeSessionLoader(.success(try goldenSession())))

        await store.load(url: anyURL)

        let viewModel = try #require(store.viewModel)
        #expect(viewModel.channels.count == (try GoldenSession.channelCount(Self.fixtureName)))
    }

    @MainActor @Test func test_loaded_lap_count_matches_golden() async throws {
        let store = SessionStore(loader: FakeSessionLoader(.success(try goldenSession())))

        await store.load(url: anyURL)

        let viewModel = try #require(store.viewModel)
        #expect(viewModel.laps.count == (try GoldenSession.lapCount(Self.fixtureName)))
    }

    @MainActor @Test func test_loaded_view_model_exposes_metadata() async throws {
        let session = try goldenSession()
        let store = SessionStore(loader: FakeSessionLoader(.success(session)))

        await store.load(url: anyURL)

        let viewModel = try #require(store.viewModel)
        #expect(viewModel.metadata == session.metadata)
    }

    @MainActor @Test func test_object_will_change_fires_per_transition() async throws {
        let store = SessionStore(loader: FakeSessionLoader(.success(try goldenSession())))
        var changeCount = 0
        let subscription = store.objectWillChange.sink { _ in changeCount += 1 }

        await store.load(url: anyURL)
        subscription.cancel()

        // idle → loading(0) → loading(1.0, complete) → loaded.
        #expect(changeCount == 3)
    }

    // MARK: - Failure path

    @MainActor @Test func test_load_failure_sets_failed_state() async {
        let store = SessionStore(loader: FakeSessionLoader(.failure(LoaderError())))

        await store.load(url: anyURL)

        guard case let .failed(error) = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
        #expect(!error.message.isEmpty)
    }

    @MainActor @Test func test_failure_does_not_populate_view_model() async {
        let store = SessionStore(loader: FakeSessionLoader(.failure(LoaderError())))

        await store.load(url: anyURL)

        #expect(store.viewModel == nil)
    }

    // MARK: - Reload

    @MainActor @Test func test_reload_replaces_previous_state() async throws {
        let loader = FakeSessionLoader(.success(try goldenSession()))
        let store = SessionStore(loader: loader)
        await store.load(url: anyURL)
        #expect(store.viewModel != nil)

        loader.result = .failure(LoaderError())
        await store.load(url: anyURL)

        guard case .failed = store.state else {
            Issue.record("expected .failed, got \(store.state)")
            return
        }
        #expect(store.viewModel == nil)
    }
}
