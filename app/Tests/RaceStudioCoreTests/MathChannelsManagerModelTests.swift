import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `MathChannelsManagerModel` (issue 8.8): the Math Channels manager
/// that validates an expression on add (rejecting an invalid one with the
/// parser's message — no crash), lists / removes defined channels, captures each
/// added channel's evaluated trace so it is usable as a channel, and fires a
/// persist hook with the definitions for the `.rsproj`. Driven FFI-free by a
/// fake ``ExpressionEvaluating``.
@MainActor
@Suite struct MathChannelsManagerModelTests {

    // MARK: - Test double

    /// A deterministic evaluator: throws the mapped engine error for any
    /// expression in `failures`, else returns `samples`.
    private struct KeyedEvaluator: ExpressionEvaluating {
        var failures: [String: ExpressionEngineError] = [:]
        var samples: [MathSample] = [MathSample(time: 0, value: 10), MathSample(time: 1, value: 20)]

        func evaluate(_ expression: String) async throws -> [MathSample] {
            if let error = failures[expression] { throw error }
            return samples
        }
    }

    /// Throws a plain, non-engine error — to exercise the manager's defensive
    /// fallback (a rejection with no crash).
    private struct BoomError: Error {}
    private struct BoomEvaluator: ExpressionEvaluating {
        func evaluate(_ expression: String) async throws -> [MathSample] { throw BoomError() }
    }

    private func makeManager(
        failures: [String: ExpressionEngineError] = [:],
        samples: [MathSample] = [MathSample(time: 0, value: 10), MathSample(time: 1, value: 20)],
        onChange: @escaping ([MathChannelDef]) -> Void = { _ in }
    ) -> MathChannelsManagerModel {
        MathChannelsManagerModel(
            evaluator: KeyedEvaluator(failures: failures, samples: samples),
            debounceInterval: .zero, onChange: onChange)
    }

    // MARK: - Empty

    @Test func test_starts_empty() {
        let manager = makeManager()
        #expect(manager.channels.isEmpty)
        #expect(manager.definitions.isEmpty)
        #expect(manager.rejection == nil)
    }

    // MARK: - Add (valid)

    @Test func test_add_valid_expression_appends_channel_with_evaluated_trace() async {
        let manager = makeManager(samples: [MathSample(time: 0, value: 3), MathSample(time: 2, value: 7)])

        let added = await manager.add(name: "Power", unit: "kW", expression: "2 * RPM")

        #expect(added)
        #expect(manager.definitions == [MathChannelDef(name: "Power", unit: "kW", expression: "2 * RPM")])
        // The added channel carries the trace it evaluated to — so it is a channel,
        // not just a stored string (a math channel is time-keyed: distance mirrors time).
        let defined = manager.channels.first
        #expect(defined?.trace.name == "Power")
        #expect(defined?.trace.samples.map(\.time) == [0, 2])
        #expect(defined?.trace.samples.map(\.distance) == [0, 2])
        #expect(defined?.trace.samples.map(\.value) == [3, 7])
        #expect(manager.rejection == nil)
    }

    @Test func test_add_fires_persist_hook_with_the_updated_definitions() async {
        var captured: [[MathChannelDef]] = []
        let manager = makeManager(onChange: { captured.append($0) })

        _ = await manager.add(name: "A", unit: "", expression: "Ax")
        _ = await manager.add(name: "B", unit: "", expression: "Ay")

        #expect(captured.count == 2, "the hook fires once per successful add")
        #expect(captured.last?.map(\.name) == ["A", "B"])
    }

    @Test func test_name_is_trimmed_before_storing() async {
        let manager = makeManager()
        _ = await manager.add(name: "  Power  ", unit: "kW", expression: "x")
        #expect(manager.definitions.first?.name == "Power")
    }

    // MARK: - Add (rejected)

    @Test func test_add_invalid_expression_is_rejected_with_the_parser_message() async {
        let message = "invalid math-channel expression: unexpected token at 1:3"
        var fired = false
        let manager = makeManager(
            failures: ["2 +": .invalidExpression(message: message)], onChange: { _ in fired = true })

        let added = await manager.add(name: "Bad", unit: "", expression: "2 +")

        #expect(!added)
        #expect(manager.channels.isEmpty, "an invalid expression is not added")
        #expect(!fired, "a rejected add does not persist")
        #expect(manager.rejection?.message == message, "the parser's message is surfaced verbatim")
        #expect(manager.rejection?.span == 2..<3, "the parser position drives the caret")
    }

    @Test func test_add_unknown_channel_surfaces_engine_message_without_a_span() async {
        let message = "channel not found: Nope"
        let manager = makeManager(failures: ["Nope * 2": .missingChannel(message: message)])

        let added = await manager.add(name: "X", unit: "", expression: "Nope * 2")

        #expect(!added)
        #expect(manager.rejection?.message == message)
        #expect(manager.rejection?.span == nil, "a missing-channel error carries no caret")
    }

    @Test func test_add_empty_name_is_rejected_without_evaluating() async {
        let manager = makeManager()
        let added = await manager.add(name: "   ", unit: "", expression: "RPM")
        #expect(!added)
        #expect(manager.channels.isEmpty)
        #expect(manager.rejection != nil)
    }

    @Test func test_add_duplicate_name_is_rejected_and_keeps_the_original() async {
        let manager = makeManager()
        _ = await manager.add(name: "Speed2", unit: "", expression: "Speed * 2")

        let added = await manager.add(name: "Speed2", unit: "", expression: "Speed * 3")

        #expect(!added)
        #expect(manager.definitions.map(\.expression) == ["Speed * 2"], "the first definition is kept")
        #expect(manager.rejection != nil)
    }

    @Test func test_rejection_is_cleared_by_the_next_successful_add() async {
        let manager = makeManager(failures: ["bad": .invalidExpression(message: "boom at 1:1")])
        _ = await manager.add(name: "A", unit: "", expression: "bad")
        #expect(manager.rejection != nil)

        _ = await manager.add(name: "A", unit: "", expression: "ok")

        #expect(manager.rejection == nil, "a successful add clears the prior rejection")
        #expect(manager.definitions.map(\.name) == ["A"])
    }

    // MARK: - Remove

    @Test func test_remove_channel_drops_it_and_persists() async {
        var captured: [[MathChannelDef]] = []
        let manager = makeManager(onChange: { captured.append($0) })
        _ = await manager.add(name: "A", unit: "", expression: "Ax")
        _ = await manager.add(name: "B", unit: "", expression: "Ay")

        manager.remove(manager.channels[0]) // remove "A"

        #expect(manager.definitions.map(\.name) == ["B"])
        #expect(captured.last?.map(\.name) == ["B"], "remove fires the persist hook too")
    }

    @Test func test_remove_at_offsets_drops_the_rows_and_persists() async {
        var captured: [[MathChannelDef]] = []
        let manager = makeManager(onChange: { captured.append($0) })
        _ = await manager.add(name: "A", unit: "", expression: "Ax")
        _ = await manager.add(name: "B", unit: "", expression: "Ay")
        _ = await manager.add(name: "C", unit: "", expression: "Az")

        manager.remove(atOffsets: IndexSet(integer: 1)) // remove "B"

        #expect(manager.definitions.map(\.name) == ["A", "C"])
        #expect(captured.last?.map(\.name) == ["A", "C"])
    }

    @Test func test_add_swallows_a_non_engine_error_as_a_rejection() async {
        // An evaluator failure that isn't an ExpressionEngineError still rejects
        // (with a message, no span) rather than crashing.
        let manager = MathChannelsManagerModel(evaluator: BoomEvaluator(), debounceInterval: .zero)

        let added = await manager.add(name: "X", unit: "", expression: "RPM")

        #expect(!added)
        #expect(manager.channels.isEmpty)
        #expect(manager.rejection != nil)
        #expect(manager.rejection?.span == nil)
    }

    // MARK: - Live draft editor

    @Test func test_editor_is_backed_by_the_injected_evaluator() async {
        let manager = makeManager(failures: ["oops": .invalidExpression(message: "nope at 1:1")])

        manager.editor.update(text: "oops")
        await manager.editor.awaitValidation()

        guard case .invalid = manager.editor.state else {
            Issue.record("expected the draft editor to validate through the shared evaluator")
            return
        }
    }

    // MARK: - Persist + reload through the 5.4 project path

    @Test func test_definitions_persist_and_reload_and_revalidate_through_the_project_store() async throws {
        let manager = makeManager()
        _ = await manager.add(name: "AccelMag", unit: "g", expression: "sqrt(Ax*Ax + Ay*Ay)")
        _ = await manager.add(name: "Doubled", unit: "", expression: "RPM * 2")

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")

        // The manager's definitions become the project's math channels; reloading
        // through the 5.4 store re-parses each expression.
        let document = ProjectDocument(
            layout: AnalysisLayout(panes: [], xAxisMode: .time), mathChannels: manager.definitions)
        let validator = FakeExpressionValidator()
        let store = ProjectStore(validator: validator)
        try store.save(document, to: url)
        let loaded = try store.load(from: url)

        #expect(loaded.mathChannels == manager.definitions, "the definitions round-trip verbatim")
        #expect(validator.validated.sorted() == manager.definitions.map(\.expression).sorted(),
                "every stored expression was re-validated on reload (the 5.4 path)")
    }
}
