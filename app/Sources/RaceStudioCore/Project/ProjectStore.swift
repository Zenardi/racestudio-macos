import Foundation

/// A typed error from the project/workspace persistence layer (issue 5.4).
public enum ProjectError: Error, Equatable, Sendable {
    /// The file is not a decodable project document.
    case corruptDocument
    /// The file's `schemaVersion` is newer/unknown to this build.
    case unsupportedVersion
    /// A math channel's stored expression failed to parse (non-fatal; collected).
    case invalidMathChannel(name: String)
    /// Reading or writing the document failed.
    case ioFailure
}

/// The library a project is resolved against on load (issue 5.4): the lap count
/// of each known session, keyed by content id.
///
/// Passing a context (even an empty one) means "resolve against this library" —
/// so an empty library correctly marks every reference unresolved. Passing `nil`
/// to ``ProjectStore/load(from:library:)`` means "no library available", leaving
/// references and lap selections exactly as loaded.
public struct LibraryContext: Sendable {
    /// Lap count per known session content id (from the 5.3 `SessionIndex`).
    public let lapCountsByID: [String: Int]

    public init(lapCountsByID: [String: Int] = [:]) {
        self.lapCountsByID = lapCountsByID
    }
}

/// Versioned, atomic persistence for a ``ProjectDocument`` (issue 5.4).
///
/// ``save(_:to:)`` writes the document as JSON atomically (temp file + replace),
/// so an interrupted write never yields a truncated `.rsproj`. ``load(from:)``
/// decodes (migrating an older ``schemaVersion`` forward), then resolves session
/// references and clamps lap selections against the supplied ``LibraryContext``
/// and re-validates every math channel's expression via the injected
/// ``ExpressionValidating`` parser — an invalid expression is recorded as
/// ``ProjectError/invalidMathChannel(name:)`` without aborting the load.
///
/// The parser and the write primitive are injected (production: the FFI parser
/// and an atomic `Data.write`) so the failure and validation paths are testable
/// without touching real global state.
public final class ProjectStore {

    /// The file extension for project/workspace documents.
    public static let fileExtension = "rsproj"

    private let validator: ExpressionValidating
    private let write: (Data, URL) throws -> Void

    public init(
        validator: ExpressionValidating,
        write: ((Data, URL) throws -> Void)? = nil
    ) {
        self.validator = validator
        self.write = write ?? { data, url in try data.write(to: url, options: .atomic) }
    }

    /// Encode `document` as JSON and write it atomically to `url`, creating the
    /// parent directory if needed. Throws ``ProjectError/ioFailure`` if the write
    /// cannot be committed (the previous file, if any, is left intact).
    public func save(_ document: ProjectDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, url)
        } catch {
            throw ProjectError.ioFailure
        }
    }

    /// Load the project at `url`, migrating an older schema forward, then
    /// resolving/validating against `library`.
    ///
    /// - Throws: ``ProjectError/ioFailure`` if the file can't be read;
    ///   ``ProjectError/corruptDocument`` if it isn't a decodable project;
    ///   ``ProjectError/unsupportedVersion`` for a newer/unknown `schemaVersion`.
    ///   An invalid math channel does **not** throw — it is recorded in the
    ///   returned document's `diagnostics`.
    public func load(from url: URL, library: LibraryContext? = nil) throws -> ProjectDocument {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ProjectError.ioFailure
        }
        guard let version = (try? JSONDecoder().decode(SchemaEnvelope.self, from: data))?.schemaVersion
        else {
            throw ProjectError.corruptDocument
        }
        // A version below 1 is not a real schema (corrupt); one above this build's is
        // a newer file (unsupported). In between, `decode` migrates it forward.
        guard version >= 1 else { throw ProjectError.corruptDocument }
        guard version <= ProjectDocument.currentSchemaVersion else { throw ProjectError.unsupportedVersion }

        return resolveAndValidate(try Self.decode(data, version: version), library: library)
    }

    /// Decode `data` at a known-in-range `version` (1…current), migrating an older
    /// shape forward to the current ``ProjectDocument``. Throws
    /// ``ProjectError/corruptDocument`` if the payload doesn't match its declared
    /// version's shape.
    private static func decode(_ data: Data, version: Int) throws -> ProjectDocument {
        switch version {
        case ProjectDocument.currentSchemaVersion:
            return try decodeWithOverlay(data, keepingVideoData: true)
        case 7:
            // v7 is the current shape without the 9.12 pane layout, which the
            // current decoder already reads as its default when absent.
            return try decodeWithOverlay(data, keepingVideoData: false)
        case 6:
            return migrate(try shape(ProjectDocumentV6.self, from: data))
        case 5:
            return migrate(try shape(ProjectDocumentV5.self, from: data))
        case 4:
            return migrate(try shape(ProjectDocumentV4.self, from: data))
        case 3:
            return migrate(try shape(ProjectDocumentV3.self, from: data))
        case 2:
            return migrate(try shape(ProjectDocumentV2.self, from: data))
        default: // version == 1 — the caller has already bounded it to 1…current.
            return migrate(try shape(ProjectDocumentV1.self, from: data))
        }
    }

    /// Decode `data` in the current shape (v7 and later carry a video overlay,
    /// whose unreadable entries are skipped leniently — count them, so the load
    /// says so), stamped with the current schema. A v7 file's pane layout key
    /// means nothing at that version, so `keepingVideoData` is `false` for it and
    /// the panel opens at its default.
    private static func decodeWithOverlay(_ data: Data, keepingVideoData: Bool) throws -> ProjectDocument {
        let counter = SkippedElementCounter()
        var document = try shape(ProjectDocument.self, from: data, counting: counter)
        if counter.total > 0 {
            document.loadWarnings.append(.skippedOverlayEntries(counter.total))
        }
        document.schemaVersion = ProjectDocument.currentSchemaVersion
        if !keepingVideoData { document.videoData = .default }
        return document
    }

    /// Decode `data` as one version's on-disk `type`, or throw
    /// ``ProjectError/corruptDocument`` when the payload doesn't match it.
    /// `counter`, when given, counts what the decode had to skip.
    private static func shape<Shape: Decodable>(_ type: Shape.Type, from data: Data,
                                                counting counter: SkippedElementCounter? = nil) throws -> Shape {
        let decoder = JSONDecoder()
        if let counter, let key = SkippedElementCounter.key { decoder.userInfo[key] = counter }
        guard let decoded = try? decoder.decode(type, from: data) else {
            throw ProjectError.corruptDocument
        }
        return decoded
    }

    /// Upgrade a decoded v1 document to the current shape: v1 math channels had
    /// no `unit`, so it defaults to empty, and v1 predates the persisted
    /// `activeLayout`, so it opens on Time/Distance; everything else is unchanged.
    static func migrate(_ raw: ProjectDocumentV1) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels.map {
                MathChannelDef(name: $0.name, unit: "", expression: $0.expression)
            },
            activeLayout: .timeDistance)
    }

    /// Upgrade a decoded v2 document to the current shape: v2 predates the
    /// persisted `activeLayout` (issue 8.13), so it opens on Time/Distance;
    /// everything else — including the per-channel `unit` added in v2 — is
    /// carried over unchanged.
    static func migrate(_ raw: ProjectDocumentV2) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels,
            activeLayout: .timeDistance)
    }

    /// Upgrade a decoded v3 document to the current shape: v3 predates the persisted
    /// log sheet (issue 8.17), so it opens with an empty ``LogSheet``; everything
    /// else — including the v3 `activeLayout` — is carried over unchanged.
    static func migrate(_ raw: ProjectDocumentV3) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels,
            activeLayout: raw.activeLayout,
            logSheet: LogSheet())
    }

    /// Upgrade a decoded v4 document to the current shape: v4 predates the
    /// attached session video (issue 9.6), so it opens with no footage;
    /// everything else — including the v4 `logSheet` — is carried over unchanged.
    static func migrate(_ raw: ProjectDocumentV4) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels,
            activeLayout: raw.activeLayout,
            logSheet: raw.logSheet,
            video: nil)
    }

    /// Upgrade a decoded v5 document to the current shape: v5 predates the clock
    /// rate and sync status (issue 9.7), so an attached video runs at rate `1`,
    /// and its status is inferred from the offset — a non-zero offset was set by
    /// the operator (``SyncStatus/anchored(lap:)`` on an unrecorded lap), a zero
    /// one was never aligned. Everything else is carried over unchanged.
    static func migrate(_ raw: ProjectDocumentV5) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels,
            activeLayout: raw.activeLayout,
            logSheet: raw.logSheet,
            video: raw.video.map { video in
                VideoAttachment(bookmark: video.bookmark, displayName: video.displayName, offset: video.offset,
                                rate: 1, status: video.offset != 0 ? .anchored(lap: nil) : .notSynced)
            })
    }

    /// Upgrade a decoded v6 document to the current shape: v6 predates the video
    /// overlay (issue 9.10), so it opens with none — the HUD is off — and the
    /// Video + Data pane layout (issue 9.12), so the panel opens at its default.
    /// Everything else, including the 9.7 video attachment, is carried over
    /// unchanged.
    static func migrate(_ raw: ProjectDocumentV6) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels,
            activeLayout: raw.activeLayout,
            logSheet: raw.logSheet,
            video: raw.video,
            overlay: nil)
    }

    // MARK: - Resolution / validation

    /// Resolve session references and clamp lap selections against `library`
    /// (skipped when it is `nil`), then re-validate every math channel — always,
    /// since validation needs no library.
    private func resolveAndValidate(
        _ input: ProjectDocument, library: LibraryContext?
    ) -> ProjectDocument {
        var document = input

        if let library {
            var resolvedRefs: [SessionRef] = []
            resolvedRefs.reserveCapacity(document.sessionRefs.count)
            for var reference in document.sessionRefs {
                reference.resolved = library.lapCountsByID[reference.id] != nil
                if !reference.resolved {
                    document.loadWarnings.append(.unresolvedSession(reference.id))
                }
                resolvedRefs.append(reference)
            }
            document.sessionRefs = resolvedRefs

            document.selectedLaps = document.selectedLaps.map { selection in
                guard let lapCount = library.lapCountsByID[selection.sessionID] else { return selection }
                let clamped = selection.lapIndices.filter { $0 >= 0 && $0 < lapCount }
                if clamped != selection.lapIndices {
                    document.loadWarnings.append(.clampedLapSelection(selection.sessionID))
                }
                var validated = selection
                validated.lapIndices = clamped
                return validated
            }
        }

        for channel in document.mathChannels {
            do {
                try channel.validate(using: validator)
            } catch {
                document.diagnostics.append(.invalidMathChannel(name: channel.name))
            }
        }

        return document
    }
}

// MARK: - Decoding helpers

/// Peeks the `schemaVersion` before committing to a full shape.
private struct SchemaEnvelope: Decodable {
    let schemaVersion: Int
}

/// The v1 on-disk shape — identical to the current document except math channels
/// carried no `unit`. Used only by ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV1: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelV1]

    struct MathChannelV1: Decodable {
        let name: String
        let expression: String
    }
}

/// The v2 on-disk shape — identical to the current document except it predates the
/// persisted `activeLayout` (issue 8.13). Used only by ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV2: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelDef]
}

/// The v4 on-disk shape — identical to the current document except it predates
/// the attached session video (issue 9.6). Used only by ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV4: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelDef]
    let activeLayout: WindowLayout
    let logSheet: LogSheet
}

/// The v5 on-disk shape — identical to the current document except its video
/// attachment predates the clock rate and sync status (issue 9.7). Used only by
/// ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV5: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelDef]
    let activeLayout: WindowLayout
    let logSheet: LogSheet
    let video: VideoV5?

    /// The 9.6 attachment: a bookmark, a name and an offset.
    struct VideoV5: Decodable {
        let bookmark: Data
        let displayName: String
        let offset: Double
    }
}

/// The v6 on-disk shape — identical to the current document except it predates
/// the video overlay (issue 9.10). Used only by ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV6: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelDef]
    let activeLayout: WindowLayout
    let logSheet: LogSheet
    let video: VideoAttachment?
}

/// The v3 on-disk shape — identical to the current document except it predates the
/// persisted `logSheet` (issue 8.17). Used only by ``ProjectStore/migrate(_:)``.
struct ProjectDocumentV3: Decodable {
    let sessionRefs: [SessionRef]
    let layout: AnalysisLayout
    let selectedLaps: [LapSelection]
    let mathChannels: [MathChannelDef]
    let activeLayout: WindowLayout
}
