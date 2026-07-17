import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `SectorModel` (issue 4.3) — sector / mini-sector partitioning.
@Suite struct SectorModelTests {

    @Test func test_sectors_partition_lap_without_gaps() throws {
        let model = SectorModel(lapDistance: 3000)
        let sectors = model.boundaries(splits: 3)

        #expect(sectors.count == 3)
        #expect(abs(try #require(sectors.first).lowerBound - 0) < 1e-9)
        #expect(abs(try #require(sectors.last).upperBound - 3000) < 1e-9)

        // Contiguous (each ends where the next begins) and equal length.
        for i in 1..<sectors.count {
            #expect(abs(sectors[i].lowerBound - sectors[i - 1].upperBound) < 1e-9)
        }
        for sector in sectors {
            #expect(abs((sector.upperBound - sector.lowerBound) - 1000) < 1e-9)
        }

        // Invalid splits / degenerate lap → empty.
        #expect(model.boundaries(splits: 0).isEmpty)
        #expect(SectorModel(lapDistance: 0).boundaries(splits: 3).isEmpty)
    }

    @Test func test_mini_sectors_subdivide_evenly() throws {
        let model = SectorModel(lapDistance: 1000)
        let minis = model.miniSectors(count: 10)

        #expect(minis.count == 10)
        // The boundaries at 0 and lap-end appear exactly once.
        #expect(abs(try #require(minis.first).lowerBound - 0) < 1e-9)
        #expect(abs(try #require(minis.last).upperBound - 1000) < 1e-9)

        for mini in minis {
            #expect(abs((mini.upperBound - mini.lowerBound) - 100) < 1e-9)
        }
        for i in 1..<minis.count {
            #expect(abs(minis[i].lowerBound - minis[i - 1].upperBound) < 1e-9)
        }

        #expect(model.miniSectors(count: 0).isEmpty)
    }

    @Test func test_sector_index_for_distance() {
        let model = SectorModel(lapDistance: 3000)
        #expect(model.sectorIndex(forDistance: 0, splits: 3) == 0)
        #expect(model.sectorIndex(forDistance: 1500, splits: 3) == 1)
        #expect(model.sectorIndex(forDistance: 2999, splits: 3) == 2)
        // The lap-end distance belongs to the final sector, not a phantom one.
        #expect(model.sectorIndex(forDistance: 3000, splits: 3) == 2)

        // Out of range / invalid splits → nil.
        #expect(model.sectorIndex(forDistance: -1, splits: 3) == nil)
        #expect(model.sectorIndex(forDistance: 3001, splits: 3) == nil)
        #expect(model.sectorIndex(forDistance: 100, splits: 0) == nil)
    }
}
