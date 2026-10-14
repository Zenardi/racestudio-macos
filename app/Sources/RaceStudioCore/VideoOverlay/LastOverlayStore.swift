import Foundation
import os

/// The last HUD the operator arranged (issue 9.22): every committed HUD edit
/// is saved here, and a session opened without a HUD of its own starts with
/// it — so a new session's video shows the widgets, places, sizes and
/// settings left on the last one.
///
/// It is one layout in `LastOverlay.json` beside the library, read with the
/// overlay's own lenient decoding: a widget or setting this build can't read
/// costs only itself, and a file that isn't a layout at all reads as no last
/// HUD, so the session starts as it always did.
public final class LastOverlayStore {

    /// The file the last HUD is kept in.
    public static let fileName = "LastOverlay.json"

    /// Where the last HUD is kept.
    public let url: URL
    private let write: (Data, URL) throws -> Void
    private static let logger = Logger(subsystem: "com.racestudio.core", category: "overlay")

    /// - Parameters:
    ///   - directory: the folder the file is kept in; created on the first save.
    ///   - write: the write primitive, injected so writes are countable in
    ///     tests; an atomic `Data.write` by default.
    public init(directory: URL, write: ((Data, URL) throws -> Void)? = nil) {
        self.url = directory.appendingPathComponent(Self.fileName)
        self.write = write ?? { data, url in try data.write(to: url, options: .atomic) }
    }

    /// `~/Library/Application Support/RaceStudio` — beside `library.json`.
    public static func defaultDirectory() -> URL {
        LibraryStore.defaultURL().deletingLastPathComponent()
    }

    /// The last HUD, or `nil` when there is none or it can't be read.
    public func load() -> OverlayLayout? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(OverlayLayout.self, from: data)
        } catch {
            Self.logger.error("unreadable last HUD: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Keep `layout` as the last HUD, atomically.
    public func save(_ layout: OverlayLayout) throws {
        let data = try JSONEncoder().encode(layout)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try write(data, url)
    }
}
