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
        let cells = model().cells(at: WorkspaceCursor(x: 50))
        #expect(cells.count == 2, "a row per channel")
        #expect(cells.allSatisfy { $0.count == 2 }, "a column per lap")
        // Row/column order follows the selection order.
        #expect(cells[0][0].channel == rpm && cells[0][0].lap == lap0)
        #expect(cells[1][1].channel == speed && cells[1][1].lap == lap1)
        // Value-at-cursor is filled for present cells (x=50 → halfway → 15).
        #expect(cells[0][0].readout?.value == 15)
    }

    @Test func test_missing_channel_yields_no_data_cell() {
        let cells = model().cells(at: WorkspaceCursor(x: 50))
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
            .cells(at: WorkspaceCursor(x: 0)).isEmpty)
        // …or empty lap selection → empty table, no error.
        #expect(ReadoutTableModel(rows: [rpm], columns: [], series: series)
            .cells(at: WorkspaceCursor(x: 0)).isEmpty)
    }

    @Test func test_cell_identity_is_stable_across_cursor_moves() {
        let table = model()
        let atA = table.cells(at: WorkspaceCursor(x: 25))
        let atB = table.cells(at: WorkspaceCursor(x: 75))

        // Same grid identity regardless of cursor — smooth SwiftUI diffing.
        let idsA = atA.map { $0.map(\.id) }
        let idsB = atB.map { $0.map(\.id) }
        #expect(idsA == idsB)
        // But the values differ as the cursor moves.
        #expect(atA[0][0].readout?.value != atB[0][0].readout?.value)
    }
}
