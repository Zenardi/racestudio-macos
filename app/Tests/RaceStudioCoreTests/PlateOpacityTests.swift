import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the HUD's background opacity (issue 9.24): one setting for the
/// whole HUD, 0 % to 100 %, that every translucent plate is drawn with — in the
/// live HUD and the export — saved with the layout, undoable, and never at the
/// cost of legible text.
@MainActor
@Suite struct PlateOpacityTests {

    // MARK: - Fixture (no logic — fixed layouts and frames)

    private let theme = OverlayTheme.raceStudio
    private let speed = SpeedWidget()

    private func layout(opacity: Double) -> OverlayLayout {
        OverlayLayout(name: "Plates", widgets: [
            OverlayWidget(kind: .speed, frame: NormalizedRect(x: 0.03, y: 0.82, width: 0.14, height: 0.15)),
            OverlayWidget(kind: .kartBadge, frame: NormalizedRect(x: 0.03, y: 0.03, width: 0.24, height: 0.06),
                          plate: .solid),
            OverlayWidget(kind: .delta, frame: NormalizedRect(x: 0.35, y: 0.03, width: 0.3, height: 0.07),
                          plate: .none)
        ], plateOpacity: opacity)
    }

    /// The speed widget's plate, drawn alone with `opacity` in a 240 × 140 box.
    private func plateAlpha(_ opacity: Double, plate: OverlayPlateStyle = .translucent) -> Int {
        let context = OverlayRenderFixture.context(.speed, plate: plate, theme: theme.withPlateOpacity(opacity))
        let bitmap = OverlayRenderFixture.render(speed, OverlayRenderFixture.midLap, context: context,
                                                 parts: .staticOnly)
        return Int(bitmap.pixel(at: CGPoint(x: context.rect.midX, y: context.rect.minY + 1)).alpha)
    }

    // MARK: - The setting

    /// The HUD's background opacity is 88 % until changed — the plate as
    /// before.
    @Test func test_the_background_opacity_starts_at_88_percent() {
        #expect(OverlayLayout(name: "New").plateOpacity == 0.88)
        #expect(OverlayLayout.defaultPlateOpacity == theme.translucentPlateOpacity)
    }

    /// The opacity stays within 0–100 % and whole percent; one that isn't a
    /// number reads as the default.
    @Test(arguments: zip([-1, 2, .nan, .infinity, 0.5, 0.333], [0, 1, 0.88, 1, 0.5, 0.33]))
    func test_the_opacity_is_kept_in_range(given: Double, kept: Double) {
        #expect(layout(opacity: given).validated().plateOpacity == kept)
    }

    /// The opacity is saved with the layout; an older layout, or a value that
    /// can't be read, reads as 88 %.
    @Test func test_the_opacity_is_saved_and_older_layouts_read_the_default() throws {
        let saved = try JSONDecoder().decode(OverlayLayout.self, from: JSONEncoder().encode(layout(opacity: 0.4)))
        let older = try JSONDecoder().decode(OverlayLayout.self, from: Data(#"{"name": "Old", "widgets": []}"#.utf8))
        let broken = try JSONDecoder().decode(OverlayLayout.self,
                                              from: Data(#"{"name": "Bad", "plateOpacity": "half"}"#.utf8))

        #expect(saved.plateOpacity == 0.4)
        #expect(older.plateOpacity == 0.88)
        #expect(broken.plateOpacity == 0.88)
    }

    // MARK: - Drawing

    /// Every translucent plate is drawn with the HUD's opacity.
    @Test(arguments: [0.25, 0.5, 0.88, 1])
    func test_the_plate_is_drawn_with_the_opacity(opacity: Double) {
        #expect(abs(plateAlpha(opacity) - Int((opacity * 255).rounded())) <= 1)
    }

    /// At 0 % no plate is drawn at all.
    @Test func test_at_0_percent_no_plate_is_drawn() {
        #expect(plateAlpha(0) == 0)
        #expect(theme.withPlateOpacity(0).plateFill(.translucent) == nil)
    }

    /// A solid plate stays opaque, and a widget without a plate stays without.
    @Test func test_solid_and_no_plates_ignore_the_opacity() {
        #expect(plateAlpha(0.3, plate: .solid) == 255)
        #expect(plateAlpha(0.3, plate: .none) == 0)
    }

    /// The renderer — the live HUD's and the export's — draws with the
    /// layout's opacity.
    @Test func test_the_renderer_draws_with_the_layouts_opacity() {
        let renderer = OverlayRenderer(layout: layout(opacity: 0.4), session: OverlayRenderFixture.session(),
                                       track: OverlayRenderFixture.track, sectors: OverlayRenderFixture.sectors)

        #expect(renderer.theme.translucentPlateOpacity == 0.4)
    }

    // MARK: - Legibility

    /// From the default up, the plate itself carries WCAG AA (≥ 4.5:1) for
    /// every text role over the worst footage.
    @Test(arguments: [0.88, 0.95, 1])
    func test_from_the_default_up_the_plate_carries_the_contrast(opacity: Double) throws {
        for role in OverlayTheme.TextRole.allCases {
            for footage in [BrandColor.rgb(255, 255, 255), .rgb(0, 0, 0)] {
                let plate = try #require(theme.withPlateOpacity(opacity).effectivePlate(.translucent, over: footage))
                #expect(theme.color(role).contrastRatio(against: plate) >= 4.5, "\(role) at \(opacity)")
            }
        }
    }

    /// Below it, every glyph's opaque outline carries it: each text role
    /// clears 4.5:1 against the outline drawn round it, whatever is behind.
    @Test func test_below_the_default_the_outline_carries_the_contrast() {
        let outline = theme.plate.withAlpha(1)

        for role in OverlayTheme.TextRole.allCases {
            #expect(theme.color(role).contrastRatio(against: outline) >= 4.5, "\(role)")
        }
    }

    /// With no plate over white footage, the digits are still ringed by a dark
    /// outline that they clear 4.5:1 against, as rasterised.
    @Test func test_with_no_plate_the_digits_keep_their_outline_over_white_footage() throws {
        let context = OverlayRenderFixture.context(.speed, theme: theme.withPlateOpacity(0))
        let layout = speed.layout(in: context)
        let overlay = OverlayRenderFixture.render(speed, OverlayRenderFixture.midLap, context: context)
        let image = try #require(overlay.context.makeImage())
        let composite = OverlayBitmap(width: overlay.width, height: overlay.height)
        composite.context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        composite.context.fill(composite.bounds)
        composite.context.draw(image, in: composite.bounds)

        let colours = composite.positions(in: layout.value) { _ in true }.map { composite.pixel(at: $0).color }
        let darkest = try #require(colours.min { $0.relativeLuminance < $1.relativeLuminance })
        let inked = overlay.positions(in: layout.value) { $0.alpha == 255 }.map { composite.pixel(at: $0).color }
        let digits = try #require(inked.max { $0.relativeLuminance < $1.relativeLuminance })

        #expect(digits.contrastRatio(against: darkest) >= 4.5)
    }

    // MARK: - The editor

    /// The editor sets the HUD's opacity as one undoable step, held to range.
    @Test func test_the_editor_sets_the_opacity() {
        let editor = OverlayEditorModel(layout: layout(opacity: 0.88))

        editor.setPlateOpacity(0.5)
        #expect(editor.layout.plateOpacity == 0.5)
        editor.setPlateOpacity(3)
        #expect(editor.layout.plateOpacity == 1)

        editor.undo()
        #expect(editor.layout.plateOpacity == 0.5)
    }

    /// Dragging the slider moves the HUD live and records the whole drag as
    /// one step, which the window hears once, at its end.
    @Test func test_a_slider_drag_is_one_step() {
        let editor = OverlayEditorModel(layout: layout(opacity: 0.88))
        var heard: [Double] = []
        editor.onCommit = { heard.append($0.plateOpacity) }

        editor.beginGesture()
        editor.setPlateOpacity(0.7)
        editor.setPlateOpacity(0.4)
        #expect(editor.layout.plateOpacity == 0.4)
        #expect(heard.isEmpty)
        editor.endGesture()

        #expect(heard == [0.4])
        editor.undo()
        #expect(editor.layout.plateOpacity == 0.88)
    }
}
