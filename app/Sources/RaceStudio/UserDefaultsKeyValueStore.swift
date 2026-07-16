import Foundation
import RaceStudioCore

/// Production `KeyValueStoring` backed by `UserDefaults` (issue 2.3).
///
/// Lives in the shell so `RaceStudioCore` — the coverage target — stays free of
/// the real user defaults; unit tests inject an in-memory store instead.
struct UserDefaultsKeyValueStore: KeyValueStoring {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}
