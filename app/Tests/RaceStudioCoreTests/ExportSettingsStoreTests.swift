import Foundation
import Testing
@testable import RaceStudioCore

/// The export sheet's last-used settings (issue 9.14): kept per user behind
/// the `KeyValueStoring` seam (`UserDefaults` in the app), and read leniently —
/// a value this build doesn't know, or a damaged entry, falls back to that
/// setting's default instead of failing the sheet.
@Suite struct ExportSettingsStoreTests {

    private let key = ExportSettingsStore.defaultKey

    /// Nothing saved yet: every choice is left to the sheet's defaults, and the
    /// output settings are 1080p H.264 with the sound kept.
    @Test func test_an_empty_store_reads_the_defaults() {
        let store = ExportSettingsStore(store: InMemoryKeyValueStore())

        let preferences = store.load()

        #expect(preferences == ExportPreferences())
        #expect(preferences.range == nil)
        #expect(preferences.overlay == nil)
        #expect(preferences.settings == ExportSettings(resolution: .p1080, codec: .h264, audio: .keep,
                                                       outsideSession: .hidden))
    }

    /// What was saved is what is read back, every field.
    @Test func test_saved_settings_are_restored() {
        let backing = InMemoryKeyValueStore()
        let saved = ExportPreferences(range: .wholeFootage, overlay: .preset(.minimal),
                                      settings: ExportSettings(resolution: .p720, codec: .hevc, audio: .drop,
                                                               outsideSession: .noData))

        ExportSettingsStore(store: backing).save(saved)
        let restored = ExportSettingsStore(store: backing).load()

        #expect(restored == saved)
    }

    /// The workspace's own overlay is remembered as a choice, not as a layout.
    @Test func test_the_workspace_overlay_choice_is_restored() {
        let backing = InMemoryKeyValueStore()

        ExportSettingsStore(store: backing).save(ExportPreferences(range: .selectedLaps, overlay: .workspace))

        #expect(ExportSettingsStore(store: backing).load().overlay == .workspace)
        #expect(ExportSettingsStore(store: backing).load().range == .selectedLaps)
    }

    /// A value this build doesn't know — written by a newer build, or edited by
    /// hand — falls back to that setting's default; the others are kept.
    @Test func test_unknown_values_fall_back_to_their_defaults() {
        let json = """
        {"range": "lastTenLaps", "overlay": "neonGlow", "resolution": "p4320", "codec": "av1",
         "audio": "keep", "outsideSession": "noData"}
        """
        let store = ExportSettingsStore(store: InMemoryKeyValueStore(seed: [key: Data(json.utf8)]))

        let preferences = store.load()

        #expect(preferences.range == nil)
        #expect(preferences.overlay == nil)
        #expect(preferences.settings == ExportSettings(resolution: .p1080, codec: .h264, audio: .keep,
                                                       outsideSession: .noData))
    }

    /// A value of the wrong type is unknown too.
    @Test func test_values_of_the_wrong_type_fall_back_to_their_defaults() {
        let json = #"{"range": 3, "overlay": true, "resolution": ["p720"], "codec": "hevc", "audio": null}"#
        let store = ExportSettingsStore(store: InMemoryKeyValueStore(seed: [key: Data(json.utf8)]))

        let preferences = store.load()

        #expect(preferences.range == nil)
        #expect(preferences.overlay == nil)
        #expect(preferences.settings == ExportSettings(codec: .hevc))
    }

    /// Bytes that are not a settings record at all read as the defaults.
    @Test func test_damaged_data_reads_as_the_defaults() {
        let damaged = InMemoryKeyValueStore(seed: [key: Data("{ not json".utf8)])
        let wrongShape = InMemoryKeyValueStore(seed: [key: Data(#"["p720", "hevc"]"#.utf8)])

        #expect(ExportSettingsStore(store: damaged).load() == ExportPreferences())
        #expect(ExportSettingsStore(store: wrongShape).load() == ExportPreferences())
    }

    /// Every overlay choice has a stable stored spelling that reads back as
    /// itself — a renamed case must not silently lose the operator's choice.
    @Test func test_overlay_choices_round_trip_their_stored_spelling() {
        let choices: [ExportOverlayChoice] = [.workspace] + OverlayPreset.allCases.map { .preset($0) }

        let restored = choices.map { ExportOverlayChoice(storageValue: $0.storageValue) }

        #expect(restored == choices)
        #expect(choices.map(\.storageValue) == ["workspace", "minimal", "kartCoaching", "fullTelemetry"])
        #expect(ExportOverlayChoice(storageValue: "unknown") == nil)
    }

    /// The widget switches (issue 9.19) are remembered per overlay choice.
    @Test func test_widget_switches_are_restored_per_overlay_choice() {
        let backing = InMemoryKeyValueStore()
        let saved = ExportPreferences(overlay: .preset(.kartCoaching), widgetSwitches: [
            .preset(.kartCoaching): ["gForce": false, "trackMap": false],
            .workspace: ["kartBadge": true]
        ])

        ExportSettingsStore(store: backing).save(saved)

        #expect(ExportSettingsStore(store: backing).load() == saved)
    }

    /// Settings saved before the switches existed read with none; switches
    /// for an overlay this build doesn't know, or that aren't on/off values,
    /// are dropped and the others kept.
    @Test func test_older_or_unknown_widget_switches_are_ignored() {
        let older = #"{"overlay": "minimal", "codec": "hevc"}"#
        let mixed = """
        {"widgets": {"neonGlow": {"speed": false}, "minimal": {"speed": false, "delta": "off", "lapTimer": 1},
                     "workspace": [true]}}
        """
        let olderStore = ExportSettingsStore(store: InMemoryKeyValueStore(seed: [key: Data(older.utf8)]))
        let mixedStore = ExportSettingsStore(store: InMemoryKeyValueStore(seed: [key: Data(mixed.utf8)]))

        #expect(olderStore.load().widgetSwitches.isEmpty)
        #expect(olderStore.load().overlay == .preset(.minimal))
        #expect(mixedStore.load().widgetSwitches == [.preset(.minimal): ["speed": false]])
    }

    /// Two stores under different keys never see each other's settings.
    @Test func test_the_key_scopes_the_settings() {
        let backing = InMemoryKeyValueStore()

        ExportSettingsStore(store: backing, key: "a").save(ExportPreferences(range: .session))

        #expect(ExportSettingsStore(store: backing, key: "b").load() == ExportPreferences())
        #expect(ExportSettingsStore(store: backing, key: "a").load().range == .session)
    }
}
