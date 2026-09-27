import CryptoKit
import Foundation
import Testing
@testable import RaceStudioCore

/// Behaviour for RaceStudio's own copy of each imported telemetry file.
///
/// The library used to reference the file the user picked, so moving or deleting
/// that file left a row that listed but could not open. Importing now *adopts* the
/// file into the app's storage and the library points at that copy, which the app
/// owns for the session's lifetime. Adoption is keyed by content hash so
/// re-importing the same file reuses the copy instead of accumulating duplicates,
/// and discarding is refused for anything outside the managed directory — the
/// user's original is never at risk.
@Suite struct ManagedFileStoreTests {

    /// A fresh managed directory plus a scratch dir standing in for the user's disk.
    private func makeStore() throws -> Scratch {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rs-managed-\(UUID().uuidString)", isDirectory: true)
        let managed = root.appendingPathComponent("Sessions", isDirectory: true)
        let scratch = root.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        return Scratch(store: ManagedFileStore(directory: managed), managed: managed, scratch: scratch)
    }

    private func write(_ bytes: String, to url: URL) throws {
        try Data(bytes.utf8).write(to: url)
    }

    // MARK: - Adopting a file

    @Test func test_adopting_copies_the_bytes_into_the_managed_directory() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)

        let adopted = try env.store.adopt(original)

        #expect(adopted.path.hasPrefix(env.managed.path), "the copy lives in the managed directory")
        #expect(try Data(contentsOf: adopted) == Data("telemetry".utf8))
    }

    @Test func test_adopting_leaves_the_original_in_place() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)

        _ = try env.store.adopt(original)

        #expect(FileManager.default.fileExists(atPath: original.path), "import must not move the user's file")
    }

    /// The FFI dispatches CSV vs `.xrk` decoding on the path extension
    /// (`has_csv_extension`), so the managed name must keep it.
    @Test func test_adopting_preserves_the_file_extension() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.csv")
        try write("Format,AiM CSV File", to: original)

        let adopted = try env.store.adopt(original)

        #expect(adopted.pathExtension == "csv")
    }

    @Test func test_adopting_keeps_the_original_name_recognisable() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)

        let adopted = try env.store.adopt(original)

        #expect(adopted.lastPathComponent.hasPrefix("stint-1-"))
    }

    // MARK: - Idempotence (re-importing the same file)

    @Test func test_re_adopting_the_same_content_reuses_the_same_copy() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)

        let first = try env.store.adopt(original)
        let second = try env.store.adopt(original)

        #expect(first == second)
        let contents = try FileManager.default.contentsOfDirectory(atPath: env.managed.path)
        #expect(contents.count == 1, "re-importing must not accumulate duplicate copies")
    }

    /// The same content picked up under a different name is still the same session,
    /// so it must not produce a second copy on disk.
    @Test func test_identical_content_under_a_different_name_reuses_the_copy() throws {
        let env = try makeStore()
        let first = env.scratch.appendingPathComponent("stint-1.xrk")
        let renamed = env.scratch.appendingPathComponent("copy-of-stint-1.xrk")
        try write("telemetry", to: first)
        try write("telemetry", to: renamed)

        _ = try env.store.adopt(first)
        _ = try env.store.adopt(renamed)

        let contents = try FileManager.default.contentsOfDirectory(atPath: env.managed.path)
        #expect(contents.count == 1, "adoption is keyed by content, not by name")
    }

    /// Two genuinely different sessions exported under the same name (the common
    /// case when a logger names every download `session.xrk`) must not collide.
    @Test func test_different_content_with_the_same_name_gets_distinct_copies() throws {
        let env = try makeStore()
        let first = env.scratch.appendingPathComponent("a/session.xrk")
        let second = env.scratch.appendingPathComponent("b/session.xrk")
        for dir in ["a", "b"] {
            try FileManager.default.createDirectory(
                at: env.scratch.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        try write("stint one", to: first)
        try write("stint two", to: second)

        let adoptedFirst = try env.store.adopt(first)
        let adoptedSecond = try env.store.adopt(second)

        #expect(adoptedFirst != adoptedSecond)
        let contents = try FileManager.default.contentsOfDirectory(atPath: env.managed.path)
        #expect(contents.count == 2)
    }

    // MARK: - Failure

    @Test func test_adopting_a_missing_file_throws_unreadable() throws {
        let env = try makeStore()

        #expect(throws: ManagedFileStore.StorageError.unreadable) {
            _ = try env.store.adopt(env.scratch.appendingPathComponent("absent.xrk"))
        }
    }

    // MARK: - Ownership and discarding

    @Test func test_a_copy_in_the_managed_directory_is_recognised_as_managed() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)

        #expect(env.store.isManaged(try env.store.adopt(original)))
        #expect(!env.store.isManaged(original), "the user's own file is never managed")
    }

    @Test func test_discarding_removes_the_managed_copy() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("stint-1.xrk")
        try write("telemetry", to: original)
        let adopted = try env.store.adopt(original)

        try env.store.discard(adopted)

        #expect(!FileManager.default.fileExists(atPath: adopted.path))
    }

    /// The safety property: a library row that still points at a user-picked file
    /// (imported before adoption existed) must never have that file deleted when
    /// the row is removed.
    @Test func test_discarding_refuses_a_file_outside_the_managed_directory() throws {
        let env = try makeStore()
        let original = env.scratch.appendingPathComponent("precious.xrk")
        try write("telemetry", to: original)

        #expect(throws: ManagedFileStore.StorageError.notManaged) {
            try env.store.discard(original)
        }
        #expect(FileManager.default.fileExists(atPath: original.path), "the user's file survives")
    }

    /// Discarding a copy that is already gone is the caller's desired end state, so
    /// it succeeds rather than failing a delete the user asked for.
    @Test func test_discarding_an_already_absent_copy_succeeds() throws {
        let env = try makeStore()

        try env.store.discard(env.managed.appendingPathComponent("gone-abcdef0123456789.xrk"))
    }

    // MARK: - Naming

    /// Path separators and dot segments in a basename must not let a managed name
    /// escape the managed directory.
    @Test func test_a_hostile_basename_cannot_escape_the_managed_directory() throws {
        let name = ManagedFileStore.managedName(basename: "../../etc/passwd", extension: "xrk",
                                                digest: "0123456789abcdef")

        #expect(!name.contains("/"))
        #expect(!name.contains(".."))
        #expect(name.hasSuffix(".xrk"))
    }

    @Test func test_a_very_long_basename_is_truncated() throws {
        let name = ManagedFileStore.managedName(basename: String(repeating: "x", count: 500),
                                                extension: "xrk", digest: "0123456789abcdef")

        #expect(name.utf8.count <= 255, "must fit a filesystem name limit")
        #expect(name.hasSuffix("-0123456789abcdef.xrk"), "the digest is never truncated away")
    }

    @Test func test_an_empty_basename_still_yields_a_usable_name() throws {
        let name = ManagedFileStore.managedName(basename: "", extension: "xrk", digest: "0123456789abcdef")

        #expect(name == "session-0123456789abcdef.xrk")
    }

    /// A file with no extension (a device download named by id) keeps a bare name
    /// rather than gaining a stray trailing dot.
    @Test func test_a_missing_extension_yields_no_trailing_dot() throws {
        let name = ManagedFileStore.managedName(basename: "download", extension: "", digest: "abcdef0123456789")

        #expect(name == "download-abcdef0123456789")
    }

    // MARK: - Default location

    /// The copies live beside `library.json` in the app's Application Support
    /// directory — inside the sandbox container, so no entitlement is needed.
    @Test func test_the_default_directory_sits_beside_the_library_index() {
        let directory = ManagedFileStore.defaultDirectory()

        #expect(directory.lastPathComponent == "Sessions")
        #expect(directory.deletingLastPathComponent() == LibraryStore.defaultURL().deletingLastPathComponent())
    }
}

/// A throwaway managed directory plus the scratch dir standing in for the user's
/// disk. A named type rather than a tuple so the lint's tuple-size rule is happy.
struct Scratch {
    let store: ManagedFileStore
    let managed: URL
    let scratch: URL
}

/// The filesystem failure paths — a copy that cannot be written, and a copy that
/// cannot be removed. Both must surface as a typed error, never a crash or a
/// silent no-op that leaves the caller believing the operation succeeded.
@Suite struct ManagedFileStoreFailureTests {

    private func root() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rs-fail-\(UUID().uuidString)", isDirectory: true)
    }

    /// The managed directory cannot be created because a *file* already occupies
    /// its path — so the copy has nowhere to go.
    @Test func test_a_managed_directory_blocked_by_a_file_fails_the_copy() throws {
        let base = root()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let blocked = base.appendingPathComponent("Sessions")
        try Data("not a directory".utf8).write(to: blocked)
        let original = base.appendingPathComponent("stint-1.xrk")
        try Data("telemetry".utf8).write(to: original)

        #expect(throws: ManagedFileStore.StorageError.copyFailed) {
            _ = try ManagedFileStore(directory: blocked).adopt(original)
        }
    }

    /// The copy exists but cannot be unlinked, because its directory is not
    /// writable. Deleting must report the failure rather than claim success.
    @Test func test_an_unremovable_copy_reports_the_failure() throws {
        let base = root()
        let managed = base.appendingPathComponent("Sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let store = ManagedFileStore(directory: managed)
        let original = base.appendingPathComponent("stint-1.xrk")
        try Data("telemetry".utf8).write(to: original)
        let adopted = try store.adopt(original)
        // Read+execute only: the copy is still visible, but cannot be unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: managed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700], ofItemAtPath: managed.path)
        }

        #expect(throws: ManagedFileStore.StorageError.copyFailed) {
            try store.discard(adopted)
        }
    }
}
