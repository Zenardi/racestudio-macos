import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for how an ``OverlayLayout`` persists (issue 9.10) — in a project and in
/// the user preset library. A layout round-trips exactly; reading is lenient (a
/// widget this build doesn't know is skipped, a missing or malformed setting
/// takes its default) and always validated, and writing never fails on a value
/// JSON cannot hold.
@Suite struct OverlayLayoutCodingTests {

    private func decode(_ json: String) throws -> OverlayLayout {
        try JSONDecoder().decode(OverlayLayout.self, from: Data(json.utf8))
    }

    private func roundTrip(_ layout: OverlayLayout) throws -> OverlayLayout {
        try JSONDecoder().decode(OverlayLayout.self, from: JSONEncoder().encode(layout))
    }

    /// One widget of every kind, each with non-default settings.
    private var everyKind: OverlayLayout {
        let kinds: [OverlayWidgetKind] = [.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap,
                                          .pedals, .temperature, .sectorTimes, .channelValue(.role(.waterTemp)),
                                          .channelValue(.channel("Logger Temperature")), .kartBadge, .sessionInfo]
        let widgets = kinds.enumerated().map { index, kind in
            OverlayWidget(id: "w\(index)", kind: kind,
                          frame: NormalizedRect(x: 0.05 + 0.05 * Double(index), y: 0.1, width: 0.05, height: 0.2),
                          anchor: .bottomTrailing, z: index, opacity: 0.75, plate: .solid, sizeClass: .large,
                          units: .imperial, isVisible: index % 2 == 0,
                          options: OverlayWidgetOptions(maxRPM: 7_000, shiftLightRPM: 6_400, deltaRange: 0.5,
                                                        gForceMax: 1.5, trackMapRotation: 90))
        }
        return OverlayLayout(name: "Everything", widgets: widgets, units: .imperial, isEnabled: false)
    }

    // MARK: - Round trip

    /// Every kind and every setting survives a save and a reload.
    @Test func test_every_kind_round_trips_exactly() throws {
        #expect(try roundTrip(everyKind) == everyKind)
    }

    /// A widget kind persists as a `type` tag, with the channel it reads when it
    /// is a channel value.
    @Test func test_kinds_persist_as_tagged_objects() throws {
        let encoded = try JSONEncoder().encode([OverlayWidgetKind.speed, .channelValue(.role(.rpm)),
                                                .channelValue(.channel("Oil"))])
        let objects = try #require(try JSONSerialization.jsonObject(with: encoded) as? [[String: String]])

        #expect(objects == [["type": "speed"], ["type": "channelValue", "role": "rpm"],
                            ["type": "channelValue", "channel": "Oil"]])
    }

    // MARK: - Lenient reading

    /// Only a widget's id, kind and rect are needed; everything else defaults.
    @Test func test_a_minimal_widget_takes_the_defaults() throws {
        let layout = try decode("""
        {"widgets": [{"id": "s", "kind": {"type": "speed"},
                      "frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}}]}
        """)

        let widget = try #require(layout.widgets.first)
        #expect(widget == OverlayWidget(id: "s", kind: .speed,
                                        frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)))
        #expect(layout.schema == OverlayLayout.currentSchema)
        #expect(layout.name.isEmpty)
        #expect(layout.units == .metric)
        #expect(layout.theme == .raceStudio)
        #expect(layout.isEnabled)
    }

    /// A widget this build doesn't understand — an unknown kind, a channel value
    /// naming nothing, a missing rect — is skipped; its neighbours load.
    @Test func test_an_unreadable_widget_is_skipped() throws {
        let layout = try decode("""
        {"name": "Mixed", "widgets": [
          {"id": "a", "kind": {"type": "hologram"}, "frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}},
          {"id": "b", "kind": {"type": "channelValue"}, "frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1}},
          {"id": "c", "kind": {"type": "speed"}},
          {"id": "d", "kind": {"type": "rpm"}, "frame": {"x": 0.1, "y": 0.5, "width": 0.4, "height": 0.1}}
        ]}
        """)

        #expect(layout.widgets.map(\.id) == ["d"])
    }

    /// A malformed setting is cosmetic: it takes its default and the layout loads.
    @Test func test_malformed_settings_take_their_defaults() throws {
        let layout = try decode("""
        {"name": 7, "units": "furlongs", "theme": 3, "isEnabled": "yes", "widgets": [
          {"id": "s", "kind": {"type": "speed"}, "frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.1},
           "anchor": "nowhere", "z": "top", "opacity": "half", "plate": "glass", "sizeClass": "huge",
           "units": "furlongs", "isVisible": "no", "options": {"maxRPM": "lots", "deltaRange": 0.4}}
        ]}
        """)

        let widget = try #require(layout.widgets.first)
        #expect(layout.name.isEmpty)
        #expect(layout.units == .metric)
        #expect(layout.isEnabled)
        #expect(widget.anchor == .topLeading)
        #expect(widget.z == 0)
        #expect(widget.opacity == 1)
        #expect(widget.plate == .translucent)
        #expect(widget.sizeClass == .medium)
        #expect(widget.units == nil)
        #expect(widget.isVisible)
        #expect(widget.options.maxRPM == OverlayWidgetOptions.defaultMaxRPM)
        #expect(widget.options.deltaRange == 0.4)
    }

    /// Options saved before any option existed read as every default.
    @Test func test_empty_options_read_as_the_defaults() throws {
        let options = try JSONDecoder().decode(OverlayWidgetOptions.self, from: Data("{}".utf8))

        #expect(options == OverlayWidgetOptions())
    }

    /// A widget saved without an id takes its kind's key.
    @Test func test_a_widget_without_an_id_takes_the_kind_key() throws {
        let layout = try decode("""
        {"widgets": [{"kind": {"type": "trackMap"}, "frame": {"x": 0.7, "y": 0.6, "width": 0.18, "height": 0.32}}]}
        """)

        #expect(layout.widgets.map(\.id) == ["trackMap"])
    }

    /// What is read is validated: a hand-edited rect off the frame comes back
    /// inside the safe area, and a copied id is renamed.
    @Test func test_a_decoded_layout_is_validated() throws {
        let layout = try decode("""
        {"widgets": [
          {"id": "s", "kind": {"type": "speed"}, "frame": {"x": 1.5, "y": 0.1, "width": 0.2, "height": 0.1}},
          {"id": "s", "kind": {"type": "delta"}, "frame": {"x": 0.3, "y": 0.1, "width": 0.2, "height": 0.1}}
        ]}
        """)

        #expect(layout.widgets.map(\.id) == ["s", "s-2"])
        #expect(layout.widgets[0].frame.isContained(in: .safeArea(margin: OverlayLayout.safeMargin)))
    }

    // MARK: - Writing

    /// JSON cannot hold a NaN, so a layout is written validated: a widget with a
    /// non-finite rect is left out rather than failing the save.
    @Test func test_a_layout_with_a_nan_rect_still_saves() throws {
        let broken = OverlayLayout(name: "Broken", widgets: [
            OverlayWidget(id: "ok", kind: .speed, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)),
            OverlayWidget(id: "nan", kind: .gear, frame: NormalizedRect(x: .nan, y: 0, width: 0.1, height: 0.1))
        ])

        let reloaded = try roundTrip(broken)

        #expect(reloaded.widgets.map(\.id) == ["ok"])
    }
}
