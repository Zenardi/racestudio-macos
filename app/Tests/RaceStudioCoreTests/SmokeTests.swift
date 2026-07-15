import Testing
import Foundation
@testable import RaceStudioCore

/// Smoke tests for the RaceStudio scaffold (issue 0.1).
///
/// These assert the three-target coverage split is wired correctly: the Core
/// library imports and exposes a public API, and the `@main` executable shell
/// holds no logic. Uses swift-testing (`import Testing`), the framework bundled
/// with the Swift toolchain.
@Suite struct SmokeTests {

    /// The logic core links and is import-able from the test target.
    @Test func testCoreModuleImports() {
        // Referencing the type is enough to prove the module resolves and links.
        _ = RaceStudioCore.self
    }

    /// The core exposes its public placeholder surface with the agreed value,
    /// mirroring the Rust crates' `placeholder() -> 0`.
    @Test func testCoreExposesPublicPlaceholder() {
        #expect(RaceStudioCore.placeholder() == 0)
    }

    /// Architecture fitness check: the `@main` executable target is a pure
    /// SwiftUI shell — it delegates to `RaceStudioCore` and declares no methods
    /// of its own — so it can be excluded from the coverage metric by target.
    @Test func testExecutableTargetHoldsNoLogic() throws {
        let shell = try shellSourceContents()

        #expect(shell.contains("@main"))
        #expect(shell.contains("import RaceStudioCore"))
        #expect(
            !shell.contains("func "),
            "shell must declare no methods (no logic) — only SwiftUI scene/view bodies"
        )
    }

    // MARK: - Helpers

    /// Locates `Sources/RaceStudio/RaceStudioApp.swift` relative to this test
    /// file so the fitness check does not depend on the working directory.
    private func shellSourceContents() throws -> String {
        let testFile = URL(fileURLWithPath: #filePath)
        let appRoot = testFile
            .deletingLastPathComponent() // RaceStudioCoreTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // app
        let shellFile = appRoot
            .appendingPathComponent("Sources/RaceStudio/RaceStudioApp.swift")
        return try String(contentsOf: shellFile, encoding: .utf8)
    }
}
