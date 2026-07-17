#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Production evaluator: runs the expression through the 3.5 engine over a live
/// `SessionHandle` via the 3.8 UniFFI boundary (issue 4.6), mapping the FFI's
/// `AnalysisError` into Core's ``ExpressionEngineError`` and each `Sample` into a
/// ``MathSample``.
///
/// Available only when `RaceStudioFFI.xcframework` has been built; a fresh
/// checkout without it compiles without this type. `@unchecked Sendable` because
/// the opaque `SessionHandle` is immutable here and the Rust analysis calls are
/// thread-safe.
public struct FFIExpressionEvaluator: ExpressionEvaluating, @unchecked Sendable {
    private let session: SessionHandle
    private let window: FfiWindow

    /// - Parameters:
    ///   - session: the decoded session to evaluate the expression against.
    ///   - window: the timecode window (ms) to preview over; defaults to the
    ///     whole session.
    public init(session: SessionHandle,
                window: FfiWindow = FfiWindow(start: -.infinity, end: .infinity)) {
        self.session = session
        self.window = window
    }

    public func evaluate(_ expression: String) async throws -> [MathSample] {
        do {
            return try session.evalMathChannel(expr: expression, window: window)
                .map { MathSample(time: $0.timecode, value: $0.value) }
        } catch let error as AnalysisError {
            throw ExpressionEngineError(error)
        }
    }
}

extension ExpressionEngineError {
    /// Translate the FFI's `AnalysisError` into the editor's error surface.
    init(_ analysisError: AnalysisError) {
        switch analysisError {
        case let .InvalidExpression(message):
            self = .invalidExpression(message: message)
        case let .MissingChannel(message):
            self = .missingChannel(message: message)
        case let .EmptyLap(message),
             let .DistanceNotMonotonic(message),
             let .EmptyRange(message),
             let .LapOutOfRange(message),
             let .WindowOutOfBounds(message):
            self = .other(message: message)
        }
    }
}
#endif
