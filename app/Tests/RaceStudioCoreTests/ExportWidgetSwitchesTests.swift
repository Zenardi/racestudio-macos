import Foundation
import Testing
@testable import RaceStudioCore

/// The export sheet's widget switches (issue 9.19): the chosen overlay's
/// widgets listed with an on/off switch each, applied to a copy of the layout
/// for this export only, remembered per overlay choice.
@MainActor
@Suite struct ExportWidgetSwitchesTests {

    private let english = Locale(identifier: "en")

    /// The workspace's overlay: Minimal plus a G-ball, pedals and a kart badge
    /// the operator hid in the overlay editor.
    private var workspace: OverlayLayout {
        var layout = OverlayPreset.minimal.layout(locale: english)
        layout.widgets += [
            OverlayWidget(kind: .gForce, frame: NormalizedRect(x: 0.03, y: 0.5, width: 0.14, height: 0.2)),
            OverlayWidget(kind: .pedals, frame: NormalizedRect(x: 0.2, y: 0.5, width: 0.06, height: 0.15)),
            OverlayWidget(kind: .kartBadge, frame: NormalizedRect(x: 0.03, y: 0.3, width: 0.24, height: 0.06),
                          isVisible: false)
        ]
        return layout
    }

    /// A session with every channel but the pedals', and no kart.
    private var sessionWithoutPedals: OverlaySessionContext {
        OverlayRenderFixture.session(
            channels: OverlayRenderFixture.channels.filter { !["Throttle", "Brake"].contains($0.name) }, kart: nil)
    }

    private func model(session: OverlaySessionContext? = nil,
                       preferences: ExportPreferences = ExportPreferences(overlay: .workspace)) -> ExportSheetModel {
        ExportSheetFixture.model(workspaceOverlay: workspace, overlaySession: session, preferences: preferences)
    }

    private func item(_ id: String, in model: ExportSheetModel) throws -> ExportWidgetItem {
        try #require(model.widgetItems.first { $0.id == id })
    }

    // MARK: - The list

    /// The sheet lists the chosen overlay's widgets in layout order, each
    /// named in the export language.
    @Test func test_the_sheet_lists_the_chosen_overlays_widgets() throws {
        let model = model()

        #expect(model.widgetItems.map(\.id) == workspace.widgets.map(\.id))
        #expect(try item("speed", in: model).title(locale: english) == "Speed")
        #expect(model.widgetItems.allSatisfy { $0.title(locale: english) == $0.kind.title(locale: english) })

        model.overlay = .preset(.fullTelemetry)

        #expect(model.widgetItems.map(\.id) == OverlayPreset.fullTelemetry.layout(locale: english).widgets.map(\.id))
    }

    /// Each switch starts in the widget's own state: off for the widget the
    /// overlay hides, on for the others.
    @Test func test_each_switch_starts_in_the_widgets_own_state() throws {
        let model = model()

        #expect(try item("kartBadge", in: model).isOn == false)
        #expect(model.widgetItems.filter { $0.id != "kartBadge" }.allSatisfy { $0.isOn })
    }

    // MARK: - The exported layout

    /// A widget switched off is left out of the export; every other widget is
    /// exactly as the overlay has it.
    @Test func test_a_switched_off_widget_is_left_out_and_the_rest_is_unchanged() throws {
        let model = model()

        model.setWidget("gForce", isOn: false)
        let layout = model.layout(locale: english)

        var expected = workspace
        expected.isEnabled = true
        expected.widgets[3].isVisible = false
        #expect(layout == expected)
        #expect(!layout.resolved(for: .widescreen).map(\.widget.id).contains("gForce"))
        #expect(try item("gForce", in: model).isOn == false)
    }

    /// A widget the overlay had hidden can be switched on: it is drawn in its
    /// place.
    @Test func test_a_widget_the_overlay_hid_can_be_switched_on() {
        let model = model(session: OverlayRenderFixture.session())

        model.setWidget("kartBadge", isOn: true)

        #expect(model.layout(locale: english).widgets.first { $0.id == "kartBadge" }?.isVisible == true)
        #expect(model.layout(locale: english).resolved(for: .widescreen).map(\.widget.id).contains("kartBadge"))
    }

    /// A widget the session can't feed is listed off, with its reason, and
    /// can't be switched on.
    @Test func test_a_widget_the_session_cannot_feed_is_off_with_its_reason() throws {
        let model = model(session: sessionWithoutPedals)

        model.setWidget("pedals", isOn: true)

        let pedals = try item("pedals", in: model)
        #expect(pedals.isOn == false && pedals.canSwitchOn == false)
        #expect(pedals.reason(locale: english)
            == OverlayAvailabilityReason.missingRoles(.throttle, .brake).label(locale: english))
        #expect(try item("speed", in: model).reason(locale: english) == nil)
        #expect(try item("speed", in: model).canSwitchOn)
    }

    // MARK: - Show all, hide all

    /// *Hide all* switches every widget off; *Show all* switches on every
    /// widget the session can feed.
    @Test func test_show_all_and_hide_all() throws {
        let model = model(session: sessionWithoutPedals)

        model.hideAllWidgets()
        #expect(model.widgetItems.allSatisfy { !$0.isOn })

        model.showAllWidgets()
        #expect(model.widgetItems.filter(\.canSwitchOn).allSatisfy { $0.isOn })
        #expect(try item("pedals", in: model).isOn == false)
        #expect(try item("kartBadge", in: model).isOn == false, "no kart: the badge can't be fed")
    }

    /// With every widget off the sheet says no overlay will be drawn, and the
    /// export still runs: the footage is cut with nothing over it.
    @Test func test_every_widget_off_still_exports_the_footage() throws {
        let model = model()
        #expect(model.noOverlayMessage(locale: english) == nil)

        model.hideAllWidgets()

        #expect(model.noOverlayMessage(locale: english) == "No overlay will be drawn: every widget is off.")
        #expect(model.canExport)
        #expect((try? model.makePlan().get()) != nil)
        #expect(model.layout(locale: english).resolved(for: .widescreen).isEmpty)
    }

    // MARK: - For this export only

    /// The switches change only the export's copy: the workspace's overlay and
    /// the built-in presets are untouched.
    @Test func test_the_workspace_overlay_and_the_presets_are_untouched() {
        let model = model()
        let input = ExportSheetFixture.input(workspaceOverlay: workspace)

        model.setWidget("gForce", isOn: false)
        model.overlay = .preset(.kartCoaching)
        model.setWidget("trackMap", isOn: false)

        #expect(input.workspaceOverlay == workspace)
        #expect(OverlayPreset.kartCoaching.layout(locale: english).widgets.allSatisfy { $0.isVisible })
        #expect(model.layout(locale: english).widgets.first { $0.id == "trackMap" }?.isVisible == false)
    }

    /// Each overlay choice keeps its own switches.
    @Test func test_the_switches_are_kept_per_overlay_choice() throws {
        let model = model()

        model.setWidget("speed", isOn: false)
        model.overlay = .preset(.minimal)

        #expect(try item("speed", in: model).isOn)

        model.overlay = .workspace

        #expect(try item("speed", in: model).isOn == false)
    }

    // MARK: - Remembered

    /// The switches are remembered per overlay choice, as the operator's
    /// changes from the overlay's own state.
    @Test func test_the_switches_are_remembered_per_overlay_choice() throws {
        let model = model()

        model.setWidget("gForce", isOn: false)
        model.setWidget("kartBadge", isOn: true)
        let reopened = self.model(preferences: model.preferences)

        #expect(model.preferences.widgetSwitches == [.workspace: ["gForce": false, "kartBadge": true]])
        #expect(try item("gForce", in: reopened).isOn == false)
        #expect(try item("kartBadge", in: reopened).isOn)
    }

    /// Switching a widget back to the overlay's own state forgets the switch,
    /// so the widget follows its overlay again.
    @Test func test_switching_back_to_the_overlays_own_state_forgets_the_switch() {
        let model = model()

        model.setWidget("gForce", isOn: false)
        model.setWidget("gForce", isOn: true)

        #expect(model.preferences.widgetSwitches.isEmpty)
    }

    /// A remembered switch for a widget the overlay no longer has is ignored.
    @Test func test_a_switch_for_a_widget_that_no_longer_exists_is_ignored() {
        let model = model(preferences: ExportPreferences(overlay: .workspace,
                                                         widgetSwitches: [.workspace: ["ghost": true]]))

        var expected = workspace
        expected.isEnabled = true
        #expect(model.layout(locale: english) == expected)
        #expect(model.widgetItems.map(\.id) == workspace.widgets.map(\.id))
    }
}
