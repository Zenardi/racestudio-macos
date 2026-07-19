import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `ReadoutTableModel` (issue 4.4) — the channels × laps grid.
@Suite struct ReadoutTableModelTests {

    private let rpm = ChannelID("RPM")
    private let speed = ChannelID("Speed")
    private let lap0 = LapID(0)
    private let lap1 = LapID(1)

    /// A model where lap 0 has both channels but lap 1 is missing Speed.
    private func model() -> ReadoutTableModel {
        let series = ChannelSeries(xs: [0, 100], values: [10, 20])
        return ReadoutTableModel(
            rows: [rpm, speed],
            columns: [lap0, lap1],
            series: [
                CellKey(channel: rpm, lap: lap0): series,
                CellKey(channel: rpm, lap: lap1): series,
                CellKey(channel: speed, lap: lap0): series
                // (speed, lap1) intentionally missing
            ])
    }

    @Test func test_table_has_row_per_channel_column_per_lap() {
        let cells = model().cells(atX: 50)
        #expect(cells.count == 2, "a row per channel")
        #expect(cells.allSatisfy { $0.count == 2 }, "a column per lap")
        // Row/column order follows the selection order.
        #expect(cells[0][0].channel == rpm && cells[0][0].lap == lap0)
        #expect(cells[1][1].channel == speed && cells[1][1].lap == lap1)
        // Value-at-cursor is filled for present cells (x=50 → halfway → 15).
        #expect(cells[0][0].readout?.value == 15)
    }

    @Test func test_missing_channel_yields_no_data_cell() {
        let cells = model().cells(atX: 50)
        let missing = cells[1][1] // (speed, lap1)
        #expect(missing.hasData == false)
        #expect(missing.readout == nil)
        // A present cell has data.
        #expect(cells[1][0].hasData == true)
    }

    @Test func test_empty_selection_returns_empty_table() {
        let series = [CellKey(channel: rpm, lap: lap0): ChannelSeries(xs: [0], values: [1])]
        // Empty channel list…
        #expect(ReadoutTableModel(rows: [], columns: [lap0], series: series)
            .cells(atX: 0).isEmpty)
        // …or empty lap selection → empty table, no error.
        #expect(ReadoutTableModel(rows: [rpm], columns: [], series: series)
            .cells(atX: 0).isEmpty)
    }

    @Test func test_model_deduplicates_rows_and_columns() {
        // Duplicate rows/columns would collide ReadoutCell.id and break SwiftUI
        // diffing — the model drops later duplicates, keeping first order.
        let model = ReadoutTableModel(
            rows: [rpm, speed, rpm],
            columns: [lap0, lap1, lap0],
            series: [:])
        #expect(model.rows == [rpm, speed])
        #expect(model.columns == [lap0, lap1])

        let cells = model.cells(atX: 0)
        let ids = cells.flatMap { $0.map(\.id) }
        #expect(Set(ids).count == ids.count, "every cell id is unique")
    }

    @Test func test_cell_identity_is_stable_across_cursor_moves() {
        let table = model()
        let atA = table.cells(atX: 25)
        let atB = table.cells(atX: 75)

        // Same grid identity regardless of cursor — smooth SwiftUI diffing.
        let idsA = atA.map { $0.map(\.id) }
        let idsB = atB.map { $0.map(\.id) }
        #expect(idsA == idsB)
        // But the values differ as the cursor moves.
        #expect(atA[0][0].readout?.value != atB[0][0].readout?.value)
    }

    // MARK: - Reference deltas (issue 8.5)

    /// A model whose laps carry distinct values so a delta is unambiguous:
    /// lap 0 reads 15, lap 1 reads 40 for RPM; Speed reads 150 for lap 0 and has
    /// no data for lap 1.
    private func deltaModel() -> ReadoutTableModel {
        ReadoutTableModel(
            rows: [rpm, speed],
            columns: [lap0, lap1],
            series: [
                CellKey(channel: rpm, lap: lap0): ChannelSeries(xs: [0, 100], values: [10, 20]),   // @50 → 15
                CellKey(channel: rpm, lap: lap1): ChannelSeries(xs: [0, 100], values: [30, 50]),    // @50 → 40
                CellKey(channel: speed, lap: lap0): ChannelSeries(xs: [0, 100], values: [100, 200]) // @50 → 150
                // (speed, lap1) intentionally missing
            ])
    }

    @Test func test_delta_cells_report_value_minus_the_reference_lap() {
        let rows = deltaModel().deltaCells(atX: 50, reference: lap0)
        // The reference column carries no delta (it is the baseline).
        #expect(rows[0][0].delta == nil)
        // RPM lap 1 is 40 vs the lap-0 baseline 15 → +25.
        #expect(rows[0][1].delta == 25)
        // The underlying value-at-cursor is preserved alongside the delta.
        #expect(rows[0][1].cell.readout?.value == 40)
    }

    @Test func test_delta_cells_have_no_delta_without_a_reference() {
        let rows = deltaModel().deltaCells(atX: 50, reference: nil)
        #expect(rows.flatMap { $0 }.allSatisfy { $0.delta == nil })
        // …yet still carry the value-at-cursor, so the grid still renders.
        #expect(rows[0][0].cell.readout?.value == 15)
    }

    @Test func test_delta_is_absent_when_either_side_has_no_data() {
        let rows = deltaModel().deltaCells(atX: 50, reference: lap0)
        // Speed lap 1 has no data → no delta even though the baseline exists.
        #expect(rows[1][1].delta == nil)
        #expect(rows[1][1].cell.hasData == false)

        // With the missing lap as the reference, the whole Speed row loses its
        // baseline, so no delta survives.
        let vsMissing = deltaModel().deltaCells(atX: 50, reference: lap1)
        #expect(vsMissing[1][0].delta == nil)
    }

    @Test func test_delta_grid_shape_and_identity_match_the_cells() {
        let cells = deltaModel().cells(atX: 50)
        let deltas = deltaModel().deltaCells(atX: 50, reference: lap0)
        #expect(deltas.map { $0.count } == cells.map { $0.count })
        #expect(deltas.map { $0.map(\.id) } == cells.map { $0.map(\.id) })
    }
}
