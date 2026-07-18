#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Production expression validator (issue 5.4): parse-validates a math-channel
/// expression through the M2 grammar over the UniFFI boundary
/// (`validate_math_expression`), **without** evaluating it or needing a session.
///
/// A malformed expression is thrown as the FFI's `AnalysisError` (mapped by the
/// caller to ``ProjectError/invalidMathChannel(name:)``). Available only when
/// `RaceStudioFFI.xcframework` has been built; a fresh checkout without it
/// compiles without this type.
public struct FFIExpressionValidator: ExpressionValidating, Sendable {

    public init() {}

    public func validate(_ expression: String) throws {
        try validateMathExpression(expr: expression)
    }
}
#endif
