import Foundation
import os

/// A typed error from the session library's persistence layer (issue 5.3).
public enum LibraryError: Error, Equatable {
    /// The on-disk index could not be decoded; it is treated as empty.
    case corruptIndex
    /// Writing the index to disk failed.
    case ioFailure
}

/// A structured filter over indexed sessions (issue 5.3). Each property is an
/// optional predicate; `nil` means "don't constrain on this". An all-`nil` spec
/// matches every session.
public struct FilterSpec: Equatable, Sendable {

    /// Exact vehicle match (case-insensitive).
    public var vehicle: String?
    /// Inclusive session-date range.
    public var dateRange: ClosedRange<Date>?
    /// Minimum lap count (inclusive).
    public var minLaps: Int?

    public init(vehicle: String? = nil, dateRange: ClosedRange<Date>? = nil, minLaps: Int? = nil) {
        self.vehicle = vehicle
        self.dateRange = dateRange
        self.minLaps = minLaps
    }

    /// Whether `summary` satisfies every set predicate.
    func matches(_ summary: SessionSummary) -> Bool {
        if let vehicle, vehicle.caseInsensitiveCompare(summary.vehicle) != .orderedSame { return false }
        if let dateRange, !dateRange.contains(summary.date) { return false }
        if let minLaps, summary.lapCount < minLaps { return false }
        return true
    }
}

/// Atomic, crash-safe persistence for a ``SessionIndex`` (issue 5.3).
///
/// ``save(_:to:)`` writes the index as JSON to a temp file and atomically
/// replaces the target, so an interrupted write never leaves a truncated or
/// corrupt index behind. ``load(from:)`` never throws: a missing file loads as an
/// empty index, and a corrupt file loads as empty with a logged
/// ``LibraryError/corruptIndex`` rather than crashing. On load, each summary's
/// availability is re-checked against disk so dangling references are flagged.
///
/// The write primitive and error log are injected (defaulting to an atomic
/// `Data.write` and `os.Logger`) so the failure and logging paths are testable
/// without touching real global state.
public final class LibraryStore {

    private let write: (Data, URL) throws -> Void
    private let log: (LibraryError) -> Void
    private let fileManager: FileManager

    private static let logger = Logger(subsystem: "com.racestudio.core", category: "library")

    public init(
        fileManager: FileManager = .default,
        write: ((Data, URL) throws -> Void)? = nil,
        log: ((LibraryError) -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.write = write ?? { data, url in try data.write(to: url, options: .atomic) }
        self.log = log ?? { error in
            LibraryStore.logger.error("session library: \(String(describing: error), privacy: .public)")
        }
    }

    /// The default index location:
    /// `~/Library/Application Support/RaceStudio/library.json`.
    public static func defaultURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("RaceStudio", isDirectory: true)
            .appendingPathComponent("library.json")
    }

    /// Encode `index` as JSON and write it atomically to `url`, creating the
    /// parent directory if needed. Throws ``LibraryError/ioFailure`` if the write
    /// cannot be committed (the previous file, if any, is left intact).
    public func save(_ index: SessionIndex, to url: URL) throws {
        let data = try JSONEncoder().encode(index)
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, url)
        } catch {
            throw LibraryError.ioFailure
        }
    }

    /// Load the index at `url`, re-checking each source's availability. A missing
    /// file returns a fresh empty index (no library yet); a file that exists but
    /// cannot be read or decoded returns empty and logs
    /// ``LibraryError/corruptIndex`` — distinguished so a transient read error on
    /// a real index is never silently mistaken for "no library". Never throws.
    public func load(from url: URL) -> SessionIndex {
        guard fileManager.fileExists(atPath: url.path) else { return SessionIndex() }
        guard let data = try? Data(contentsOf: url),
              let index = try? JSONDecoder().decode(SessionIndex.self, from: data) else {
            log(.corruptIndex)
            return SessionIndex()
        }
        index.refreshAvailability(fileManager: fileManager)
        return index
    }
}
