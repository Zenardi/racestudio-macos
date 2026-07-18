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

        let decoded: ProjectDocument
        switch version {
        case ProjectDocument.currentSchemaVersion:
            guard let document = try? JSONDecoder().decode(ProjectDocument.self, from: data) else {
                throw ProjectError.corruptDocument
            }
            decoded = document
        case 1:
            guard let raw = try? JSONDecoder().decode(ProjectDocumentV1.self, from: data) else {
                throw ProjectError.corruptDocument
            }
            decoded = Self.migrate(raw)
        case let invalid where invalid < 1:
            // A schema version below 1 is not a real version — treat as corrupt,
            // not as a "newer build" file.
            throw ProjectError.corruptDocument
        default:
            throw ProjectError.unsupportedVersion
        }

        return resolveAndValidate(decoded, library: library)
    }

    /// Upgrade a decoded v1 document to the current shape: v1 math channels had
    /// no `unit`, so it defaults to empty; everything else is unchanged.
    static func migrate(_ raw: ProjectDocumentV1) -> ProjectDocument {
        ProjectDocument(
            schemaVersion: ProjectDocument.currentSchemaVersion,
            sessionRefs: raw.sessionRefs,
            layout: raw.layout,
            selectedLaps: raw.selectedLaps,
            mathChannels: raw.mathChannels.map {
                MathChannelDef(name: $0.name, unit: "", expression: $0.expression)
            })
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
                    document.warnings.append("unresolved session reference: \(reference.id)")
                }
                resolvedRefs.append(reference)
            }
            document.sessionRefs = resolvedRefs

            document.selectedLaps = document.selectedLaps.map { selection in
                guard let lapCount = library.lapCountsByID[selection.sessionID] else { return selection }
                let clamped = selection.lapIndices.filter { $0 >= 0 && $0 < lapCount }
                if clamped != selection.lapIndices {
                    document.warnings.append(
                        "clamped lap selection for session \(selection.sessionID)")
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
