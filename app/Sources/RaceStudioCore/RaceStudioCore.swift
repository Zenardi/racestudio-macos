#if canImport(RaceStudioFFIBindings)
import RaceStudioFFIBindings
#endif

/// Namespace for the RaceStudio logic core.
///
/// This target is the 95%-coverage logic library; all testable behaviour lives
/// here rather than in the thin `@main` shell. As of issue 0.4 it bridges the
/// first value across the Rust→Swift UniFFI boundary (`coreVersion()`); real
/// decode/analysis surface arrives in later milestones.
public enum RaceStudioCore {

    /// Human-readable product name. Owned by the Core so the `@main` shell can
    /// render it without holding any logic of its own.
    public static let appName = "RaceStudio"

    /// Compiling stub proving the Core library links and is import-able.
    ///
    /// Returns an inert sentinel (`0`), mirroring the Rust crates'
    /// `placeholder() -> 0`. The real API arrives in later milestones.
    public static func placeholder() -> Int {
        0
    }

    #if canImport(RaceStudioFFIBindings)
    /// The Rust core version, obtained across the UniFFI boundary.
    ///
    /// Forwards to the uniffi-generated binding, which calls the Rust
    /// `core_version()` export. Available when the RaceStudioFFI xcframework has
    /// been built (`scripts/build_xcframework.sh`).
    public static func coreVersion() -> String {
        RaceStudioFFIBindings.coreVersion()
    }
    #endif
}
