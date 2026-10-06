import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for the issue 9.8 ``SyncStatus/autoAudio(confidence:)`` status: an
/// alignment proposed from engine sound and confirmed by the operator. It is
/// added **without a schema bump** — older builds read it as not synced through
/// the lenient status decode, never failing to open the workspace.
@Suite struct SyncStatusAutoAudioTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")
    private let bookmark = Data("/tmp/onboard/session-lap.mp4".utf8)

    // MARK: - Label

    /// The status line says the footage was synced from engine sound, and how
    /// confident the match was.
    @Test func test_auto_audio_status_reads_with_its_confidence() {
        let status = SyncStatus.autoAudio(confidence: 0.87)

        #expect(status.label(locale: en) == "Synced from engine sound (87%)")
        #expect(status.label(locale: ptBR) == "Sincronizado pelo som do motor (87%)")
    }

    // MARK: - Persistence

    /// The on-disk form is the readable kind plus the confidence.
    @Test func test_auto_audio_encodes_as_a_kind_and_a_confidence() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys

        let json = String(bytes: try encoder.encode(SyncStatus.autoAudio(confidence: 0.5)), encoding: .utf8)

        #expect(json == #"{"confidence":0.5,"kind":"autoAudio"}"#)
    }

    /// The status survives an encode/decode round trip, at either end of its range.
    @Test(arguments: [0.0, 0.42, 1.0])
    func test_auto_audio_roundtrips_through_codable(confidence: Double) throws {
        let status = SyncStatus.autoAudio(confidence: confidence)

        let data = try JSONEncoder().encode(status)

        #expect(try JSONDecoder().decode(SyncStatus.self, from: data) == status)
    }

    /// A missing or out-of-range confidence is a decode error, never a
    /// fabricated certainty.
    @Test(arguments: [#"{"kind":"autoAudio"}"#, #"{"kind":"autoAudio","confidence":1.5}"#,
                      #"{"kind":"autoAudio","confidence":-0.1}"#, #"{"kind":"autoAudio","confidence":"high"}"#])
    func test_malformed_auto_audio_fails_to_decode(json: String) {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SyncStatus.self, from: Data(json.utf8))
        }
    }

    /// A corrupt auto-audio status is cosmetic: the attachment still opens, as
    /// not synced, with its offset intact.
    @Test func test_a_malformed_auto_audio_attachment_opens_as_not_synced() throws {
        let json = #"{"bookmark": "\#(bookmark.base64EncodedString())", "displayName": "a.mp4", "offset": -9.46, "#
            + #""rate": 1, "status": {"kind": "autoAudio", "confidence": 7}}"#

        let decoded = try JSONDecoder().decode(VideoAttachment.self, from: Data(json.utf8))

        #expect(decoded.status == .notSynced)
        #expect(decoded.offset == -9.46)
    }

    /// Save → reopen restores an auto-audio sync, on the current schema.
    @Test func test_auto_audio_survives_a_project_roundtrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rsaudio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("auto.rsproj")
        let video = VideoAttachment(bookmark: bookmark, displayName: "session-lap.mp4", offset: -113.632,
                                    rate: 1, status: .autoAudio(confidence: 0.91))
        let store = ProjectStore(validator: FakeExpressionValidator())

        try store.save(ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time), video: video), to: url)
        let loaded = try store.load(from: url)

        #expect(loaded.video == video)
    }

    /// What a build from before issue 9.8 does with the new status: its status
    /// decoder knows only the 9.7 kinds, so `autoAudio` fails to decode and the
    /// attachment's lenient decode reads the footage as not synced — the
    /// workspace still opens, offset and all. Modelled on the 9.7 decoder.
    @Test func test_an_older_build_reads_auto_audio_as_not_synced() throws {
        let saved = VideoAttachment(bookmark: bookmark, displayName: "a.mp4", offset: -9.46,
                                    rate: 1, status: .autoAudio(confidence: 0.8))

        let legacy = try JSONDecoder().decode(LegacyAttachment.self, from: try JSONEncoder().encode(saved))

        #expect(legacy.status == .notSynced)
        #expect(legacy.offset == -9.46)
    }
}

/// The 9.7 attachment decode, frozen: its lenient `try?` status decode over the
/// four 9.7 kinds.
private struct LegacyAttachment: Decodable {
    enum Status: String, Decodable { case notSynced, estimated, anchored, twoPoint }
    private struct StatusBox: Decodable { let kind: Status }
    private enum CodingKeys: String, CodingKey { case offset, status }

    let offset: Double
    let status: Status

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offset = try container.decode(Double.self, forKey: .offset)
        status = (try? container.decodeIfPresent(StatusBox.self, forKey: .status))?.kind ?? .notSynced
    }
}
