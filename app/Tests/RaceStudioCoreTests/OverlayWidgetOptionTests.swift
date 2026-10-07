import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the overlay editor's per-widget options (issue 9.12): which
/// settings each kind of widget offers — the pedals' full scales among them,
/// the #188 follow-up — and setting one as an undoable, validated step.
@MainActor
@Suite struct OverlayWidgetOptionTests {

    /// Each kind offers exactly the settings it draws with.
    @Test func test_each_kind_offers_the_options_it_draws_with() {
        #expect(OverlayWidgetKind.pedals.editableOptions == [.throttleFullScale, .brakeFullScale])
        #expect(OverlayWidgetKind.rpm.editableOptions == [.maxRPM, .shiftLightRPM])
        #expect(OverlayWidgetKind.delta.editableOptions == [.deltaRange])
        #expect(OverlayWidgetKind.gForce.editableOptions == [.gForceMax])
        #expect(OverlayWidgetKind.trackMap.editableOptions == [.trackMapRotation])
        #expect(OverlayWidgetKind.speed.editableOptions.isEmpty)
        #expect(OverlayWidgetKind.channelValue(.role(.rpm)).editableOptions.isEmpty)
    }

    /// Every option is offered by some kind, reads and writes its own setting,
    /// and is named in both languages.
    @Test func test_every_option_is_named_and_bound_to_its_setting() {
        let kinds: [OverlayWidgetKind] = [.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap,
                                          .pedals, .temperature, .sectorTimes, .kartBadge, .sessionInfo]
        #expect(Set(kinds.flatMap(\.editableOptions)) == Set(OverlayWidgetOption.allCases))
        for option in OverlayWidgetOption.allCases {
            var options = OverlayWidgetOptions()
            options[keyPath: option.keyPath] = 1.5
            #expect(options[keyPath: option.keyPath] == 1.5)
            for locale in [Locale(identifier: "en_US"), Locale(identifier: "pt_BR")] {
                #expect(!L10n.isFlagged(option.title(locale: locale)))
            }
        }
        #expect(OverlayWidgetOption.brakeFullScale.title(locale: Locale(identifier: "en_US")) == "Brake full scale")
    }

    /// Setting one option stores it validated, as one undoable step.
    @Test func test_setting_an_option_is_validated_and_undoable() {
        let editor = OverlayEditorFixture.editor()

        editor.setOption(.brakeFullScale, to: 40, for: "pedals")
        editor.setOption(.throttleFullScale, to: 1e9, for: "pedals")

        let options = editor.layout.widgets.first { $0.id == "pedals" }?.options
        #expect(options?.brakeFullScale == 40)
        #expect(options?.throttleFullScale == OverlayWidgetOptions.pedalFullScaleLimits.upperBound)
        editor.undo()
        #expect(editor.layout.widgets.first { $0.id == "pedals" }?.options.throttleFullScale == 100)
    }

    /// An option set on a widget the layout lacks changes nothing.
    @Test func test_an_option_on_an_unknown_widget_changes_nothing() {
        let editor = OverlayEditorFixture.editor()

        editor.setOption(.maxRPM, to: 9_000, for: "laser")

        #expect(!editor.canUndo)
    }
}
