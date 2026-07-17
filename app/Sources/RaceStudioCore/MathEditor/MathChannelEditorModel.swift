import Foundation
import Combine

/// One evaluated math-channel sample: a `value` at an elapsed `time` (seconds).
/// The engine keys results by timecode, so the editor preview is time-based
/// (issue 4.6).
public struct MathSample: Equatable, Sendable {
    public let time: Double
    public let value: Double

    public init(time: Double, value: Double) {
        self.time = time
        self.value = value
    }
}

/// Evaluates a math-channel expression over the current session (issue 4.6).
///
/// Abstracted so the editor model is driven by a fake in tests and by the
/// FFI-backed ``FFIExpressionEvaluator`` in production. Returns the preview
/// samples, or throws an ``ExpressionEngineError`` when the expression cannot be
/// parsed or evaluated.
public protocol ExpressionEvaluating: Sendable {
    func evaluate(_ expression: String) async throws -> [MathSample]
}

/// The live-validated math-channel editor (issue 4.6): holds the expression
/// text, validates it (debounced, last-write-wins) through an injected
/// ``ExpressionEvaluating``, and publishes an ``EditorState`` plus a preview
/// ``ChannelTrace`` for the 4.1 plot.
///
/// `@MainActor` so every published mutation lands on the main actor. The package
/// targets macOS 13, where the `@Observable` macro is unavailable, so this uses
/// `ObservableObject` like the other view-models; the validation lifecycle mirrors
/// ``SessionStore`` — a monotonic token discards any superseded validation.
@MainActor
public final class MathChannelEditorModel: ObservableObject {

    /// The current validation state; mutated only on the main actor.
    @Published public private(set) var state: EditorState = .idle
    /// The preview trace for a valid expression, or `nil` otherwise.
    @Published public private(set) var preview: ChannelTrace?
    /// The latest expression text handed to ``update(text:)``.
    @Published public private(set) var text: String = ""

    /// How long to wait after the latest keystroke before validating.
    public let debounceInterval: Duration

    private let evaluator: ExpressionEvaluating
    private var task: Task<Void, Never>?
    /// Monotonic token identifying the current validation; a stale one (cancelled
    /// or superseded by a newer keystroke) never publishes its result.
    private var token = 0

    /// - Parameters:
    ///   - evaluator: the strategy used to evaluate an expression.
    ///   - debounceInterval: the quiet period after the latest keystroke before
    ///     validating (default 300 ms).
    public init(evaluator: ExpressionEvaluating, debounceInterval: Duration = .milliseconds(300)) {
        self.evaluator = evaluator
        self.debounceInterval = debounceInterval
    }

    /// Set the expression to `text` and (debounced) re-validate. Cancels any
    /// pending validation so only the latest text is ever evaluated.
    public func update(text: String) {
        self.text = text
        let token = beginNewValidation()
        task = Task { await self.validate(text: text, token: token) }
    }

    // MARK: - Internals

    private func beginNewValidation() -> Int {
        task?.cancel()
        task = nil
        token += 1
        return token
    }

    private func validate(text: String, token: Int) async {
        // Debounce; bail if a newer keystroke superseded us while we waited.
        try? await Task.sleep(for: debounceInterval)
        guard !Task.isCancelled, token == self.token else { return }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            apply(.idle, preview: nil, token: token)
            return
        }

        do {
            let samples = try await evaluator.evaluate(text)
            guard token == self.token else { return } // superseded during eval → discard
            apply(.valid, preview: makePreview(name: text, samples: samples), token: token)
        } catch is CancellationError {
            return
        } catch let error as ExpressionEngineError {
            guard token == self.token else { return }
            apply(.invalid(.map(engineError: error)), preview: nil, token: token)
        } catch {
            guard token == self.token else { return }
            apply(.invalid(ExpressionDiagnostic(message: "\(error)")), preview: nil, token: token)
        }
    }

    /// Apply a result only while `token` is still the current validation.
    private func apply(_ newState: EditorState, preview newPreview: ChannelTrace?, token: Int) {
        guard token == self.token else { return }
        state = newState
        preview = newPreview
    }

    /// Builds the preview trace from the evaluated samples. A math channel is
    /// time-keyed, so distance mirrors time and the editor renders it in time mode.
    private func makePreview(name: String, samples: [MathSample]) -> ChannelTrace {
        let times = samples.map(\.time)
        return ChannelTrace(name: name, times: times, distances: times, values: samples.map(\.value))
    }

    /// Awaits the in-flight validation. Test hook: production drives validation
    /// through the SwiftUI text-field binding, not by awaiting.
    func awaitValidation() async {
        await task?.value
    }
}
