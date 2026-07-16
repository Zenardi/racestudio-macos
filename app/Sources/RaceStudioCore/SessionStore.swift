import Foundation
import Combine

/// The load lifecycle `SessionStore` publishes. Views render purely from this
/// state, so it is `Equatable` for straightforward test and view assertions.
public enum LoadState: Equatable, Sendable {
    /// No session requested yet.
    case idle
    /// A load is in flight.
    case loading
    /// A session finished decoding.
    case loaded(SessionViewModel)
    /// The load failed; no partial session is exposed.
    case failed(ImportError)
}

/// The `ObservableObject` the SwiftUI shell (2.1) observes to drive every M2
/// screen (issue 2.2).
///
/// It takes a file URL, decodes it through an injected ``SessionLoading``, and
/// publishes a small ``LoadState`` machine — `idle → loading → loaded / failed`
/// — so views are a pure function of state. Loading is injected so unit tests
/// drive it with a golden-backed fake and never invoke the real Rust decode;
/// production uses `FFISessionLoader`.
///
/// `@MainActor` so every `@Published` mutation is observed on the main actor.
/// Progress/cancellation (2.5), open/drag/recents entry points (2.3), and
/// summary formatting (2.4) build on this store but are out of scope here.
@MainActor
public final class SessionStore: ObservableObject {

    /// The current load state. Mutated only on the main actor.
    @Published public private(set) var state: LoadState = .idle

    private let loader: SessionLoading

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

    /// Decode the session at `url`, driving `state` through
    /// `.loading` then `.loaded` (success) or `.failed` (any thrown error).
    ///
    /// On failure the store never partially-populates a view-model — it replaces
    /// whatever came before with `.failed`.
    public func load(url: URL) async {
        state = .loading
        do {
            let session = try await loader.load(url)
            state = .loaded(SessionViewModel(session: session))
        } catch {
            state = .failed(.decodeFailed)
        }
    }
}
