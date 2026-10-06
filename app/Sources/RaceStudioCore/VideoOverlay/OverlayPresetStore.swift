import Foundation
import os

/// A failure in the user overlay preset library (issue 9.10).
public enum OverlayPresetStoreError: Error, Equatable, Sendable {
    /// The library file exists but could not be read or decoded. Logged on load,
    /// which degrades to the built-ins — never thrown.
    case corruptFile
    /// Writing the library failed (the previous file is left intact).
    case ioFailure
    /// A preset was saved without a name.
    case emptyName
}

/// The user's own overlay presets — *Save as preset…* (issue 9.10) — kept as
/// JSON in `~/Library/Application Support/RaceStudio/OverlayPresets.json`.
///
/// Writes are atomic (temp file + replace), so an interrupted save never leaves
/// a truncated library. Reads are lenient and never throw: a missing file is an
/// empty library; a preset this build can't read is skipped; a file that can't
/// be read at all logs ``OverlayPresetStoreError/corruptFile`` and yields no
/// user presets, so the menu still offers the built-ins. Saving over such a
/// file first keeps it aside as `OverlayPresets.corrupt.json`, so a hand edit
/// gone wrong is never silently destroyed.
///
/// The directory, the write primitive and the log are injected (production:
/// Application Support, an atomic `Data.write` and `os.Logger`), so tests run in
/// a temporary directory and observe the failure paths.
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

    /// `~/Library/Application Support/RaceStudio` — beside the session library.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("RaceStudio", isDirectory: true)
    }

    /// The library file.
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    /// Where an unreadable library is kept aside before it is overwritten.
    private var corruptURL: URL { directory.appendingPathComponent("OverlayPresets.corrupt.json") }

    // MARK: - Reading

    /// What the preset menu offers: the built-ins in `locale`, then the user's.
    public func presets(locale: Locale = .current) -> [OverlayLayout] {
        OverlayPreset.builtIns(locale: locale) + userPresets()
    }

    /// The user's saved presets, in the order saved. Never throws (see the type).
    public func userPresets() -> [OverlayLayout] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        guard let presets = readFile() else {
            log(.corruptFile)
            return []
        }
        return presets
    }

    /// The presets in the library file, or `nil` when it can't be read or decoded.
    private func readFile() -> [OverlayLayout]? {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(PresetFile.self, from: data) else { return nil }
        return file.presets
    }

    // MARK: - Writing

    /// Replace the user's presets with `presets`, atomically, creating the folder
    /// if needed. An existing file that can't be read is kept aside first.
    /// - Throws: ``OverlayPresetStoreError/ioFailure`` when the write fails.
    public func save(_ presets: [OverlayLayout]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(PresetFile(schema: Self.currentSchema, presets: presets))
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: fileURL.path), readFile() == nil {
                try? fileManager.removeItem(at: corruptURL)
                try fileManager.copyItem(at: fileURL, to: corruptURL)
            }
            try write(data, fileURL)
        } catch {
            throw OverlayPresetStoreError.ioFailure
        }
    }

    /// *Save as preset…*: store `layout` under `name` (trimmed), replacing — in
    /// place — a preset of the same name in any letter case.
    /// - Returns: the user's presets after the save.
    /// - Throws: ``OverlayPresetStoreError/emptyName`` for a blank name, or
    ///   ``OverlayPresetStoreError/ioFailure`` when the write fails.
    @discardableResult
    public func savePreset(_ layout: OverlayLayout, named name: String) throws -> [OverlayLayout] {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OverlayPresetStoreError.emptyName }
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

    private static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

/// The library file: a format version and the presets, read leniently.
private struct PresetFile: Codable {
    let schema: Int
    let presets: [OverlayLayout]

    init(schema: Int, presets: [OverlayLayout]) {
        self.schema = schema
        self.presets = presets
    }

    private enum CodingKeys: String, CodingKey {
        case schema, presets
    }

    /// A preset this build can't read is skipped; a missing list is empty.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = container.lenient(Int.self, forKey: .schema) ?? OverlayPresetStore.currentSchema
        presets = container.lenient(LossyList<OverlayLayout>.self, forKey: .presets)?.elements ?? []
    }
}
