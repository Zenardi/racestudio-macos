import Testing
import Foundation
@testable import RaceStudioCore

/// Tests for `LibraryStore` (issue 5.3) — atomic on-disk persistence of the
/// session index, forward-compatible decode, corruption recovery, and
/// dangling-source detection.
///
/// Each test uses a private temp directory (repeatable, no global state); the
/// index clock is injected so persisted `importedAt` values round-trip exactly.
@Suite struct LibraryStoreTests {

    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)

    /// Signals a save interrupted mid-write (e.g. the process is killed).
    private enum TestCrash: Error { case interrupted }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("libstore-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func touch(_ url: URL) throws {
        try Data("x".utf8).write(to: url)
    }

    private func makeIndex() -> SessionIndex {
        SessionIndex(now: { Self.fixedNow })
    }

    // MARK: - round-trip

    @Test func test_save_load_roundtrip_is_value_equal() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        // Two present source files so availability stays true across load.
        let srcA = dir.appendingPathComponent("a.xrk"); try touch(srcA)
        let srcB = dir.appendingPathComponent("b.xrk"); try touch(srcB)

        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "Fuji GP Sh", datetimeUtc: 300), sourceURL: srcA)
        _ = index.add(SessionFixture.make(track: "Suzuka", datetimeUtc: 200, lapDurations: []), sourceURL: srcB)

        let store = LibraryStore()
        try store.save(index, to: url)
        let loaded = store.load(from: url)

        #expect(loaded == index)
    }

    @Test func test_is_available_is_not_persisted() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        let index = makeIndex()
        _ = index.add(SessionFixture.make(), sourceURL: dir.appendingPathComponent("s.xrk"))
        try LibraryStore().save(index, to: url)

        // isAvailable is transient (filesystem-derived, recomputed on load), so it
        // must not appear in the persisted JSON.
        let json = try #require(String(data: Data(contentsOf: url), encoding: .utf8))
        #expect(!json.contains("isAvailable"))
    }

    @Test func test_load_ignores_unknown_json_keys() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        let index = makeIndex()
        _ = index.add(SessionFixture.make(), sourceURL: dir.appendingPathComponent("s.xrk"))
        try LibraryStore().save(index, to: url)

        // Rewrite the file with extra keys, as a newer app version might.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        json["futureFeature"] = 42
        if var summaries = json["summaries"] as? [[String: Any]], !summaries.isEmpty {
            summaries[0]["unknownField"] = "x"
            json["summaries"] = summaries
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        #expect(LibraryStore().load(from: url).summaries.count == 1)
    }

    // MARK: - atomicity & failure paths

    @Test func test_atomic_save_survives_interruption() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        // A committed, good index.
        let good = makeIndex()
        _ = good.add(SessionFixture.make(track: "Committed"), sourceURL: dir.appendingPathComponent("g.xrk"))
        try LibraryStore().save(good, to: url)

        // A save that dies before it can commit its bytes.
        let crashing = LibraryStore(write: { _, _ in throw TestCrash.interrupted })
        let doomed = makeIndex()
        _ = doomed.add(SessionFixture.make(track: "Never"), sourceURL: dir.appendingPathComponent("n.xrk"))
        #expect(throws: LibraryError.ioFailure) { try crashing.save(doomed, to: url) }

        // The previously committed index is intact — never truncated or corrupt.
        #expect(LibraryStore().load(from: url).summaries.map(\.venue) == ["Committed"])
    }

    @Test func test_real_atomic_save_overwrites_cleanly() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        let store = LibraryStore()  // the real atomic Data.write path

        // Save a larger index, then overwrite with a smaller one.
        let first = makeIndex()
        for laps in 1...5 {
            _ = first.add(SessionFixture.make(track: "T\(laps)", datetimeUtc: Int64(laps)),
                          sourceURL: dir.appendingPathComponent("s\(laps).xrk"))
        }
        try store.save(first, to: url)

        let second = makeIndex()
        _ = second.add(SessionFixture.make(track: "Only"), sourceURL: dir.appendingPathComponent("only.xrk"))
        try store.save(second, to: url)

        // The target holds exactly the new index — no partial/merged content …
        #expect(store.load(from: url).summaries.map(\.venue) == ["Only"])
        // … and the atomic write left no temp sidecar behind.
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        #expect(entries.map(\.lastPathComponent) == ["library.json"])
    }

    @Test func test_save_creates_missing_parent_directory() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let nested = dir.appendingPathComponent("a/b/c/library.json")  // parents do not exist yet

        let index = makeIndex()
        _ = index.add(SessionFixture.make(), sourceURL: dir.appendingPathComponent("s.xrk"))

        try LibraryStore().save(index, to: nested)

        #expect(FileManager.default.fileExists(atPath: nested.path))
    }

    @Test func test_corrupt_index_loads_as_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        try Data("{ not valid json ".utf8).write(to: url)

        var logged: [LibraryError] = []
        let store = LibraryStore(log: { logged.append($0) })
        let loaded = store.load(from: url)

        #expect(loaded.summaries.isEmpty)
        #expect(logged == [.corruptIndex])
    }

    @Test func test_load_missing_file_returns_empty() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).json")

        #expect(LibraryStore().load(from: url).summaries.isEmpty)
    }

    @Test func test_corrupt_index_with_default_logger_loads_empty() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")
        try Data("not json".utf8).write(to: url)

        // The default store uses the real os.Logger; it must still recover to empty.
        #expect(LibraryStore().load(from: url).summaries.isEmpty)
    }

    @Test func test_load_dedupes_duplicate_ids_keeping_last() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "First"), sourceURL: dir.appendingPathComponent("s.xrk"))
        try LibraryStore().save(index, to: url)

        // Duplicate the single summary (same id, different venue) — a corrupt/hand-edited file.
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var summaries = try #require(json["summaries"] as? [[String: Any]])
        var duplicate = try #require(summaries.first)
        duplicate["venue"] = "Second"
        summaries.append(duplicate)
        json["summaries"] = summaries
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let loaded = LibraryStore().load(from: url)
        #expect(loaded.summaries.count == 1)                 // deduped by id
        #expect(loaded.summaries.first?.venue == "Second")   // last occurrence wins
    }

    // MARK: - dangling references

    @Test func test_missing_source_flags_unavailable() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("library.json")

        let present = dir.appendingPathComponent("present.xrk"); try touch(present)
        let missing = dir.appendingPathComponent("missing.xrk")  // never created

        let index = makeIndex()
        _ = index.add(SessionFixture.make(track: "Present", datetimeUtc: 300), sourceURL: present)
        _ = index.add(SessionFixture.make(track: "Missing", datetimeUtc: 200), sourceURL: missing)
        try LibraryStore().save(index, to: url)

        // Delete the present source to create a dangling reference after save.
        try FileManager.default.removeItem(at: present)

        let loaded = LibraryStore().load(from: url)
        let byVenue = Dictionary(uniqueKeysWithValues: loaded.summaries.map { ($0.venue, $0) })
        #expect(byVenue["Present"]?.isAvailable == false)  // deleted -> unavailable
        #expect(byVenue["Missing"]?.isAvailable == false)  // never existed -> unavailable
        #expect(loaded.summaries.count == 2)               // retained, not silently dropped
    }

    // MARK: - default location

    @Test func test_default_url_points_at_application_support() {
        let url = LibraryStore.defaultURL()

        #expect(url.lastPathComponent == "library.json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "RaceStudio")
    }
}
