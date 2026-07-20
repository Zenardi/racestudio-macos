import Foundation

/// A named RaceStudio 3 collection of sessions (issue 8.15).
///
/// A collection is either **smart** — rule-based, its members computed on the fly
/// from a ``FilterSpec`` — or **manual** — a curated, ordered set of session
/// content ids built by drag-and-drop. Both persist in the library JSON via
/// ``SessionIndex``; ``SessionIndex/sessions(in:)`` resolves a collection to the
/// summaries it contains.
public struct SessionCollection: Identifiable, Equatable, Codable, Sendable {

    /// What drives a collection's membership.
    public enum Kind: Equatable, Sendable {
        /// Rule-based: members are the sessions matching this ``FilterSpec``.
        case smart(FilterSpec)
        /// Curated: an ordered list of session content ids.
        case manual([String])
    }

    /// Stable, unique id within a library.
    public let id: String
    /// User-facing name (shown in the collections sidebar).
    public var name: String
    /// The rule (smart) or curated members (manual).
    public var kind: Kind

    public init(id: String, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    /// A rule-based collection whose members are the sessions matching `rule`.
    public static func smart(id: String, name: String, rule: FilterSpec) -> SessionCollection {
        SessionCollection(id: id, name: name, kind: .smart(rule))
    }

    /// A curated collection seeded with `members` (empty by default).
    public static func manual(id: String, name: String, members: [String] = []) -> SessionCollection {
        SessionCollection(id: id, name: name, kind: .manual(members))
    }

    // MARK: - Accessors

    /// Whether this is a smart (rule-based) collection.
    public var isSmart: Bool {
        if case .smart = kind { return true }
        return false
    }

    /// The rule of a smart collection, or `nil` for a manual one.
    public var rule: FilterSpec? {
        if case .smart(let rule) = kind { return rule }
        return nil
    }

    /// The curated member ids of a manual collection, or `[]` for a smart one.
    public var memberIDs: [String] {
        if case .manual(let members) = kind { return members }
        return []
    }

    // MARK: - Curating a manual collection

    /// A copy with `sessionID` appended (drag-and-drop). Idempotent — a session
    /// already present keeps its position. A smart collection is unchanged (its
    /// members are rule-driven, not hand-curated).
    public func adding(_ sessionID: String) -> SessionCollection {
        guard case .manual(var members) = kind, !members.contains(sessionID) else { return self }
        members.append(sessionID)
        return SessionCollection(id: id, name: name, kind: .manual(members))
    }

    /// A copy with `sessionID` removed (no-op if absent, or if smart).
    public func removing(_ sessionID: String) -> SessionCollection {
        guard case .manual(let members) = kind else { return self }
        return SessionCollection(id: id, name: name, kind: .manual(members.filter { $0 != sessionID }))
    }

    // MARK: - Codable (flat, diff-friendly JSON with a `kind` discriminator)

    private enum CodingKeys: String, CodingKey { case id, name, kind, rule, members }
    private enum KindTag: String, Codable { case smart, manual }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        switch try container.decode(KindTag.self, forKey: .kind) {
        case .smart:
            kind = .smart(try container.decode(FilterSpec.self, forKey: .rule))
        case .manual:
            kind = .manual(try container.decodeIfPresent([String].self, forKey: .members) ?? [])
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        switch kind {
        case .smart(let rule):
            try container.encode(KindTag.smart, forKey: .kind)
            try container.encode(rule, forKey: .rule)
        case .manual(let members):
            try container.encode(KindTag.manual, forKey: .kind)
            try container.encode(members, forKey: .members)
        }
    }
}
