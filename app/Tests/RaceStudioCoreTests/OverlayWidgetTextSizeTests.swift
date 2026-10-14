import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Tests for a widget's text size (issue 9.21): a percentage, 50–200 %, that
/// makes the widget's numbers and labels bigger or smaller without changing
/// its box — saved with the layout, undoable in the editor, and never letting
/// text out of its place.
@MainActor
@Suite struct OverlayWidgetTextSizeTests {

    // MARK: - Fixture (no logic — fixed rects)

    /// A box with room to spare round the classic speed's digits.
    private let roomy = CGRect(x: 0, y: 0, width: 600, height: 300)
    /// A wide box with room to spare round the classic RPM's digits.
    private let wide = CGRect(x: 0, y: 0, width: 800, height: 200)

    private func speed(textSize: Double, sizeClass: OverlaySizeClass = .medium) -> SpeedWidget.Layout {
        SpeedWidget().layout(in: OverlayRenderFixture.context(.speed, rect: roomy, sizeClass: sizeClass,
                                                              textSize: textSize))
    }

    private func layout(textSize: Double) -> OverlayLayout {
        OverlayLayout(name: "Sized", widgets: [
            OverlayWidget(kind: .speed, frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2),
                          textSize: textSize)
        ])
    }

    // MARK: - The setting

    /// A widget draws its text at 100 % until it is changed.
    @Test func test_a_new_widget_draws_its_text_at_100_percent() {
        #expect(OverlayWidget(kind: .speed, frame: .unit).textSize == 1)
        #expect(OverlayWidget.textSizes == 0.5...2)
    }

    /// The text size stays between 50 % and 200 %; a size that isn't a number
    /// reads as 100 %.
    @Test(arguments: zip([0.2, 3, -1, .nan, .infinity, -.infinity, 1.4], [0.5, 2, 0.5, 1, 2, 0.5, 1.4]))
    func test_the_text_size_is_kept_between_50_and_200_percent(given: Double, kept: Double) {
        #expect(layout(textSize: given).validated().widgets[0].textSize == kept)
    }

    /// The text size is saved with the layout and read back.
    @Test func test_the_text_size_is_saved_and_read_back() throws {
        let data = try JSONEncoder().encode(layout(textSize: 1.5))

        let decoded = try JSONDecoder().decode(OverlayLayout.self, from: data)

        #expect(decoded.widgets[0].textSize == 1.5)
        #expect(String(bytes: data, encoding: .utf8)?.contains(#""textSize":1.5"#) == true)
    }

    /// A layout saved before text sizes existed, or with one that can't be
    /// read, draws its text at 100 %; one out of range is held to it.
    @Test(arguments: zip(["", #", "textSize": "big""#, #", "textSize": 9"#], [1.0, 1, 2]))
    func test_an_older_or_unreadable_text_size_is_read_safely(extra: String, kept: Double) throws {
        let json = #"{"name": "Old", "widgets": [{"kind": {"type": "speed"}, "#
            + #""frame": {"x": 0.1, "y": 0.1, "width": 0.2, "height": 0.2}\#(extra)}]}"#

        let decoded = try JSONDecoder().decode(OverlayLayout.self, from: Data(json.utf8))

        #expect(decoded.widgets[0].textSize == kept)
    }

    // MARK: - Drawing

    /// At 100 % the text is exactly what it was.
    @Test func test_at_100_percent_the_text_is_unchanged() {
        let layout = speed(textSize: 1)
        let outline: CGFloat = 1

        let expected = OverlayTextStyle.fitting(height: layout.value.height, outline: outline)
            .shrunk(toFit: "888", width: layout.value.width - 2 * outline)

        #expect(layout.valueStyle.capHeight == expected.capHeight)
    }

    /// The text grows and shrinks by the text size where it has room.
    @Test(arguments: [0.5, 0.8, 1.2, 1.5])
    func test_the_text_follows_the_text_size(size: Double) {
        let base = speed(textSize: 1), sized = speed(textSize: size)

        #expect(abs(sized.valueStyle.capHeight / base.valueStyle.capHeight - CGFloat(size)) < 0.001)
        #expect(abs(sized.unitStyle.capHeight / base.unitStyle.capHeight - CGFloat(size)) < 0.001)
    }

    /// Growing, the text fills its place at most — it never spills into the
    /// next one.
    @Test func test_the_text_never_outgrows_its_place() {
        let base = speed(textSize: 1), largest = speed(textSize: 2)

        #expect(largest.valueStyle.capHeight > base.valueStyle.capHeight * 1.4)
        #expect(largest.valueStyle.capHeight <= largest.value.height - 2)
        #expect(largest.unitStyle.capHeight <= largest.unit.height - 2)
    }

    /// The size class and the text size multiply.
    @Test func test_the_size_class_and_the_text_size_multiply() {
        let medium = speed(textSize: 1), sized = speed(textSize: 1.5, sizeClass: .small)

        #expect(abs(sized.valueStyle.capHeight / medium.valueStyle.capHeight - 1.2) < 0.001)
    }

    /// The classic RPM's digits and label grow too.
    @Test func test_the_classic_rpm_text_grows() {
        let base = RPMWidget().layout(in: OverlayRenderFixture.context(.rpm, rect: wide))
        let sized = RPMWidget().layout(in: OverlayRenderFixture.context(.rpm, rect: wide, textSize: 1.5))

        #expect(abs(sized.valueStyle.capHeight / base.valueStyle.capHeight - 1.5) < 0.001)
        #expect(sized.labelStyle.capHeight > base.labelStyle.capHeight)
    }

    // MARK: - The editor

    /// The editor sets one widget's text size, as one undoable step the
    /// window hears.
    @Test func test_the_editor_sets_a_widgets_text_size() {
        let editor = OverlayEditorFixture.editor()
        var heard: [OverlayLayout] = []
        editor.onCommit = { heard.append($0) }

        editor.setTextSize(1.5, for: "speed")

        #expect(editor.layout.widgets.map(\.textSize) == [1.5, 1, 1, 1])
        #expect(heard.last == editor.layout)
        editor.undo()
        #expect(editor.layout.widgets.map(\.textSize) == [1, 1, 1, 1])
    }

    /// The editor keeps the text size in range, and ignores a widget it
    /// doesn't have.
    @Test func test_the_editor_keeps_the_text_size_in_range() {
        let editor = OverlayEditorFixture.editor()

        editor.setTextSize(5, for: "speed")
        editor.setTextSize(0.1, for: "gForce")
        editor.setTextSize(1.5, for: "ghost")

        #expect(editor.layout.widgets.map(\.textSize) == [2, 0.5, 1, 1])
    }

    /// Five steps of 10 % save as 150 %, not as the sum's rounding error.
    @Test func test_steps_of_ten_percent_save_as_whole_percent() {
        let editor = OverlayEditorFixture.editor()
        let steps = [Double](repeating: 0.1, count: 5)

        editor.setTextSize(steps.reduce(1, +), for: "speed")

        #expect(editor.layout.widgets[0].textSize == 1.5)
    }
}
