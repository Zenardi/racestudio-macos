import Testing
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// Round-trip tests for the Rust→Swift UniFFI boundary (issue 0.4).
///
/// These prove the pipeline works end-to-end: the Rust `core_version()` export
/// is bridged to Swift via the generated bindings and returns the crate version
/// unchanged across the FFI boundary.
@Suite struct FFIRoundTripTests {

    /// The Rust `racestudio-ffi` crate version. Kept in lockstep with the
    /// workspace `Cargo.toml`; the round-trip test below pins them together.
    static let expectedRustCrateVersion = "0.1.0"

    /// `coreVersion()` crosses the FFI boundary and returns a non-empty,
    /// semver-shaped string (proving the boundary call succeeds and the value
    /// survives the crossing).
    @Test func testCoreVersionCrossesBoundary() {
        let version = RaceStudioCore.coreVersion()
        #expect(!version.isEmpty)
        #expect(version.split(separator: ".").count == 3)
    }

    /// The bridged version equals the Rust crate version exactly.
    @Test func testCoreVersionMatchesRustCrateVersion() {
        #expect(RaceStudioCore.coreVersion() == Self.expectedRustCrateVersion)
    }

    /// The generated low-level bindings module imports and is callable, and
    /// `RaceStudioCore` forwards to it unchanged.
    @Test func testGeneratedBindingsImport() {
        #expect(RaceStudioFFIBindings.coreVersion() == RaceStudioCore.coreVersion())
    }
}
