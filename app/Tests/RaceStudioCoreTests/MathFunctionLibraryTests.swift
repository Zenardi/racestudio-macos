import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `MathFunctionLibrary` (issue 8.8): the expression-editor reference of
/// functions / operators / numbers / channels. It must mirror the real M2 grammar
/// (issue 3.5) — the 11 built-in functions, the four arithmetic operators plus
/// grouping, numeric literals (there are **no** named constants), and the
/// session's own channel names.
@Suite struct MathFunctionLibraryTests {

    private func library(channels: [String] = []) -> MathFunctionLibrary {
        MathFunctionLibrary(channelNames: channels)
    }

    // MARK: - Categories

    @Test func test_categories_are_functions_operators_numbers_channels() {
        #expect(MathReferenceCategory.allCases == [.functions, .operators, .numbers, .channels])
    }

    @Test func test_category_titles() {
        #expect(MathReferenceCategory.functions.title == "Functions")
        #expect(MathReferenceCategory.operators.title == "Operators")
        #expect(MathReferenceCategory.numbers.title == "Numbers")
        #expect(MathReferenceCategory.channels.title == "Channels")
    }

    // MARK: - Functions

    @Test func test_functions_are_the_grammar_builtins_in_order() {
        // The 11 built-ins the parser resolves (`Func::from_name`), arity order:
        // 7 unary, 3 binary, 1 ternary.
        #expect(library().entries(for: .functions).map(\.insertion)
            == ["abs(", "sqrt(", "sin(", "cos(", "tan(", "log(", "exp(",
                "min(", "max(", "pow(", "clamp("])
    }

    @Test func test_function_signatures_show_arity() {
        let functions = library().entries(for: .functions)
        #expect(functions.first { $0.insertion == "sqrt(" }?.symbol == "sqrt(x)")
        #expect(functions.first { $0.insertion == "min(" }?.symbol == "min(a, b)")
        #expect(functions.first { $0.insertion == "clamp(" }?.symbol == "clamp(x, lo, hi)")
    }

    // MARK: - Operators

    @Test func test_operators_are_the_four_arithmetic_ops_plus_grouping() {
        // `+ - * /` and grouping `(` — exactly what the lexer/parser accept
        // (unary minus reuses `-`).
        #expect(Set(library().entries(for: .operators).map(\.insertion)) == ["+", "-", "*", "/", "("])
    }

    // MARK: - Numbers (there are no named constants)

    @Test func test_numbers_surface_literal_syntax_not_named_constants() {
        // A bare identifier is a channel reference, so `pi`/`e` are not constants;
        // the reference lists numeric-literal forms instead.
        let numbers = library().entries(for: .numbers)
        #expect(!numbers.isEmpty)
        #expect(numbers.allSatisfy { !$0.symbol.isEmpty && !$0.summary.isEmpty })
    }

    // MARK: - Channels

    @Test func test_channels_come_from_the_session_channel_names() {
        let channels = library(channels: ["Speed", "RPM"]).entries(for: .channels)
        #expect(channels.map(\.symbol) == ["Speed", "RPM"])
        #expect(channels.map(\.insertion) == ["Speed", "RPM"])
    }

    @Test func test_channels_are_empty_without_a_session() {
        #expect(library().entries(for: .channels).isEmpty)
    }

    // MARK: - Identity (used by SwiftUI ForEach)

    @Test func test_entry_id_is_its_symbol() {
        let entry = MathFunctionEntry(symbol: "sqrt(x)", summary: "square root", insertion: "sqrt(")
        #expect(entry.id == "sqrt(x)")
    }

    @Test func test_category_id_is_its_raw_value() {
        #expect(MathReferenceCategory.functions.id == "functions")
        #expect(MathReferenceCategory.channels.id == "channels")
    }
}
