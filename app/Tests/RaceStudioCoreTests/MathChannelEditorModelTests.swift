import Testing
import Foundation
@testable import RaceStudioCore
#if canImport(RaceStudioFFIBindings)
import RaceStudioFFIBindings
#endif

/// Tests for `MathChannelEditorModel` (issue 4.6) — live-validated expression
/// editing with a debounced, last-write-wins validation and a preview trace.
@Suite struct MathChannelEditorModelTests {

    // MARK: - Test doubles

    /// A synchronous evaluator returning a preset success/failure.
    private struct StubEvaluator: ExpressionEvaluating {
        let result: Result<[MathSample], ExpressionEngineError>
        func evaluate(_ expression: String) async throws -> [MathSample] { try result.get() }
    }

    /// Records the expressions it was asked to evaluate (for debounce assertions).
    private actor SpyEvaluator: ExpressionEvaluating {
        private(set) var calls: [String] = []
        let result: [MathSample]
        init(result: [MathSample] = []) { self.result = result }
        func evaluate(_ expression: String) async throws -> [MathSample] {
            calls.append(expression)
            return result
        }
    }

    /// Throws a non-engine error, to exercise the model's defensive fallback.
    private struct BoomError: Error {}
    private struct ThrowingEvaluator: ExpressionEvaluating {
        func evaluate(_ expression: String) async throws -> [MathSample] { throw BoomError() }
    }

    /// Suspends (until cancelled) for `slowExpr`, returns immediately otherwise —
    /// so a test can hold one validation in-flight while a newer one supersedes it.
    private final class GatedEvaluator: ExpressionEvaluating, @unchecked Sendable {
        let slowExpr: String
        let slowResult: [MathSample]
        let fastResult: [MathSample]
        private let lock = NSLock()
        private var startedFlag = false
        var started: Bool { lock.withLock { startedFlag } }

        init(slowExpr: String, slowResult: [MathSample], fastResult: [MathSample]) {
            self.slowExpr = slowExpr
            self.slowResult = slowResult
            self.fastResult = fastResult
        }

        func evaluate(_ expression: String) async throws -> [MathSample] {
            guard expression == slowExpr else { return fastResult }
            lock.withLock { startedFlag = true }
            try await Task.sleep(nanoseconds: 5_000_000_000) // released only by cancellation
            return slowResult
        }
    }

    // MARK: - Valid / idle / error

    @MainActor @Test func test_valid_expression_reports_valid_and_preview() async {
        let samples = [MathSample(time: 0, value: 10), MathSample(time: 1, value: 20)]
        let model = MathChannelEditorModel(
            evaluator: StubEvaluator(result: .success(samples)), debounceInterval: .zero)

        model.update(text: "2 * RPM")
        await model.awaitValidation()

        #expect(model.state == .valid)
        #expect(model.preview?.name == "2 * RPM")
        #expect(model.preview?.samples.map(\.value) == [10, 20])
        #expect(model.preview?.samples.map(\.time) == [0, 1])
    }

    @MainActor @Test func test_empty_expression_is_idle() async {
        let spy = SpyEvaluator()
        let model = MathChannelEditorModel(evaluator: spy, debounceInterval: .zero)

        model.update(text: "   ") // whitespace only
        await model.awaitValidation()

        #expect(model.state == .idle)
        #expect(model.preview == nil)
        #expect(await spy.calls.isEmpty, "an empty expression is not evaluated")
    }

    @MainActor @Test func test_syntax_error_maps_message_and_span() async {
        let message = "invalid math-channel expression: unexpected token at 1:4"
        let model = MathChannelEditorModel(
            evaluator: StubEvaluator(result: .failure(.invalidExpression(message: message))),
            debounceInterval: .zero)

        model.update(text: "2 +")
        await model.awaitValidation()

        guard case let .invalid(diagnostic) = model.state else {
            Issue.record("expected .invalid, got \(model.state)"); return
        }
        #expect(diagnostic.message == message)
        #expect(diagnostic.span == 3..<4)
        #expect(model.preview == nil, "an invalid expression shows no preview")
    }

    @MainActor @Test func test_unknown_channel_surfaces_engine_error_no_preview() async {
        let message = "channel not found: Nonexistent"
        let model = MathChannelEditorModel(
            evaluator: StubEvaluator(result: .failure(.missingChannel(message: message))),
            debounceInterval: .zero)

        model.update(text: "Nonexistent * 2")
        await model.awaitValidation()

        guard case let .invalid(diagnostic) = model.state else {
            Issue.record("expected .invalid, got \(model.state)"); return
        }
        #expect(diagnostic.message == message, "the engine's error is surfaced verbatim")
        #expect(diagnostic.span == nil)
        #expect(model.preview == nil)
    }

    @MainActor @Test func test_arity_error_reported_as_diagnostic() async {
        let message = "invalid math-channel expression: function `sqrt` expects 1 argument(s), got 2 at 1:1"
        let model = MathChannelEditorModel(
            evaluator: StubEvaluator(result: .failure(.invalidExpression(message: message))),
            debounceInterval: .zero)

        model.update(text: "sqrt(RPM, 2)")
        await model.awaitValidation()

        guard case let .invalid(diagnostic) = model.state else {
            Issue.record("expected .invalid, got \(model.state)"); return
        }
        #expect(diagnostic.message == message)
        #expect(diagnostic.span == 0..<1)
        #expect(model.preview == nil)
    }

    @MainActor @Test func test_non_engine_error_becomes_diagnostic_without_span() async {
        // A failure that isn't an ExpressionEngineError still surfaces as an
        // invalid diagnostic (no span, no preview) rather than crashing.
        let model = MathChannelEditorModel(evaluator: ThrowingEvaluator(), debounceInterval: .zero)

        model.update(text: "RPM")
        await model.awaitValidation()

        guard case let .invalid(diagnostic) = model.state else {
            Issue.record("expected .invalid, got \(model.state)"); return
        }
        #expect(!diagnostic.message.isEmpty)
        #expect(diagnostic.span == nil)
        #expect(model.preview == nil)
    }

    // MARK: - Debounce / last-write-wins

    @MainActor @Test func test_debounce_validates_only_latest_text() async {
        let spy = SpyEvaluator()
        let model = MathChannelEditorModel(evaluator: spy, debounceInterval: .milliseconds(30))

        model.update(text: "R")
        model.update(text: "RP")
        model.update(text: "RPM")
        await model.awaitValidation()

        #expect(await spy.calls == ["RPM"], "earlier keystrokes are cancelled before evaluation")
    }

    @MainActor @Test func test_stale_validation_result_discarded() async {
        let evaluator = GatedEvaluator(
            slowExpr: "SLOW",
            slowResult: [MathSample(time: 9, value: 999)],
            fastResult: [MathSample(time: 1, value: 1)])
        let model = MathChannelEditorModel(evaluator: evaluator, debounceInterval: .zero)

        model.update(text: "SLOW")
        while !evaluator.started { await Task.yield() } // the slow validation is in-flight
        model.update(text: "FAST")                       // supersede it
        await model.awaitValidation()

        #expect(model.state == .valid)
        #expect(model.preview?.samples.map(\.value) == [1], "the latest (fast) result wins")
        #expect(model.preview?.samples.map(\.value) != [999], "the stale result is discarded")
    }

    // MARK: - Real engine over the session golden (skips when the fixture is absent)

    #if canImport(RaceStudioFFIBindings)
    private static func xrkOrSkip() -> String? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 2), magic == Data("<h".utf8) else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
            return nil
        }
        try? handle.close()
        return url.path
    }

    @MainActor @Test func test_valid_preview_matches_engine_eval_golden() async throws {
        guard let path = Self.xrkOrSkip() else { return }
        let session = try openSession(path: path)
        let window = FfiWindow(start: 0, end: 5000)
        let model = MathChannelEditorModel(
            evaluator: FFIExpressionEvaluator(session: session, window: window),
            debounceInterval: .zero)

        model.update(text: "2 * RPM + 1")
        await model.awaitValidation()
        #expect(model.state == .valid)

        // The preview equals a direct engine eval over the same window.
        let expected = try session.evalMathChannel(expr: "2 * RPM + 1", window: window)
        let preview = try #require(model.preview)
        try #require(preview.samples.count == expected.count)
        for (got, want) in zip(preview.samples, expected) {
            #expect(abs(got.time - want.timecode) < 1e-9)
            #expect(abs(got.value - want.value) < 1e-9)
        }
    }

    @MainActor @Test func test_ffi_evaluator_maps_engine_errors() async throws {
        guard let path = Self.xrkOrSkip() else { return }
        let session = try openSession(path: path)
        let evaluator = FFIExpressionEvaluator(session: session, window: FfiWindow(start: 0, end: 5000))

        // A syntax error → invalidExpression (its message carries a position).
        do {
            _ = try await evaluator.evaluate("2 +")
            Issue.record("expected a thrown error for a syntax error")
        } catch let error as ExpressionEngineError {
            guard case .invalidExpression = error else {
                Issue.record("expected invalidExpression, got \(error)"); return
            }
        }

        // An unknown channel → missingChannel.
        do {
            _ = try await evaluator.evaluate("Nonexistent * 2")
            Issue.record("expected a thrown error for an unknown channel")
        } catch let error as ExpressionEngineError {
            guard case .missingChannel = error else {
                Issue.record("expected missingChannel, got \(error)"); return
            }
        }

        // Any other analysis failure (here an inverted window) → other.
        let inverted = FFIExpressionEvaluator(session: session, window: FfiWindow(start: 5000, end: 1000))
        do {
            _ = try await inverted.evaluate("RPM")
            Issue.record("expected a thrown error for an inverted window")
        } catch let error as ExpressionEngineError {
            guard case .other = error else {
                Issue.record("expected other, got \(error)"); return
            }
        }
    }
    #endif
}
