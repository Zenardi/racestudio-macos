import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for the HUD's background opacity (issue 9.24) from the review of its
/// first cut: the export's presets keep it, a slider drag stays one step
/// whatever happens mid-drag, a closed window keeps it, and as the plate fades
/// the text's outline and the guides get stronger.
@MainActor
@Suite struct PlateOpacityReviewTests: WorkspaceAutosaveFixture {

    // MARK: - Fixture (no logic — fixed layouts)

    private let english = Locale(identifier: "en")
    private let theme = OverlayTheme.raceStudio

    private func hud(opacity: Double) -> OverlayLayout {
        var layout = OverlayPreset.minimal.layout(locale: english)
        layout.plateOpacity = opacity
        return layout
    }

    // MARK: - The export

    /// A built-in preset chosen in the export sheet is drawn with the HUD's
    /// background opacity; without a HUD, with the default.
    @Test func test_the_export_presets_keep_the_huds_opacity() {
        let preset = ExportPreferences(overlay: .preset(.kartCoaching))
        let withHUD = ExportSheetFixture.model(workspaceOverlay: hud(opacity: 0.3), preferences: preset)
        let withoutHUD = ExportSheetFixture.model(workspaceOverlay: nil, preferences: preset)

        #expect(withHUD.layout(locale: english).plateOpacity == 0.3)
        #expect(withoutHUD.layout(locale: english).plateOpacity == OverlayLayout.defaultPlateOpacity)
    }

    /// Applying a preset in the editor keeps the HUD's background opacity, as
    /// it keeps the units and the theme.
    @Test func test_applying_a_preset_keeps_the_background_opacity() {
        let editor = OverlayEditorModel(layout: hud(opacity: 0.3))

        editor.apply(hud(opacity: 0.6))

        #expect(editor.layout.plateOpacity == 0.3)
    }

    // MARK: - The slider

    /// An undo in the middle of a slider drag doesn't split the rest of the
    /// drag into a step per tick: it is still one step.
    @Test func test_an_undo_mid_drag_keeps_the_rest_of_the_drag_one_step() {
        let editor = OverlayEditorModel(layout: hud(opacity: 0.88))

        editor.beginPlateAdjustment()
        editor.setPlateOpacity(0.7)
        editor.undo()
        editor.setPlateOpacity(0.5)
        editor.setPlateOpacity(0.4)
        editor.endPlateAdjustment()

        #expect(editor.layout.plateOpacity == 0.4)
        editor.undo()
        #expect(editor.layout.plateOpacity == 0.88)
    }

    /// A widget drag started while a slider drag is still open records the
    /// slider's change as its own step first.
    @Test func test_a_widget_drag_after_an_open_slider_drag_records_both() throws {
        let editor = OverlayEditorModel(layout: hud(opacity: 0.88))
        let frame = try #require(editor.layout.widgets.first { $0.id == "speed" }?.frame)
        editor.select("speed")

        editor.beginPlateAdjustment()
        editor.setPlateOpacity(0.5)
        editor.beginGesture()
        editor.drag(by: CGSize(width: 0.05, height: 0))
        editor.endGesture()

        editor.undo()
        #expect(editor.layout.widgets.first { $0.id == "speed" }?.frame == frame)
        #expect(editor.layout.plateOpacity == 0.5)
        editor.undo()
        #expect(editor.layout.plateOpacity == 0.88)
    }

    /// Closing the session mid-drag keeps the opacity — in the workspace and
    /// in the last HUD.
    @Test func test_closing_mid_drag_keeps_the_opacity() async throws {
        let dir = try makeTempDir()
        let last = LastOverlayStore(directory: dir)
        let window = window()
        let saver = WorkspaceAutosave(store: store(in: dir), lastOverlay: last, scheduler: ManualScheduler())
        await saver.open(window.parts)

        window.overlay.beginPlateAdjustment()
        window.overlay.setPlateOpacity(0.4)
        saver.flush()

        #expect(saved(in: dir)?.overlay?.plateOpacity == 0.4)
        #expect(last.load()?.plateOpacity == 0.4)
    }

    // MARK: - The theme and the renderer

    /// The layout's opacity wins over a theme handed to the renderer.
    @Test func test_the_renderer_takes_the_layouts_opacity_over_a_themes() {
        let renderer = OverlayRenderer(layout: hud(opacity: 0.6), theme: theme.withPlateOpacity(0.3),
                                       session: OverlayRenderFixture.session())

        #expect(renderer.theme.translucentPlateOpacity == 0.6)
    }

    /// A theme holds its opacity in range, as the layout does.
    @Test(arguments: zip([2, -1, .nan, 0.456], [1, 0, OverlayLayout.defaultPlateOpacity, 0.46]))
    func test_the_theme_holds_its_opacity_in_range(given: Double, kept: Double) {
        #expect(theme.withPlateOpacity(given).translucentPlateOpacity == kept)
    }

    /// The last HUD keeps its opacity.
    @Test func test_the_last_hud_keeps_its_opacity() throws {
        let last = LastOverlayStore(directory: try makeTempDir())

        try last.save(hud(opacity: 0.4))

        #expect(last.load()?.plateOpacity == 0.4)
    }

    // MARK: - Fading

    /// As a translucent plate fades below the default, the outline round the
    /// text thickens — twice as thick with no plate; solid plates and widgets
    /// without one keep theirs.
    @Test(arguments: zip([0.88, 1, 0.44, 0], [1, 1, 1.5, 2] as [CGFloat]))
    func test_as_the_plate_fades_the_outline_thickens(opacity: Double, factor: CGFloat) {
        let faded = OverlayRenderFixture.context(.speed, theme: theme.withPlateOpacity(opacity))
        let solid = OverlayRenderFixture.context(.speed, plate: .solid, theme: theme.withPlateOpacity(opacity))
        let bare = OverlayRenderFixture.context(.speed, plate: .none, theme: theme.withPlateOpacity(opacity))

        #expect(abs(faded.outline - factor) < 1e-9)
        #expect(solid.outline == 1 && bare.outline == 1)
    }

    /// As the plate fades, unlit bars and guides get stronger, so they still
    /// show over bright footage.
    @Test(arguments: zip([0.88, 0.44, 0], [0.35, 0.525, 0.7]))
    func test_as_the_plate_fades_the_guides_strengthen(opacity: Double, alpha: Double) {
        let context = OverlayRenderFixture.context(.rpm, theme: theme.withPlateOpacity(opacity))

        #expect(abs(context.palette.guide.alpha - alpha) < 1e-9)
    }
}
