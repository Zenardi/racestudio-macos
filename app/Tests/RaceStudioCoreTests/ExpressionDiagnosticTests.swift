import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ExpressionDiagnostic` (issue 4.6) — engine-error → diagnostic
/// mapping, the `at line:col` → character-span parse, and caret rendering.
@Suite struct ExpressionDiagnosticTests {

    // MARK: - map(engineError:) + span parse

    @Test func test_maps_message_verbatim_and_parses_span() {
        // A positional (invalid-expression) error → message verbatim + a 0-based
        // single-char span at (col − 1). "unexpected token at 1:4" → span 3..<4.
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

    @Test func test_invalid_expression_without_position_has_no_span() {
        // An invalid-expression message with no `at line:col` → no span, no crash.
        #expect(ExpressionDiagnostic.map(
            engineError: .invalidExpression(message: "totally malformed")).span == nil)
        // ` at ` present but not followed by a line:col pair → still no span.
        #expect(ExpressionDiagnostic.map(
            engineError: .invalidExpression(message: "failed at dusk")).span == nil)
        // A zero column is rejected (positions are 1-based).
        #expect(ExpressionDiagnostic.map(
            engineError: .invalidExpression(message: "boom at 1:0")).span == nil)
    }

    @Test func test_missing_channel_has_message_but_no_span() {
        let diagnostic = ExpressionDiagnostic.map(
            engineError: .missingChannel(message: "channel not found: Nonexistent"))
        #expect(diagnostic.message == "channel not found: Nonexistent")
        #expect(diagnostic.span == nil)
    }

    @Test func test_non_invalid_expression_message_is_never_scanned_for_a_span() {
        // A channel name (or other-error text) that happens to contain a
        // position-like `… at N:M` must NOT produce a bogus caret — only an
        // invalid-expression error carries a real engine position.
        #expect(ExpressionDiagnostic.map(
            engineError: .missingChannel(message: "channel not found: Oil at 9:5")).span == nil)
        #expect(ExpressionDiagnostic.map(
            engineError: .other(message: "aborted at 3:7")).span == nil)
    }

    @Test func test_engine_error_exposes_message() {
        #expect(ExpressionEngineError.invalidExpression(message: "x").message == "x")
        #expect(ExpressionEngineError.missingChannel(message: "y").message == "y")
        #expect(ExpressionEngineError.other(message: "z").message == "z")
    }

    // MARK: - caret(forTextLength:)

    @Test func test_caret_aligns_under_span() {
        let diagnostic = ExpressionDiagnostic(message: "x", span: 3..<4)
        #expect(diagnostic.caret(forTextLength: 10) == "   ^")
    }

    @Test func test_caret_clamps_span_past_text_end() {
        // "2 +" (length 3) → caret at col 4 (span 3..<4) is one past the end;
        // it clamps to a single caret at the end rather than overrunning.
        let diagnostic = ExpressionDiagnostic(message: "x", span: 3..<4)
        #expect(diagnostic.caret(forTextLength: 3) == "   ^")
    }

    @Test func test_caret_is_nil_without_span() {
        #expect(ExpressionDiagnostic(message: "x", span: nil).caret(forTextLength: 5) == nil)
    }

    @Test func test_caret_does_not_trap_on_nonsensical_length() {
        // A negative length must not trap String(repeating:count:).
        #expect(ExpressionDiagnostic(message: "x", span: 0..<1).caret(forTextLength: -5) == "^")
    }
}
