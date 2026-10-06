import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for ``OverlayLayout/validated()`` (issue 9.10): whatever a layout holds
/// — a hand-edited file, an editor bug, a stray division by zero — validation
/// leaves one the renderer can draw: every rect inside the 3% safe area and at
/// least the minimum size, no NaN or infinity anywhere, and unique widget ids.
@Suite struct OverlayLayoutValidationTests {

    private let safe = NormalizedRect.safeArea(margin: OverlayLayout.safeMargin)

    private func widget(_ id: String, _ kind: OverlayWidgetKind = .speed,
                        frame: NormalizedRect = NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1),
                        opacity: Double = 1, options: OverlayWidgetOptions = OverlayWidgetOptions()) -> OverlayWidget {
        OverlayWidget(id: id, kind: kind, frame: frame, opacity: opacity, options: options)
    }

    private func layout(_ widgets: [OverlayWidget]) -> OverlayLayout {
        OverlayLayout(name: "Test", widgets: widgets)
    }

    // MARK: - Geometry

    /// A layout that is already valid comes back exactly as it was.
    @Test func test_a_valid_layout_is_unchanged() {
        let valid = layout([widget("speed"), widget("delta", .delta)])

        #expect(valid.validated() == valid)
    }

    /// A rect off the frame is moved inside the safe area.
    @Test func test_an_off_frame_rect_is_clamped_into_the_safe_area() throws {
        let stray = layout([widget("speed", frame: NormalizedRect(x: 0.95, y: -0.1, width: 0.2, height: 0.1))])

        let frame = try #require(stray.validated().widgets.first?.frame)

        #expect(frame.isContained(in: safe))
        #expect(frame.width == 0.2)
    }

    /// A rect smaller than the minimum grows to it.
    @Test func test_an_undersized_rect_grows_to_the_minimum_size() throws {
        let tiny = layout([widget("gear", .gear, frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.001, height: 0))])

        let frame = try #require(tiny.validated().widgets.first?.frame)

        #expect(frame.width == OverlayLayout.minimumWidgetSize)
        #expect(frame.height == OverlayLayout.minimumWidgetSize)
    }

    /// A widget whose rect is not finite has no place on the frame: it is dropped
    /// and the rest of the layout survives.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func test_a_widget_with_a_non_finite_rect_is_dropped(bad: Double) {
        let broken = layout([widget("speed"),
                             widget("map", .trackMap, frame: NormalizedRect(x: 0.5, y: bad, width: 0.2, height: 0.3))])

        #expect(broken.validated().widgets.map(\.id) == ["speed"])
    }

    // MARK: - Scalars

    /// Opacity is a fraction; a NaN reads as fully opaque.
    @Test(arguments: [(Double.nan, 1.0), (1.7, 1.0), (-0.2, 0.0), (0.6, 0.6)])
    func test_opacity_is_sanitized(opacity: Double, expected: Double) {
        let validated = layout([widget("speed", opacity: opacity)]).validated()

        #expect(validated.widgets.first?.opacity == expected)
    }

    /// Unusable options fall back to their defaults, and out-of-range ones are
    /// clamped to what the widget can draw.
    @Test func test_options_are_sanitized() throws {
        let wild = OverlayWidgetOptions(maxRPM: .nan, shiftLightRPM: 90_000, deltaRange: 50,
                                        gForceMax: 0, trackMapRotation: -90)

        let options = try #require(layout([widget("rpm", .rpm, options: wild)]).validated().widgets.first?.options)

        #expect(options.maxRPM == OverlayWidgetOptions.defaultMaxRPM)
        #expect(options.shiftLightRPM == OverlayWidgetOptions.defaultMaxRPM)
        #expect(options.deltaRange == OverlayWidgetOptions.deltaRangeLimits.upperBound)
        #expect(options.gForceMax == OverlayWidgetOptions.gForceMaxLimits.lowerBound)
        #expect(options.trackMapRotation == 270)
    }

    /// A non-finite option reads as its default.
    @Test func test_non_finite_options_read_as_defaults() throws {
        let wild = OverlayWidgetOptions(maxRPM: 12_000, shiftLightRPM: .infinity, deltaRange: .nan,
                                        gForceMax: -.infinity, trackMapRotation: .nan)

        let options = try #require(layout([widget("rpm", .rpm, options: wild)]).validated().widgets.first?.options)

        #expect(options.maxRPM == 12_000)
        #expect(options.shiftLightRPM == 12_000, "the default threshold is clamped to the scale")
        #expect(options.deltaRange == OverlayWidgetOptions.defaultDeltaRange)
        #expect(options.gForceMax == OverlayWidgetOptions.defaultGForceMax)
        #expect(options.trackMapRotation == 0)
    }

    /// Rotation is kept in one turn, `0..<360` — even when a hair below zero
    /// would round up to a full turn.
    @Test(arguments: [(720.0, 0.0), (405.0, 45.0), (-450.0, 270.0), (-1e-20, 0.0)])
    func test_track_map_rotation_is_normalized(degrees: Double, expected: Double) {
        let options = OverlayWidgetOptions(trackMapRotation: degrees)

        #expect(layout([widget("map", .trackMap, options: options)]).validated()
            .widgets.first?.options.trackMapRotation == expected)
    }

    // MARK: - Identity

    /// Repeated ids are renamed — the widgets the operator placed stay — and an
    /// id that was already unique keeps it.
    @Test func test_duplicate_ids_are_renamed_without_touching_unique_ones() {
        let copied = layout([widget("speed"), widget("speed"), widget("speed-2"), widget("speed")])

        #expect(copied.validated().widgets.map(\.id) == ["speed", "speed-3", "speed-2", "speed-4"])
    }

    /// A blank id takes the widget kind's key.
    @Test func test_a_blank_id_takes_the_kind_key() {
        let unnamed = layout([widget("  ", .lapTimer), widget("", .lapTimer)])

        #expect(unnamed.validated().widgets.map(\.id) == ["lapTimer", "lapTimer-2"])
    }

    /// Validation is idempotent: a validated layout is already valid.
    @Test func test_validation_is_idempotent() {
        let messy = layout([widget("a", frame: NormalizedRect(x: 2, y: 2, width: 3, height: 0)),
                            widget("a", opacity: .nan), widget("", .delta)])

        let once = messy.validated()

        #expect(once.validated() == once)
    }
}
