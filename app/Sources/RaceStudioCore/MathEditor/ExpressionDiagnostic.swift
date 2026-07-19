import Foundation

/// An inline diagnostic for an invalid math-channel expression (issue 4.6): a
/// human-readable `message` and, when the engine reported a source position, the
/// 0-based half-open character `span` to underline in the editor field.
public struct ExpressionDiagnostic: Equatable, Sendable {
    /// The engine's error message, shown verbatim.
    public let message: String
    /// The character range to underline, or `nil` when the error carries no
    /// position (e.g. a missing channel). This is a raw engine position and may
    /// extend past the current text; render it through ``caret(forTextLength:)``,
    /// which clamps it, rather than indexing a string with it directly.
    public let span: Range<Int>?

    public init(message: String, span: Range<Int>? = nil) {
        self.message = message
        self.span = span
    }

    /// A caret string (e.g. `"   ^"`) placing a `^` under ``span``, clamped to
    /// `textLength` so it never runs past the field (and never traps on a
    /// negative count). `nil` when there is no span.
    public func caret(forTextLength textLength: Int) -> String? {
        guard let span else { return nil }
        let width = max(0, textLength)
        let start = min(max(span.lowerBound, 0), width)
        let length = max(1, min(span.count, max(1, width - start)))
        return String(repeating: " ", count: start) + String(repeating: "^", count: length)
    }
}

/// The editor's live-validation state (issue 4.6): nothing typed yet (`idle`), a
/// valid expression (`valid`, with a preview alongside), or an invalid one
/// (`invalid`, carrying the diagnostic).
public enum EditorState: Equatable, Sendable {
    case idle
    case valid
    case invalid(ExpressionDiagnostic)
}

/// The expression-engine failure surface the editor maps to a diagnostic
/// (issue 4.6). It mirrors the relevant `AnalysisError` cases without depending
/// on the FFI bindings, so the editor model stays testable with a fake engine;
/// `FFIExpressionEvaluator` translates the real `AnalysisError` into it.
public enum ExpressionEngineError: Error, Equatable, Sendable {
    /// The expression failed to lex, parse, or evaluate. The message ends with
    /// the engine's `line:col` position (e.g. `… at 1:4`).
    case invalidExpression(message: String)
    /// The expression referenced a channel not present in the session.
    case missingChannel(message: String)
    /// Any other analysis failure (window / lap / monotonicity).
    case other(message: String)

    /// The engine's human-readable message, surfaced verbatim in the diagnostic.
    public var message: String {
        switch self {
        case let .invalidExpression(message), let .missingChannel(message), let .other(message):
            return message
        }
    }
}

extension ExpressionDiagnostic {
    /// Map any evaluation failure to a diagnostic: an ``ExpressionEngineError`` via
    /// ``map(engineError:)`` (keeping its caret span), any other error by its
    /// description (no span). Shared by the editor and the Math Channels manager so
    /// the evaluate → diagnostic mapping has one definition.
    public static func map(evaluationError error: Error) -> ExpressionDiagnostic {
        if let engineError = error as? ExpressionEngineError { return .map(engineError: engineError) }
        return ExpressionDiagnostic(message: "\(error)")
    }

    /// Maps an engine error to a diagnostic: the message verbatim, plus a
    /// single-character `span` parsed from a trailing `at line:col` position.
    /// Only ``ExpressionEngineError/invalidExpression`` carries a position (the
    /// engine appends it to syntax / lex / arity errors); a missing-channel or
    /// other error never does — so its message is not scanned for a position,
    /// avoiding a false caret when a channel name happens to contain `"… 9:5"`.
    public static func map(engineError: ExpressionEngineError) -> ExpressionDiagnostic {
        let span: Range<Int>?
        switch engineError {
        case let .invalidExpression(message): span = self.span(in: message)
        case .missingChannel, .other: span = nil
        }
        return ExpressionDiagnostic(message: engineError.message, span: span)
    }

    /// Parses the trailing `at line:col` (1-based) of an engine message into a
    /// 0-based single-character span at `col − 1`, or `nil` when it is absent or
    /// unparseable. The editor is single-line, so only the column is used.
    private static func span(in message: String) -> Range<Int>? {
        // The engine appends " at line:col" (1-based) to positional errors; a
        // missing-channel error has none, so there is nothing after the last " at ".
        let components = message.components(separatedBy: " at ")
        guard components.count > 1 else { return nil }
        let parts = components[components.count - 1].split(separator: ":")
        guard parts.count == 2, let column = Int(parts[1]), column >= 1 else { return nil }
        return (column - 1)..<column
    }
}
