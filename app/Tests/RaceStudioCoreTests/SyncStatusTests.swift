import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.7 sync **status** and **coverage summary**: the panel's
/// status line — e.g. "Synced on lap 3 + lap 14 · footage covers laps 2–15
/// (14 of 16)" — so the operator can see how the footage was aligned and how
/// much of the session it actually covers.
@Suite struct SyncStatusTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    /// Sixteen one-minute laps from session time 0.
    private func sixteenLaps() -> LapSectorTimeline { VideoReviewFixture.sixteenLaps() }

    // MARK: - Coverage summary

    /// A clip that starts during lap 1 and stops during lap 16 fully covers laps
    /// 2–15: fourteen of sixteen.
    @Test func test_a_partial_clip_covers_the_laps_in_between() {
        let clip = VideoSyncModel(videoDuration: 860, offset: -50) // session 50…910

        let summary = CoverageSummary.make(timeline: sixteenLaps(), sync: clip)

        #expect(summary == CoverageSummary(firstLap: LapID(1), lastLap: LapID(14), coveredLaps: 14, totalLaps: 16))
        #expect(summary.label(locale: en) == "footage covers laps 2–15 (14 of 16)")
        #expect(summary.label(locale: ptBR) == "o vídeo cobre as voltas 2–15 (14 de 16)")
    }

    /// Footage that misses the session entirely covers nothing.
    @Test func test_footage_outside_the_session_covers_no_lap() {
        let summary = CoverageSummary.make(timeline: sixteenLaps(),
                                           sync: VideoSyncModel(videoDuration: 600, offset: -5_000))

        #expect(summary == CoverageSummary(firstLap: nil, lastLap: nil, coveredLaps: 0, totalLaps: 16))
        #expect(summary.label(locale: en) == "footage covers no laps")
        #expect(summary.label(locale: ptBR) == "o vídeo não cobre nenhuma volta")
    }

    /// Footage running the whole session covers every lap.
    @Test func test_full_footage_covers_every_lap() {
        let summary = CoverageSummary.make(timeline: sixteenLaps(), sync: VideoSyncModel(videoDuration: 1_000))

        #expect(summary.coveredLaps == 16)
        #expect(summary.label(locale: en) == "footage covers laps 1–16 (16 of 16)")
    }

    /// A single covered lap reads in the singular.
    @Test func test_a_single_covered_lap_reads_in_the_singular() {
        let clip = VideoSyncModel(videoDuration: 70, offset: -175) // session 175…245: lap 4 only

        let summary = CoverageSummary.make(timeline: sixteenLaps(), sync: clip)

        #expect(summary.label(locale: en) == "footage covers lap 4 (1 of 16)")
        #expect(summary.label(locale: ptBR) == "o vídeo cobre a volta 4 (1 de 16)")
    }

    /// Coverage honours the clock rate: a fast camera clock pushes the last lap
    /// off the end of footage that would otherwise just hold it.
    @Test func test_coverage_summary_honours_the_rate() {
        let exact = VideoSyncModel(videoDuration: 960)
        let fast = VideoSyncModel(videoDuration: 960, rate: 1.001)

        #expect(CoverageSummary.make(timeline: sixteenLaps(), sync: exact).coveredLaps == 16)
        #expect(CoverageSummary.make(timeline: sixteenLaps(), sync: fast).lastLap == LapID(14))
    }

    /// No footage, or a session with no laps, covers nothing.
    @Test func test_no_footage_or_no_laps_covers_nothing() {
        let noFootage = CoverageSummary.make(timeline: sixteenLaps(), sync: VideoSyncModel(videoDuration: 0))
        let noLaps = CoverageSummary.make(timeline: .empty, sync: VideoSyncModel(videoDuration: 600))

        #expect(noFootage.coveredLaps == 0 && noFootage.totalLaps == 16)
        #expect(noLaps == CoverageSummary(firstLap: nil, lastLap: nil, coveredLaps: 0, totalLaps: 0))
        #expect(noLaps.label(locale: en) == "footage covers no laps")
    }

    // MARK: - Status labels

    /// Each status names how the footage was aligned, laps 1-based.
    @Test func test_status_labels_in_english() {
        #expect(SyncStatus.notSynced.label(locale: en) == "Not synced")
        #expect(SyncStatus.estimated.label(locale: en) == "Estimated from file date")
        #expect(SyncStatus.anchored(lap: LapID(2)).label(locale: en) == "Synced on lap 3")
        #expect(SyncStatus.anchored(lap: nil).label(locale: en) == "Synced by hand")
        #expect(SyncStatus.twoPoint(lapA: LapID(2), lapB: LapID(13)).label(locale: en)
                == "Synced on lap 3 + lap 14")
    }

    /// The same in Brazilian Portuguese.
    @Test func test_status_labels_in_portuguese() {
        #expect(SyncStatus.notSynced.label(locale: ptBR) == "Não sincronizado")
        #expect(SyncStatus.estimated.label(locale: ptBR) == "Estimado pela data do arquivo")
        #expect(SyncStatus.anchored(lap: LapID(2)).label(locale: ptBR) == "Sincronizado na volta 3")
        #expect(SyncStatus.anchored(lap: nil).label(locale: ptBR) == "Sincronizado manualmente")
        #expect(SyncStatus.twoPoint(lapA: LapID(2), lapB: LapID(13)).label(locale: ptBR)
                == "Sincronizado nas voltas 3 + 14")
    }

    /// The status line joins how the footage was synced with what it covers.
    @Test func test_status_line_joins_status_and_coverage() {
        let summary = CoverageSummary(firstLap: LapID(1), lastLap: LapID(14), coveredLaps: 14, totalLaps: 16)

        #expect(SyncStatus.twoPoint(lapA: LapID(2), lapB: LapID(13)).statusLine(coverage: summary, locale: en)
                == "Synced on lap 3 + lap 14 · footage covers laps 2–15 (14 of 16)")
    }

    // MARK: - Persistence

    /// Every status survives an encode/decode round trip.
    @Test(arguments: [SyncStatus.notSynced, .estimated, .anchored(lap: LapID(4)), .anchored(lap: nil),
                      .twoPoint(lapA: LapID(2), lapB: LapID(13))])
    func test_status_roundtrips_through_codable(status: SyncStatus) throws {
        let data = try JSONEncoder().encode(status)

        #expect(try JSONDecoder().decode(SyncStatus.self, from: data) == status)
    }

    /// The on-disk form is a readable kind plus 0-based lap indices.
    @Test func test_status_encodes_as_a_kind_and_lap_indices() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = String(bytes: try encoder.encode(SyncStatus.twoPoint(lapA: LapID(2), lapB: LapID(13))),
                          encoding: .utf8)

        #expect(json == #"{"kind":"twoPoint","lapA":2,"lapB":13}"#)
    }

    /// An unknown kind, or a two-point status missing a lap, is a decode error
    /// rather than a silently wrong status.
    @Test(arguments: [#"{"kind":"telepathic"}"#, #"{"kind":"twoPoint","lapA":2}"#, #"{"lap":3}"#,
                      #"{"kind":"anchored","lap":-1}"#, #"{"kind":"anchored","lap":9223372036854775807}"#,
                      #"{"kind":"twoPoint","lapA":-4,"lapB":3}"#, #"{"kind":"twoPoint","lapA":2,"lapB":2147483647}"#])
    func test_malformed_status_fails_to_decode(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SyncStatus.self, from: Data(json.utf8))
        }
    }
}
