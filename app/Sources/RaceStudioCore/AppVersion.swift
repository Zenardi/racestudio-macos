import Foundation

/// The running app's own version, for the About panel and the Home footer.
///
/// A user reporting a problem — or checking whether a fix has reached them — needs
/// to see which build they are on. `scripts/build_app.sh` stamps both bundle keys
/// from the release tag, so a shipped build reports one number; a development
/// build can differ, and then the build is shown alongside. The Rust core reports
/// its own version through the FFI, surfaced next to the app's so a mismatched
/// xcframework is visible rather than silent.
public struct AppVersion: Equatable, Sendable {

    /// Shown in place of a version key that is absent or blank — a `swift run` of
    /// the executable outside a `.app` bundle has no `Info.plist` at all.
    public static let unknown = "unknown"

    /// `CFBundleShortVersionString` — the marketing version (e.g. `0.2.2`).
    public let marketing: String
    /// `CFBundleVersion` — the build. Equal to ``marketing`` in a release build.
    public let build: String
    /// The Rust core's version, or `nil` in a build without the FFI xcframework.
    public let core: String?

    public init(marketing: String, build: String, core: String? = nil) {
        self.marketing = marketing
        self.build = build
        self.core = core
    }

    /// Read the version keys from a bundle's info dictionary. A missing, non-string,
    /// or blank value becomes ``unknown`` rather than an empty label.
    public init(infoDictionary: [String: Any]?, core: String? = nil) {
        func read(_ key: String) -> String {
            guard let raw = infoDictionary?[key] as? String else { return AppVersion.unknown }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? AppVersion.unknown : trimmed
        }
        self.init(marketing: read("CFBundleShortVersionString"),
                  build: read("CFBundleVersion"), core: core)
    }

    /// `"0.2.2"`, or `"0.2.2 (17)"` when the build differs from the marketing
    /// version — a release build stamps both identically, so it is not repeated.
    public var shortDisplay: String {
        build == marketing ? marketing : "\(marketing) (\(build))"
    }

    /// The line added under the app's name in the standard About panel. The decode
    /// core is named explicitly so a stale or mismatched `RaceStudioFFI.xcframework`
    /// is visible to a user reporting a problem, rather than silent.
    public var creditsText: String {
        "Decode core \(core ?? AppVersion.unknown)"
    }

    /// The full one-line label: `"RaceStudio 0.2.2 — core 0.2.2"`. The core clause
    /// is omitted entirely when there is no core to report.
    public var fullDisplay: String {
        let base = "RaceStudio \(shortDisplay)"
        guard let core, !core.isEmpty else { return base }
        return "\(base) — core \(core)"
    }
}

public extension AppVersion {
    /// The running build's version: the main bundle's keys, paired with the Rust
    /// core's version when the FFI xcframework is present.
    static var current: AppVersion {
        AppVersion(infoDictionary: Bundle.main.infoDictionary, core: linkedCoreVersion)
    }

    #if canImport(RaceStudioFFIBindings)
    /// The Rust core's version, read through the 1.7 bindings.
    private static var linkedCoreVersion: String? { RaceStudioFFIBindings.coreVersion() }
    #else
    /// No xcframework in this build, so there is no core version to report.
    private static var linkedCoreVersion: String? { nil }
    #endif
}

#if canImport(RaceStudioFFIBindings)
import RaceStudioFFIBindings
#endif
