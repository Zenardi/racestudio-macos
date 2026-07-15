/// Namespace for the RaceStudio logic core.
///
/// Milestone M0 (issue 0.1) ships only a compiling, import-able stub; the real
/// decode/analysis surface (bridged from the Rust core via UniFFI) arrives in
/// later milestones. This target is the 95%-coverage logic library; all
/// testable behaviour lives here rather than in the thin `@main` shell.
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
}
