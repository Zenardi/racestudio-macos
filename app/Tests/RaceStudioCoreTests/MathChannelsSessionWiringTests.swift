import Testing
import Foundation
@testable import RaceStudioCore

/// Tests that the load path carries an ``ExpressionEvaluating`` from the retained
/// session handle out to the UI (issue 8.8): the Math Channels editor is backed by
/// `FFIExpressionEvaluator(session:)`, so `LoadedSession` and `SessionViewModel`
/// must vend the evaluator. Covered FFI-free with a fake evaluator.
@Suite struct MathChannelsSessionWiringTests {

    private struct FakeEvaluator: ExpressionEvaluating {
        func evaluate(_ expression: String) async throws -> [MathSample] { [] }
    }

    private func session() -> Session {
        Session(
            metadata: SessionMetadata(vehicle: "", track: "", driver: "", session: "",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [], laps: [])
    }

    @Test func test_loaded_session_carries_the_evaluator() {
        let loaded = LoadedSession(session: session(), dataSource: nil, evaluator: FakeEvaluator())
        #expect(loaded.evaluator != nil)
    }

    @Test func test_session_view_model_exposes_the_evaluator() {
        let viewModel = SessionViewModel(session: session(), analysis: nil, evaluator: FakeEvaluator())
        #expect(viewModel.evaluator != nil)
    }

    @Test func test_evaluator_defaults_to_nil() {
        #expect(LoadedSession(session: session()).evaluator == nil)
        #expect(SessionViewModel(session: session()).evaluator == nil)
    }
}
