#if canImport(RaceStudioFFIBindings)
import Testing
import Foundation
@testable import RaceStudioCore

/// Integration tests for the production ``FFIExpressionValidator`` (issue 5.4):
/// math-channel expressions are parse-validated through the real M2 grammar over
/// UniFFI. Compiled only when `RaceStudioFFI.xcframework` is present.
@Suite struct ProjectFFIValidatorTests {

    @Test func test_ffi_validator_accepts_valid_and_rejects_invalid() throws {
        let validator = FFIExpressionValidator()

        // A syntactically valid expression parses (no session/channels required).
        try validator.validate("sqrt(Ax*Ax + Ay*Ay)")

        // A malformed expression throws — surfaced, never a trap.
        #expect(throws: (any Error).self) { try validator.validate("Ax +* 2") }
    }

    @Test func test_load_flags_invalid_math_via_real_ffi_parser() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rsproj-ffi-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("project.rsproj")

        let document = ProjectDocument(
            layout: AnalysisLayout(panes: [Pane(channelNames: ["Speed"])], xAxisMode: .time),
            mathChannels: [
                MathChannelDef(name: "Good", unit: "g", expression: "Ax*2"),
                MathChannelDef(name: "Bad", unit: "", expression: "Ax +* 2")
            ])
        let store = ProjectStore(validator: FFIExpressionValidator())
        try store.save(document, to: url)

        let loaded = try store.load(from: url)

        #expect(loaded.mathChannels.map(\.name) == ["Good", "Bad"])       // load not aborted
        #expect(loaded.diagnostics == [.invalidMathChannel(name: "Bad")]) // only the invalid one
    }
}
#endif
