import Foundation

/// Parse-validates a math-channel expression against the M2 grammar (issue 5.4).
///
/// A seam so `RaceStudioCore` load/validate logic is testable without the FFI:
/// production supplies ``FFIExpressionValidator`` (the Rust `expr` parser over
/// UniFFI, parse-only — no evaluation, no session); tests supply a fake.
public protocol ExpressionValidating {
    /// Parse `expression`; throw if it is syntactically invalid.
    func validate(_ expression: String) throws
}

/// A user-defined math channel persisted in a project (issue 5.4): a display
/// name and unit plus the expression **source text**. The expression is stored
/// verbatim and re-validated by parsing on load — never evaluated here (that is
/// M2's job, and needs a session).
public struct MathChannelDef: Codable, Equatable, Sendable {
    /// Channel display name.
    public var name: String
    /// Physical unit (may be empty).
    public var unit: String
    /// The expression source, e.g. `sqrt(Ax*Ax + Ay*Ay)`.
    public var expression: String

    public init(name: String, unit: String, expression: String) {
        self.name = name
        self.unit = unit
        self.expression = expression
    }

    /// Parse-validate ``expression`` via `validator`, rethrowing the parser's
    /// error verbatim. The loader (``ProjectStore``) catches it and attributes it
    /// to this channel as ``ProjectError/invalidMathChannel(name:)`` without
    /// aborting the rest of the load.
    public func validate(using validator: ExpressionValidating) throws {
        try validator.validate(expression)
    }
}
