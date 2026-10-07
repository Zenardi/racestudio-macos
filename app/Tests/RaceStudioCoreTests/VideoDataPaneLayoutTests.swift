import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `VideoDataPaneLayout` (issue 9.12): how the Video + Data panel
/// splits its space — the player beside the side column, the strip plot under
/// the player, the track map over the lap list — and which panes are shown. It
/// is persisted with the workspace, so it must survive a round-trip and read
/// leniently.
@Suite struct VideoDataPaneLayoutTests {

    // MARK: - Defaults

    /// A new workspace shows every pane, the player taking most of the width.
    @Test func test_default_layout_shows_every_pane() {
        let layout = VideoDataPaneLayout.default

        #expect(layout.isVisible(.plot))
        #expect(layout.isVisible(.map))
        #expect(layout.isVisible(.lapList))
        #expect(layout.showsSideColumn)
        #expect(layout.fraction(.side) == 0.34)
        #expect(layout.fraction(.plot) == 0.3)
        #expect(layout.fraction(.map) == 0.5)
    }

    // MARK: - Fractions

    /// A divider can't squeeze a pane to nothing nor push it off the panel.
    @Test(arguments: [(-1.0, 0.15), (0.05, 0.15), (0.5, 0.5), (0.95, 0.85), (3.0, 0.85)])
    func test_fractions_are_held_inside_their_limits(requested: Double, expected: Double) {
        var layout = VideoDataPaneLayout.default

        layout.setFraction(requested, for: .plot)

        #expect(layout.fraction(.plot) == expected)
    }

    /// A non-finite fraction is no position; the divider stays where it was.
    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func test_a_non_finite_fraction_is_ignored(value: Double) {
        var layout = VideoDataPaneLayout.default

        layout.setFraction(value, for: .map)

        #expect(layout.fraction(.map) == 0.5)
    }

    /// Dragging a divider moves it by its share of the length it splits, from
    /// where the drag began — not from wherever the last update left it.
    @Test func test_dragging_a_divider_moves_it_by_its_share_of_the_length() {
        var layout = VideoDataPaneLayout.default

        layout.drag(.side, from: 0.34, by: -100, across: 1_000)
        layout.drag(.side, from: 0.34, by: -160, across: 1_000)

        #expect(abs(layout.fraction(.side) - 0.5) < 1e-12, "the side column grows as the divider moves left")
    }

    /// The plot and map dividers grow the pane below them as they move up.
    @Test func test_dragging_the_plot_divider_up_grows_the_plot() {
        var layout = VideoDataPaneLayout.default

        layout.drag(.plot, from: 0.3, by: -50, across: 500)

        #expect(abs(layout.fraction(.plot) - 0.4) < 1e-12)
    }

    /// The map sits over the lap list, so its divider grows it moving down.
    @Test func test_dragging_the_map_divider_down_grows_the_map() {
        var layout = VideoDataPaneLayout.default

        layout.drag(.map, from: 0.5, by: 100, across: 1_000)

        #expect(abs(layout.fraction(.map) - 0.6) < 1e-12)
    }

    /// A drag across a pane with no length (not laid out yet) changes nothing.
    @Test(arguments: [0.0, -10.0, Double.nan])
    func test_a_drag_across_no_length_is_ignored(length: Double) {
        var layout = VideoDataPaneLayout.default

        layout.drag(.map, from: 0.5, by: 40, across: length)

        #expect(layout.fraction(.map) == 0.5)
    }

    // MARK: - Visibility

    /// Panes toggle independently, and the side column folds away only when
    /// both of its panes are hidden.
    @Test func test_hiding_both_side_panes_folds_the_side_column() {
        var layout = VideoDataPaneLayout.default

        layout.toggle(.map)
        #expect(!layout.isVisible(.map))
        #expect(layout.showsSideColumn, "the lap list still needs the column")

        layout.setVisible(false, for: .lapList)
        #expect(!layout.showsSideColumn)

        layout.toggle(.map)
        #expect(layout.isVisible(.map))
        #expect(layout.showsSideColumn)
    }

    /// Hiding the plot leaves the other panes and every fraction alone, so
    /// showing it again restores the split the operator left.
    @Test func test_hiding_a_pane_keeps_its_split() {
        var layout = VideoDataPaneLayout.default
        layout.setFraction(0.42, for: .plot)

        layout.setVisible(false, for: .plot)
        layout.setVisible(true, for: .plot)

        #expect(layout.fraction(.plot) == 0.42)
        #expect(layout.isVisible(.map) && layout.isVisible(.lapList))
    }

    // MARK: - Persistence

    /// A saved layout reads back exactly.
    @Test func test_round_trip_is_value_equal() throws {
        var layout = VideoDataPaneLayout.default
        layout.setFraction(0.4, for: .side)
        layout.setFraction(0.25, for: .plot)
        layout.setFraction(0.6, for: .map)
        layout.setVisible(false, for: .lapList)

        let data = try JSONEncoder().encode(layout)
        let decoded = try JSONDecoder().decode(VideoDataPaneLayout.self, from: data)

        #expect(decoded == layout)
    }

    /// An empty object is the default layout — what an older save carries.
    @Test func test_missing_keys_read_as_the_defaults() throws {
        let decoded = try JSONDecoder().decode(VideoDataPaneLayout.self, from: Data("{}".utf8))

        #expect(decoded == .default)
    }

    /// A hand-edited value costs only itself: a malformed one takes its
    /// default, an out-of-range one is clamped.
    @Test func test_malformed_values_read_leniently() throws {
        let json = #"{"side": "wide", "plot": 9, "map": 0.6, "showsMap": "no", "showsLapList": false}"#

        let decoded = try JSONDecoder().decode(VideoDataPaneLayout.self, from: Data(json.utf8))

        #expect(decoded.fraction(.side) == 0.34)
        #expect(decoded.fraction(.plot) == 0.85)
        #expect(decoded.fraction(.map) == 0.6)
        #expect(decoded.isVisible(.map))
        #expect(!decoded.isVisible(.lapList))
    }
}
