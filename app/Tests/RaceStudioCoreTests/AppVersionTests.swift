import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for the app's self-reported version: it reads the bundle's
/// marketing/build strings, pairs them with the Rust core's version, and
/// renders a display string for the About panel and the Home footer — degrading
/// to a readable placeholder rather than an empty label when a key is absent.
@Suite struct AppVersionTests {

    // MARK: - Reading the bundle

    @Test func test_reads_marketing_and_build_from_the_info_dictionary() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.2.2", "CFBundleVersion": "17"])

        #expect(version.marketing == "0.2.2")
        #expect(version.build == "17")
    }

    /// A bundle with no version keys must still render — an App Store build always
    /// has them, but a `swift run` of the executable outside a `.app` does not.
    @Test func test_missing_keys_fall_back_to_a_readable_placeholder() {
        let version = AppVersion(infoDictionary: [:])

        #expect(version.marketing == AppVersion.unknown)
        #expect(version.build == AppVersion.unknown)
    }

    @Test func test_a_nil_info_dictionary_is_treated_as_empty() {
        #expect(AppVersion(infoDictionary: nil).marketing == AppVersion.unknown)
    }

    /// `scripts/build_app.sh` stamps both keys from the release tag, so a shipped
    /// build has `CFBundleVersion == CFBundleShortVersionString`.
    @Test func test_a_release_build_stamps_both_keys_identically() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "0.2.2", "CFBundleVersion": "0.2.2"])

        #expect(version.shortDisplay == "0.2.2", "the redundant build is not repeated")
    }

    // MARK: - Display

    @Test func test_short_display_appends_a_distinct_build_number() {
        let version = AppVersion(marketing: "0.2.2", build: "17")

        #expect(version.shortDisplay == "0.2.2 (17)")
    }

    @Test func test_full_display_names_the_app_and_the_core() {
        let version = AppVersion(marketing: "0.2.2", build: "0.2.2", core: "0.2.2")

        #expect(version.fullDisplay == "RaceStudio 0.2.2 — core 0.2.2")
    }

    /// A build without the FFI xcframework has no Rust core to report; the label
    /// omits the clause rather than printing an empty or "nil" one.
    @Test func test_full_display_omits_the_core_when_it_is_absent() {
        let version = AppVersion(marketing: "0.2.2", build: "0.2.2", core: nil)

        #expect(version.fullDisplay == "RaceStudio 0.2.2")
    }

    @Test func test_full_display_carries_a_distinct_build_through() {
        let version = AppVersion(marketing: "0.3.0", build: "41", core: "0.3.0")

        #expect(version.fullDisplay == "RaceStudio 0.3.0 (41) — core 0.3.0")
    }

    /// An empty string in the plist is as useless as a missing key, so it takes
    /// the same placeholder rather than rendering a blank version.
    @Test func test_an_empty_version_string_is_treated_as_missing() {
        let version = AppVersion(infoDictionary: [
            "CFBundleShortVersionString": "", "CFBundleVersion": "  "])

        #expect(version.marketing == AppVersion.unknown)
        #expect(version.build == AppVersion.unknown)
    }
}

/// The line the About panel adds under the app's name.
@Suite struct AppVersionCreditsTests {

    @Test func test_credits_name_the_decode_core() {
        #expect(AppVersion(marketing: "0.2.2", build: "0.2.2", core: "0.2.2").creditsText
                == "Decode core 0.2.2")
    }

    /// A build without the xcframework still renders a line, so the panel never
    /// shows a blank or "nil" credit.
    @Test func test_credits_report_an_absent_core_as_unknown() {
        #expect(AppVersion(marketing: "0.2.2", build: "0.2.2", core: nil).creditsText
                == "Decode core unknown")
    }
}

/// The running build's own version, read from the live bundle.
@Suite struct AppVersionCurrentTests {

    /// `current` is what every UI surface actually shows, so it must resolve rather
    /// than trap — including under the test bundle, which has no app version keys.
    @Test func test_the_running_version_resolves() {
        let version = AppVersion.current

        #expect(!version.marketing.isEmpty)
        #expect(!version.fullDisplay.isEmpty)
        #expect(version.fullDisplay.hasPrefix("RaceStudio "))
    }

    /// Built against the FFI xcframework, the decode core must report a version —
    /// this is the check that makes a missing or stale core visible.
    @Test func test_a_linked_core_reports_its_version() throws {
        #if canImport(RaceStudioFFIBindings)
        let core = try #require(AppVersion.current.core)
        #expect(!core.isEmpty)
        #else
        #expect(AppVersion.current.core == nil)
        #endif
    }
}
