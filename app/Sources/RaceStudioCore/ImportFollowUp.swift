import Foundation

/// The user's standing answer to "open this session after importing it?".
public enum ImportOpenPreference: String, Codable, Sendable, CaseIterable {
    /// Offer the choice each time (the default).
    case ask
    /// Open the imported session straight away, without asking.
    case always
    /// Stay in the library, without asking.
    case never
}

/// What the app should do once an import finishes.
public enum ImportFollowUp: Equatable, Sendable {
    /// Offer to open this session for analysis.
    case ask(SessionSummary)
    /// Open this session without asking (the user chose ``ImportOpenPreference/always``).
    case open(SessionSummary)
    /// Stay in the library.
    case stay
}

/// Decides what happens after an import, and remembers the user's standing answer.
///
/// Importing used to leave the user in the library with no signal that anything was
/// ready to look at — the row simply appeared. A completed import now offers to open
/// the session for analysis, and the offer is suppressible in both directions so it
/// never becomes a click to dismiss on every import.
///
/// A **batch** import never opens or asks, whatever the standing answer: importing
/// several files is a "fill my library" action, and hijacking the window to one
/// arbitrary member of the batch would be wrong in either direction.
public struct ImportFollowUpPolicy {

    /// The defaults key the standing answer is stored under.
    public static let defaultsKey = "import.followUp"

    private let store: KeyValueStoring
    private let key: String

    public init(store: KeyValueStoring, key: String = ImportFollowUpPolicy.defaultsKey) {
        self.store = store
        self.key = key
    }

    /// The user's standing answer. An absent or unreadable saved value reads as
    /// ``ImportOpenPreference/ask`` — a preference written by a future version must
    /// not silently lock the user into a behaviour they cannot see.
    public var preference: ImportOpenPreference {
        get {
            guard let data = store.data(forKey: key),
                  let raw = String(data: data, encoding: .utf8),
                  let preference = ImportOpenPreference(rawValue: raw) else { return .ask }
            return preference
        }
        nonmutating set {
            store.set(Data(newValue.rawValue.utf8), forKey: key)
        }
    }

    /// What to do now that `imported` has landed in the library.
    public func followUp(for imported: [SessionSummary]) -> ImportFollowUp {
        guard imported.count == 1, let only = imported.first else { return .stay }
        switch preference {
        case .ask: return .ask(only)
        case .always: return .open(only)
        case .never: return .stay
        }
    }
}
