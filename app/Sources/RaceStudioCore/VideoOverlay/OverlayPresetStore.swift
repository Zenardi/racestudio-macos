import Foundation
import os

/// A failure in the user overlay preset library (issue 9.10).
public enum OverlayPresetStoreError: Error, Equatable, Sendable {
    /// The library file exists but could not be read or decoded. Logged on load,
    /// which degrades to the built-ins — never thrown.
    case corruptFile
    /// This many presets, widgets or settings in the library could not be read:
    /// skipped, or read as their default. Logged on load — never thrown.
    case skippedEntries(Int)
    /// The library was written in this newer format; it is read as far as this
    /// build can. Logged on load — never thrown.
    case newerFormat(Int)
    /// Writing the library failed (the previous file is left intact).
    case ioFailure
    /// A preset was saved without a name.
    case emptyName
    /// A preset was saved under a built-in preset's name, in any language the
    /// app ships — the menu could not tell the two apart.
    case reservedName
}

/// The user's own overlay presets — *Save as preset…* (issue 9.10) — kept as
/// JSON in `Application Support/RaceStudio/OverlayPresets.json` (inside the app's
/// sandbox container when sandboxed).
///
/// Writes are atomic (temp file + replace), so an interrupted save never leaves
/// a truncated library. Reads are lenient and never throw: a missing file is an
/// empty library; a preset or widget this build can't read is skipped, and a
/// setting it can't read takes its default, both logged
/// (``OverlayPresetStoreError/skippedEntries(_:)``), as is a newer format
/// (``OverlayPresetStoreError/newerFormat(_:)``); a file that can't be read at
/// all logs ``OverlayPresetStoreError/corruptFile`` and yields no user presets,
/// so the menu still offers the built-ins. Before a save overwrites a file that
/// was not read in full in any of these ways, the file is kept aside as
/// `OverlayPresets.backup.json` (then `…backup-2.json`, …), so a hand edit gone
/// wrong — or a library from a newer build — is never silently lost. (Keys this
/// build doesn't know at all are ignored, not detected: a format that adds
/// meaning is expected to bump the schema.)
///
/// The directory, the file manager, the write primitive and the log are
/// injected (production: Application Support, an atomic `Data.write` and
/// `os.Logger`), so tests run in a temporary directory and observe the failure
/// paths. Each edit is a read-modify-write of the file, so use one store from
/// one actor (the main actor in the app).
public final class OverlayPresetStore {

    /// The library's file name.
    public static let fileName = "OverlayPresets.json"
    /// The library file format this build writes.
    static let currentSchema = 1

    /// The folder holding the library.
    public let directory: URL
    private let fileManager: FileManager
    private let write: (Data, URL) throws -> Void
    private let log: (OverlayPresetStoreError) -> Void

    private static let logger = Logger(subsystem: "com.racestudio.core", category: "overlay")

    public init(directory: URL = OverlayPresetStore.defaultDirectory(), fileManager: FileManager = .default,
                write: ((Data, URL) throws -> Void)? = nil, log: ((OverlayPresetStoreError) -> Void)? = nil) {
        self.directory = directory
        self.fileManager = fileManager
        self.write = write ?? { data, url in try data.write(to: url, options: .atomic) }
        self.log = log ?? { error in
            OverlayPresetStore.logger.warning("overlay presets: \(String(describing: error), privacy: .public)")
        }
    }

    /// `Application Support/RaceStudio` — beside the session library.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RaceStudio", isDirectory: true)
    }

    /// The library file.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    // MARK: - Reading

    /// What the preset menu offers: the built-ins in `locale`, then the user's.
    public func presets(locale: Locale = .current) -> [OverlayLayout] {
        OverlayPreset.builtIns(locale: locale) + userPresets()
    }

    /// The user's saved presets, in the order saved. Never throws (see the type).
    public func userPresets() -> [OverlayLayout] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        guard let read = readFile() else {
            log(.corruptFile)
            return []
        }
        if read.format > Self.currentSchema { log(.newerFormat(read.format)) }
        if read.skipped > 0 { log(.skippedEntries(read.skipped)) }
        return read.presets
    }

    /// One read of the library file.
    private struct LibraryRead {
        let presets: [OverlayLayout]
        /// The format it was written in.
        let format: Int
        /// How many entries could not be read.
        let skipped: Int

        /// Whether rewriting it would lose nothing this build saw.
        var isComplete: Bool { skipped == 0 && format <= OverlayPresetStore.currentSchema }
    }

    /// The library file as read, or `nil` when it can't be read or decoded at all.
    private func readFile() -> LibraryRead? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let counter = SkippedElementCounter()
        let decoder = JSONDecoder()
        if let key = SkippedElementCounter.key { decoder.userInfo[key] = counter }
        guard let file = try? decoder.decode(PresetFile.self, from: data) else { return nil }
        return LibraryRead(presets: file.presets, format: file.schema, skipped: counter.total)
    }

    // MARK: - Writing

    /// Replace the user's presets with `presets`, atomically, creating the folder
    /// if needed. An existing file that was not read in full is kept aside first.
    /// - Throws: ``OverlayPresetStoreError/ioFailure`` when the backup or the
    ///   write fails (nothing is overwritten then).
    public func save(_ presets: [OverlayLayout]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(PresetFile(presets: presets))
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path), readFile()?.isComplete != true {
                try fileManager.copyItem(at: fileURL, to: nextBackupURL())
            }
            try write(data, fileURL)
        } catch {
            throw OverlayPresetStoreError.ioFailure
        }
    }

    /// *Save as preset…*: store `layout` under `name` (trimmed), replacing — in
    /// place — a preset of the same name in any letter case.
    /// - Returns: the user's presets after the save.
    /// - Throws: ``OverlayPresetStoreError/emptyName`` for a blank name,
    ///   ``OverlayPresetStoreError/reservedName`` for a built-in's name, or
    ///   ``OverlayPresetStoreError/ioFailure`` when the write fails.
    @discardableResult
    public func savePreset(_ layout: OverlayLayout, named name: String) throws -> [OverlayLayout] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OverlayPresetStoreError.emptyName }
        guard !Self.reservedNames.contains(where: { Self.sameName($0, trimmed) }) else {
            throw OverlayPresetStoreError.reservedName
        }
        var named = layout
        named.name = trimmed
        var presets = userPresets()
        if let index = presets.firstIndex(where: { Self.sameName($0.name, trimmed) }) {
            presets[index] = named
        } else {
            presets.append(named)
        }
        try save(presets)
        return presets
    }

    /// Delete the user's preset called `name` (any letter case); an unknown name
    /// changes nothing.
    /// - Returns: the user's presets after the delete.
    /// - Throws: ``OverlayPresetStoreError/ioFailure`` when the write fails.
    @discardableResult
    public func deletePreset(named name: String) throws -> [OverlayLayout] {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let presets = userPresets().filter { !Self.sameName($0.name, wanted) }
        try save(presets)
        return presets
    }

    // MARK: - Internals

    /// The first free backup name: `OverlayPresets.backup.json`, then
    /// `OverlayPresets.backup-2.json`, … — an earlier backup is never replaced.
    private func nextBackupURL() -> URL {
        var url = directory.appendingPathComponent("OverlayPresets.backup.json")
        var suffix = 1
        while fileManager.fileExists(atPath: url.path) {
            suffix += 1
            url = directory.appendingPathComponent("OverlayPresets.backup-\(suffix).json")
        }
        return url
    }

    /// Every built-in preset's name in every language the app ships.
    private static var reservedNames: [String] {
        let languages = LocalizationCatalog.shared.availableLanguages
        return OverlayPreset.allCases.flatMap { preset in
            languages.map { preset.title(locale: Locale(identifier: $0)) }
        }
    }

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// The library file: a format version and the presets.
private struct PresetFile: Codable {
    /// The format: this build's when written; as found when read.
    var schema = OverlayPresetStore.currentSchema
    let presets: [OverlayLayout]

    init(presets: [OverlayLayout]) {
        self.presets = presets
    }

    private enum CodingKeys: String, CodingKey {
        case schema, presets
    }

    /// A preset this build can't read is skipped (and counted); a missing list
    /// is empty, but a list that isn't one makes the whole file unreadable.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = container.lenient(Int.self, forKey: .schema) ?? OverlayPresetStore.currentSchema
        presets = container.contains(.presets)
            ? try container.decode(LossyList<OverlayLayout>.self, forKey: .presets).elements
            : []
    }
}
