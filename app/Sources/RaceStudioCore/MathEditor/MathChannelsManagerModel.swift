import Foundation
import Combine

/// A defined math channel plus the trace it evaluated to over the live session
/// (issue 8.8). The trace is captured on add, so a panel can plot the channel —
/// "usable as a channel" — without re-evaluating; the ``definition`` is what
/// persists into the `.rsproj` (5.4).
public struct DefinedMathChannel: Equatable, Sendable, Identifiable {
    /// The persisted definition (name, unit, expression source).
    public let definition: MathChannelDef
    /// The channel evaluated over the current session (time-keyed, like the editor
    /// preview): the plottable trace.
    public let trace: ChannelTrace

    /// The channel name — unique within a manager, so it is a stable list identity.
    public var id: String { definition.name }

    public init(definition: MathChannelDef, trace: ChannelTrace) {
        self.definition = definition
        self.trace = trace
    }
}

/// The Math Channels manager (issue 8.8): authors, lists, and removes user-defined
/// math channels over a loaded session.
///
/// It owns a live ``MathChannelEditorModel`` (4.6) for the draft expression — so the
/// view embeds the existing editor with its debounced validation, caret diagnostic,
/// and preview — and an ``add(name:unit:expression:)`` that validates the expression
/// through the same injected ``ExpressionEvaluating`` before committing it. An
/// invalid expression is **rejected** with the parser's message (surfaced as a
/// ``rejection``) and never added — no crash. Every list change fires the
/// ``onChange`` persist hook with the ``definitions``, which the workspace writes
/// into the project document's `mathChannels` (the 5.4 path).
///
/// `@MainActor` (owns the main-actor editor and publishes to the UI); the package
/// targets macOS 13, where `@Observable` is unavailable, so it is an
/// `ObservableObject` like the other view-models. Covered FFI-free through a fake
/// evaluator; production injects the FFI-backed ``FFIExpressionEvaluator`` built
/// from the retained session handle (8.1).
@MainActor
public final class MathChannelsManagerModel: ObservableObject {

    /// The defined math channels, in the order they were added.
    @Published public private(set) var channels: [DefinedMathChannel]

    /// The last add rejection (the parser's message + optional caret span), or
    /// `nil` after a successful add. Drives the inline "couldn't add" diagnostic.
    @Published public private(set) var rejection: ExpressionDiagnostic?

    /// The live draft editor (4.6) the view embeds: debounced validation, caret
    /// diagnostic, and preview, all backed by the same evaluator as ``add``.
    public let editor: MathChannelEditorModel

    private let evaluator: ExpressionEvaluating
    /// Fired with the current ``definitions`` after every list change, so the
    /// workspace can persist them into the project document (5.4).
    private let onChange: ([MathChannelDef]) -> Void

    /// - Parameters:
    ///   - evaluator: the strategy that validates an expression (and evaluates the
    ///     preview) against the current session.
    ///   - channels: any already-defined channels (e.g. restored from a project).
    ///   - debounceInterval: the draft editor's quiet period (default 300 ms).
    ///   - onChange: the persist hook, called with the definitions after each change.
    public init(evaluator: ExpressionEvaluating,
                channels: [DefinedMathChannel] = [],
                debounceInterval: Duration = .milliseconds(300),
                onChange: @escaping ([MathChannelDef]) -> Void = { _ in }) {
        self.evaluator = evaluator
        self.channels = channels
        self.editor = MathChannelEditorModel(evaluator: evaluator, debounceInterval: debounceInterval)
        self.onChange = onChange
    }

    /// The persisted definitions in list order — the payload for
    /// ``ProjectDocument/mathChannels``.
    public var definitions: [MathChannelDef] { channels.map(\.definition) }

    /// Validate `expression` and, if it is valid, named, and not a duplicate, add it
    /// as a defined channel (capturing its evaluated trace) and fire the persist
    /// hook. Returns whether it was added; on failure sets ``rejection`` and adds
    /// nothing.
    @discardableResult
    public func add(name: String, unit: String, expression: String) async -> Bool {
        rejection = nil
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            rejection = ExpressionDiagnostic(message: "Name the math channel before adding it.")
            return false
        }
        guard !channels.contains(where: { $0.definition.name == trimmedName }) else {
            rejection = ExpressionDiagnostic(message: "A math channel named “\(trimmedName)” already exists.")
            return false
        }

        let samples: [MathSample]
        do {
            samples = try await evaluator.evaluate(expression)
        } catch let error as ExpressionEngineError {
            rejection = .map(engineError: error)
            return false
        } catch {
            rejection = ExpressionDiagnostic(message: "\(error)")
            return false
        }

        let definition = MathChannelDef(name: trimmedName, unit: unit, expression: expression)
        // A math channel is time-keyed, so distance mirrors time (as the editor
        // preview does); the trace makes it plottable as a channel.
        let times = samples.map(\.time)
        let trace = ChannelTrace(name: trimmedName, times: times, distances: times,
                                 values: samples.map(\.value))
        channels.append(DefinedMathChannel(definition: definition, trace: trace))
        onChange(definitions)
        return true
    }

    /// Remove `channel` and fire the persist hook.
    public func remove(_ channel: DefinedMathChannel) {
        channels.removeAll { $0.id == channel.id }
        onChange(definitions)
    }

    /// Remove the channels at `offsets` (the `onDelete` swipe) and fire the persist
    /// hook. Descending order so each removal leaves the lower indices valid.
    public func remove(atOffsets offsets: IndexSet) {
        for index in offsets.sorted(by: >) {
            channels.remove(at: index)
        }
        onChange(definitions)
    }
}
