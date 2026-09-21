import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for ``ResourceBundle`` — the total replacement for SwiftPM's synthesised
/// `Bundle.module` accessor.
///
/// `Bundle.module` `fatalError`s when its bundle is absent, and the variant emitted
/// for a release build probes only the app-bundle directory and the *absolute build
/// directory of the compiling machine*. Shipped v0.1.0 satisfied neither, so the
/// first localized string trapped and the app died as soon as a session was opened
/// for analysis. These assertions pin the replacement's two guarantees: it finds a
/// bundle that is present, and it returns `nil` — never traps — when one is not.
@Suite struct ResourceBundleTests {

    /// A directory containing `<name>.bundle`, cleaned up by the caller.
    private func stagedBundle(named name: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rs-resbundle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("\(name).bundle"),
            withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Search order

    @Test func test_locates_the_bundle_in_the_first_matching_directory() throws {
        let present = try stagedBundle(named: "Pkg_Target")
        defer { try? FileManager.default.removeItem(at: present) }
        let absent = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")

        let found = ResourceBundle.locate(named: "Pkg_Target", in: [absent, present])

        #expect(found == present.appendingPathComponent("Pkg_Target.bundle"))
    }

    @Test func test_search_order_is_most_specific_first() throws {
        // Given the same bundle name staged in two directories, Then the earlier
        // directory wins — Contents/Resources of a packaged .app must beat the
        // build-directory fallbacks.
        let first = try stagedBundle(named: "Pkg_Target")
        let second = try stagedBundle(named: "Pkg_Target")
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let found = ResourceBundle.locate(named: "Pkg_Target", in: [first, second])

        #expect(found == first.appendingPathComponent("Pkg_Target.bundle"))
    }

    // MARK: - The crash that shipped

    @Test func test_returns_nil_instead_of_trapping_when_no_candidate_exists() {
        // This is the v0.1.0 crash condition: an .app with no resource bundle and a
        // build path that exists only on the machine that compiled it.
        let found = ResourceBundle.locate(
            named: "RaceStudio_RaceStudioCore",
            in: [
                URL(fileURLWithPath: "/Applications/RaceStudio.app"),
                URL(fileURLWithPath: "/Users/runner/work/racestudio-macos/app/.build/release")
            ],
            exists: { _ in false })

        #expect(found == nil)
    }

    @Test func test_empty_search_path_returns_nil() {
        #expect(ResourceBundle.locate(named: "RaceStudio_RaceStudioCore", in: []) == nil)
    }

    @Test func test_probes_every_directory_until_one_matches() throws {
        var probed: [String] = []
        let dirs = (1...3).map { URL(fileURLWithPath: "/candidate-\($0)") }

        let found = ResourceBundle.locate(named: "Pkg_Target", in: dirs) { url in
            probed.append(url.path)
            return url.path.contains("candidate-3")
        }

        #expect(found?.path == "/candidate-3/Pkg_Target.bundle")
        #expect(probed.count == 3, "the search must not stop before a match")
    }

    // MARK: - Real resolution

    @Test func test_default_search_directories_are_non_empty() {
        // A malformed candidate list would silently disable localization everywhere.
        #expect(!ResourceBundle.defaultSearchDirectories.isEmpty)
    }

    @Test func test_resolves_the_real_catalog_so_strings_are_not_sentinels() throws {
        // The end-to-end guarantee: the locator finds the genuine resource bundle in
        // this build layout, so L10n returns real strings rather than the
        // ⚠️MISSING sentinel that a packaging fault degrades to.
        #expect(ResourceBundle.localization() != nil, "the resource bundle must be locatable")
        #expect(!LocalizationCatalog.shared.keys.isEmpty, "the shared catalog must not be empty")

        let appName = L10n.string(.appName)
        #expect(!appName.hasPrefix(L10n.missingKeyPrefix), "got sentinel instead of a real string: \(appName)")
    }
}
