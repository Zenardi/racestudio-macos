import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ExpressionDiagnostic` (issue 4.6) — engine-error → diagnostic
/// mapping and the `at line:col` → character-span parse.
@Suite struct ExpressionDiagnosticTests {

    @Test func test_maps_message_verbatim_and_parses_span() {
        // A positional engine error → message verbatim + a 0-based single-char
        // span at (col − 1). "unexpected token at 1:4" → col 4 → span 3..<4.
        let diagnostic = ExpressionDiagnostic.map(
            engineError: .invalidExpression(message: "invalid math-channel expression: unexpected token at 1:4"))
        #expect(diagnostic.message == "invalid math-channel expression: unexpected token at 1:4")
        #expect(diagnostic.span == 3..<4)
    }

    @Test func test_span_is_zero_based_at_column_one() {
        let diagnostic = ExpressionDiagnostic.map(
            engineError: .invalidExpression(message: "unbalanced parenthesis at 1:1"))
        #expect(diagnostic.span == 0..<1)
    }

    @Test func test_missing_channel_has_message_but_no_span() {
        // A missing-channel error carries no `at line:col`, so there is no span.
        let diagnostic = ExpressionDiagnostic.map(
            engineError: .missingChannel(message: "channel not found: Nonexistent"))
        #expect(diagnostic.message == "channel not found: Nonexistent")
        #expect(diagnostic.span == nil)
    }

    @Test func test_message_with_at_but_no_position_has_no_span() {
        // " at " present but not followed by a line:col pair → no span, not a crash.
        let diagnostic = ExpressionDiagnostic.map(engineError: .other(message: "failed at dusk"))
        #expect(diagnostic.message == "failed at dusk")
        #expect(diagnostic.span == nil)
    }

    @Test func test_engine_error_exposes_message() {
        #expect(ExpressionEngineError.invalidExpression(message: "x").message == "x")
        #expect(ExpressionEngineError.missingChannel(message: "y").message == "y")
        #expect(ExpressionEngineError.other(message: "z").message == "z")
    }
}
