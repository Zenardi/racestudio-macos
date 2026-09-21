import Foundation

/// Locates the SwiftPM resource bundle that ships `Localizable.xcstrings`.
///
/// SwiftPM synthesises a `Bundle.module` accessor for any target with resources,
/// but that accessor **traps** (`Swift.fatalError`) when the bundle is absent, and
/// the variant emitted for a release build probes only two paths: the directory
/// holding the app bundle, and the *absolute build directory of the machine that
/// compiled it*. In a shipped `.app` the first is empty and the second points at
/// the CI runner's filesystem, so the very first localized string kills the app —
/// which is exactly how v0.1.0 crashed the moment a session was opened for
/// analysis (the `.app` had no resource bundle at all).
///
/// Resolving the bundle here instead keeps the lookup **total**: every candidate is
/// probed with `FileManager`, a miss returns `nil`, and ``LocalizationCatalog``
/// degrades to ``LocalizationCatalog/empty``. A packaging fault then shows sentinel
/// strings a developer notices rather than a SIGTRAP a user hits.
public enum ResourceBundle {

    /// The bundle SwiftPM emits for `RaceStudioCore`'s resources.
    public static let localizationBundleName = "RaceStudio_RaceStudioCore"

    /// The directories a resource bundle can legitimately sit in, most-specific first:
    ///
    /// - `Bundle.main.resourceURL` — `Contents/Resources` of a packaged `.app`; this
    ///   is where `scripts/build_app.sh` installs it and the conventional, signable spot.
    /// - `Bundle.main.bundleURL` — alongside a command-line binary, and the only place
    ///   SwiftPM's release accessor looks inside an `.app`.
    /// - the defining module's own bundle and its parent — the `.xctest` layout used
    ///   when running the test suite, and `swift build`'s `.build/<triple>/<config>`.
    public static var defaultSearchDirectories: [URL] {
        let module = Bundle(for: BundleFinder.self)
        return [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            module.resourceURL,
            module.bundleURL,
            module.bundleURL.deletingLastPathComponent()
        ].compactMap { $0 }
    }

    /// The first `<name>.bundle` that exists in `directories`, or `nil` when none do.
    ///
    /// `directories` and `exists` are injectable so the search order is unit-testable
    /// without staging real bundles on disk.
    public static func locate(
        named name: String = localizationBundleName,
        in directories: [URL] = defaultSearchDirectories,
        exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> URL? {
        for directory in directories {
            let candidate = directory.appendingPathComponent("\(name).bundle")
            if exists(candidate) { return candidate }
        }
        return nil
    }

    /// The located bundle, or `nil` when it is missing — never a trap.
    public static func localization() -> Bundle? {
        locate().flatMap(Bundle.init(url:))
    }
}

/// Anchors `Bundle(for:)` to the module that defines it, so the search can find a
/// resource bundle sitting next to `RaceStudioCore` in a test or `swift build` layout.
private final class BundleFinder {}
