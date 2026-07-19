import Foundation
import Combine

/// The load lifecycle `SessionStore` publishes. Views render purely from this
/// state, so it is `Equatable` for straightforward test and view assertions.
public enum LoadState: Equatable, Sendable {
    /// No session requested (also the state after a cancel).
    case idle
    /// A load is in flight, carrying clamped/monotonic decode progress.
    case loading(DecodeProgress)
    /// A session finished decoding.
    case loaded(SessionViewModel)
    /// The load failed with a user-facing error; no partial session is exposed.
    case failed(ImportError)
}

/// The `ObservableObject` the SwiftUI shell observes to drive every M2 screen
/// (issues 2.2 + 2.5).
///
/// It decodes a URL through an injected ``SessionLoading`` and publishes a
/// ``LoadState`` machine — `idle → loading(progress) → loaded / failed` — while
/// threading decode progress, mapping failures to a user-facing ``ImportError``,
/// and supporting cancellation. Starting a new load cancels any in-flight one.
///
/// `@MainActor` so every `@Published` mutation is observed on the main actor.
@MainActor
public final class SessionStore: ObservableObject {

    /// The current load state. Mutated only on the main actor.
    @Published public private(set) var state: LoadState = .idle

    private let loader: SessionLoading
    private var task: Task<Void, Never>?
    /// Monotonic token identifying the current load; stale loads (cancelled or
    /// superseded) are ignored so their late updates never clobber the state.
    private var token = 0

    /// - Parameter loader: the strategy used to decode a session from a URL.
    public init(loader: SessionLoading) {
        self.loader = loader
    }

    /// The loaded view-model, or `nil` in any non-`.loaded` state.
    public var viewModel: SessionViewModel? {
        if case let .loaded(viewModel) = state {
            return viewModel
        }
        return nil
    }

    /// Decode the session at `url`, publishing `.loading(progress)` while it runs
    /// and ending at `.loaded` (success) or `.failed` (any thrown error). Any
    /// in-flight load is cancelled first.
    public func load(url: URL) async {
        let token = beginNewOperation()
        let task = Task { await self.run(url: url, token: token) }
        self.task = task
        await task.value
        // Drop the finished task, but only if a newer load/cancel hasn't already
        // replaced it (whose token would differ).
        if self.token == token { self.task = nil }
    }

    /// Cancel an in-flight load and return to `.idle` without producing a
    /// `.loaded` or `.failed` result. A no-op when nothing is loading, so a
    /// completed `.loaded` session is never discarded.
    public func cancel() {
        guard task != nil else { return }
        _ = beginNewOperation()
        state = .idle
    }

    // MARK: - Internals

    private func beginNewOperation() -> Int {
        task?.cancel()
        task = nil
        token += 1
        return token
    }

    private func run(url: URL, token: Int) async {
        setState(.loading(DecodeProgress()), token: token)
        do {
            let loaded = try await loader.load(url) { progress in
                self.applyProgress(progress, token: token)
            }
            try Task.checkCancellation()
            setState(.loading(DecodeProgress(fraction: 1, phase: .complete)), token: token)
            // Retain the live pump when the loader vends a data source (issue 8.1),
            // so the loaded session can feed the analysis UI.
            let analysis = loaded.dataSource.map {
                AnalysisSession(session: loaded.session, dataSource: $0)
            }
            setState(.loaded(SessionViewModel(session: loaded.session, analysis: analysis,
                                              evaluator: loaded.evaluator)), token: token)
        } catch is CancellationError {
            setState(.idle, token: token)
        } catch {
            let decodeError = (error as? DecodeError) ?? .other(message: "\(error)")
            setState(.failed(ImportError(decodeError: decodeError)), token: token)
        }
    }

    private func applyProgress(_ update: DecodeProgress, token: Int) {
        guard token == self.token, case let .loading(current) = state else { return }
        setState(.loading(current.reduce(update)), token: token)
    }

    /// Apply a state change only if `token` is still the current operation.
    private func setState(_ newState: LoadState, token: Int) {
        guard token == self.token else { return }
        state = newState
    }
}
