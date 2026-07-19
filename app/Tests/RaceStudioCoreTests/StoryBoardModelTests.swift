import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for the StoryBoard lap strip (issue 8.13): the `StoryBoardModel` cards
/// derived from the lap selection (shown laps in order, reference marked), the
/// `LapSelectionModel` reorder primitive, and the `AnalysisWindowModel` reorder
/// that makes every panel reflect the new lap order.
@Suite struct StoryBoardModelTests {

    private func laps() -> [Lap] {
        (0..<4).map { Lap(index: UInt32($0), startTimeS: Double($0) * 5, durationS: 5, endTimeS: Double($0) * 5 + 5) }
    }

    // MARK: - StoryBoardModel cards

    @Test func test_cards_are_the_selected_laps_in_order_with_one_based_labels() {
        let selection = LapSelectionModel(selected: [LapID(2), LapID(0)], reference: LapID(2))
        let board = StoryBoardModel(selection: selection, laps: laps())
        #expect(board.cards.map(\.lap) == [LapID(2), LapID(0)], "selection order is preserved")
        #expect(board.cards.map(\.label) == ["Lap 3", "Lap 1"], "labels are one-based")
    }

    @Test func test_the_reference_card_is_the_only_one_marked() {
        let selection = LapSelectionModel(selected: [LapID(0), LapID(1), LapID(2)], reference: LapID(1))
        let board = StoryBoardModel(selection: selection, laps: laps())
        #expect(board.cards.filter(\.isReference).map(\.lap) == [LapID(1)])
    }

    @Test func test_no_selection_yields_no_cards() {
        #expect(StoryBoardModel(selection: LapSelectionModel(), laps: laps()).cards.isEmpty)
    }

    @Test func test_card_id_is_the_lap_index_so_it_is_reorder_stable() {
        let board = StoryBoardModel(selection: LapSelectionModel(selected: [LapID(2)]), laps: laps())
        #expect(board.cards.first?.id == 2)
    }

    // MARK: - LapSelectionModel reorder

    @Test func test_move_reorders_the_selection_without_touching_the_reference() {
        var selection = LapSelectionModel(selected: [LapID(0), LapID(1), LapID(2)], reference: LapID(1))
        selection.move(from: 0, to: 2)
        #expect(selection.selected == [LapID(1), LapID(2), LapID(0)])
        #expect(selection.reference == LapID(1), "the reference lap is unchanged by a reorder")
    }

    @Test func test_move_clamps_the_destination_into_range() {
        var selection = LapSelectionModel(selected: [LapID(0), LapID(1), LapID(2)])
        selection.move(from: 0, to: 99)
        #expect(selection.selected == [LapID(1), LapID(2), LapID(0)])
    }

    @Test func test_move_from_an_invalid_index_is_a_noop() {
        var selection = LapSelectionModel(selected: [LapID(0), LapID(1)])
        selection.move(from: 5, to: 0)
        #expect(selection.selected == [LapID(0), LapID(1)])
    }

    // MARK: - AnalysisWindowModel reorder makes panels follow

    @MainActor
    @Test func test_reordering_a_lap_reorders_the_selection_and_the_readout_columns() {
        let session = Session(
            metadata: SessionMetadata(vehicle: "SFJ", track: "Fuji", driver: "CMD",
                                      session: "", series: "", logDate: "", logTime: "", datetimeUtc: 0),
            channels: [Channel(name: "Speed", unit: "", sampleRateHz: 10, decimals: 0, sampleCount: 10)],
            laps: laps())
        let model = AnalysisWindowModel(session: session, analysis: nil)
        model.setSelection(channelNames: ["Speed"], lapIndices: [0, 1, 2], reference: 0)

        model.reorderSelectedLap(from: 0, to: 2)

        #expect(model.selection.laps.selected == [LapID(1), LapID(2), LapID(0)])
        #expect(model.readoutTable.columns == [LapID(1), LapID(2), LapID(0)],
                "the channel table columns follow the new lap order")
        #expect(model.selection.laps.reference == LapID(0), "the reference lap survives the reorder")
    }
}
