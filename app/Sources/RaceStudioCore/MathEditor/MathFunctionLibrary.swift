import Foundation

/// One reference entry in the math-channel function library (issue 8.8): a display
/// `symbol` (e.g. `sqrt(x)`), a one-line `summary`, and the `insertion` text a tap
/// drops at the caret (e.g. `sqrt(`).
public struct MathFunctionEntry: Equatable, Sendable, Identifiable {
    /// The display form, e.g. `clamp(x, lo, hi)` or `a + b`.
    public let symbol: String
    /// A one-line human description.
    public let summary: String
    /// The text inserted at the caret when the entry is tapped.
    public let insertion: String

    public var id: String { symbol }

    public init(symbol: String, summary: String, insertion: String) {
        self.symbol = symbol
        self.summary = summary
        self.insertion = insertion
    }
}

/// The sections of the function-library reference (issue 8.8).
public enum MathReferenceCategory: String, CaseIterable, Sendable, Identifiable {
    /// The built-in functions.
    case functions
    /// The arithmetic operators and grouping.
    case operators
    /// Numeric-literal syntax (the grammar has no named constants).
    case numbers
    /// The session's own channel names.
    case channels

    public var id: String { rawValue }

    /// The section header.
    public var title: String {
        switch self {
        case .functions: return "Functions"
        case .operators: return "Operators"
        case .numbers: return "Numbers"
        case .channels: return "Channels"
        }
    }
}

/// The expression-editor reference (issue 8.8): the functions, operators, numeric
/// literals, and channel names a user can type into a math-channel expression.
///
/// It mirrors the real M2 grammar (issue 3.5) exactly — the 11 built-in functions
/// resolved by the parser (`Func::from_name`), the four arithmetic operators plus
/// grouping accepted by the lexer, and numeric literals. There are **no** named
/// constants (`pi`/`e`): a bare identifier is a channel reference, so the numbers
/// section surfaces literal syntax rather than inventing constants that would parse
/// as a missing channel. A pure value derived from the session's channel names, so
/// the reference panel view stays a thin binding.
public struct MathFunctionLibrary: Sendable {

    /// The session's channel names, in configuration order (the `.channels` section).
    private let channelNames: [String]

    public init(channelNames: [String] = []) {
        self.channelNames = channelNames
    }

    /// The reference entries for `category`.
    public func entries(for category: MathReferenceCategory) -> [MathFunctionEntry] {
        switch category {
        case .functions: return Self.functions
        case .operators: return Self.operators
        case .numbers: return Self.numbers
        case .channels:
            // Only channels whose names are grammar identifiers can be referenced —
            // the grammar has no quoting, so a spaced/punctuated name (e.g.
            // "GPS Speed") is not a usable expression token and is omitted.
            return channelNames.filter(Self.isReferenceableIdentifier).map {
                MathFunctionEntry(symbol: $0, summary: "channel reference", insertion: $0)
            }
        }
    }

    /// Whether `name` is a grammar identifier — `[A-Za-z_][A-Za-z0-9_]*` (ASCII),
    /// matching the M2 lexer (issue 3.5) — and so referenceable in an expression.
    static func isReferenceableIdentifier(_ name: String) -> Bool {
        guard let first = name.first, first == "_" || (first.isASCII && first.isLetter) else { return false }
        return name.dropFirst().allSatisfy { $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }
    }

    // MARK: - Static grammar reference

    /// The 11 built-ins the parser resolves, in arity order (7 unary, 3 binary, 1
    /// ternary). Tapping inserts the name + `(` ready for arguments.
    private static let functions: [MathFunctionEntry] = [
        MathFunctionEntry(symbol: "abs(x)", summary: "absolute value", insertion: "abs("),
        MathFunctionEntry(symbol: "sqrt(x)", summary: "square root", insertion: "sqrt("),
        MathFunctionEntry(symbol: "sin(x)", summary: "sine (radians)", insertion: "sin("),
        MathFunctionEntry(symbol: "cos(x)", summary: "cosine (radians)", insertion: "cos("),
        MathFunctionEntry(symbol: "tan(x)", summary: "tangent (radians)", insertion: "tan("),
        MathFunctionEntry(symbol: "log(x)", summary: "natural logarithm", insertion: "log("),
        MathFunctionEntry(symbol: "exp(x)", summary: "e raised to x", insertion: "exp("),
        MathFunctionEntry(symbol: "min(a, b)", summary: "smaller of two values", insertion: "min("),
        MathFunctionEntry(symbol: "max(a, b)", summary: "larger of two values", insertion: "max("),
        MathFunctionEntry(symbol: "pow(a, b)", summary: "a raised to b", insertion: "pow("),
        MathFunctionEntry(symbol: "clamp(x, lo, hi)", summary: "constrain x to [lo, hi]", insertion: "clamp(")
    ]

    /// The four arithmetic operators plus grouping (unary minus reuses `-`).
    private static let operators: [MathFunctionEntry] = [
        MathFunctionEntry(symbol: "a + b", summary: "addition", insertion: "+"),
        MathFunctionEntry(symbol: "a - b", summary: "subtraction (or negation: -x)", insertion: "-"),
        MathFunctionEntry(symbol: "a * b", summary: "multiplication", insertion: "*"),
        MathFunctionEntry(symbol: "a / b", summary: "division", insertion: "/"),
        MathFunctionEntry(symbol: "( )", summary: "grouping", insertion: "(")
    ]

    /// Numeric-literal syntax — the grammar's only "constants".
    private static let numbers: [MathFunctionEntry] = [
        MathFunctionEntry(symbol: "9.81", summary: "decimal literal", insertion: "9.81"),
        MathFunctionEntry(symbol: "1e-3", summary: "scientific notation", insertion: "1e-3")
    ]
}
