import Foundation

/// A kart in the user's garage: the identity of the machine a session was
/// driven on — category, chassis, engine and power — so lap times can be read
/// in context (an 18 HP F4 and a 30 HP shifter are not comparable).
///
/// The logger stamps its own free-text "vehicle" into every recording, but that
/// is whatever was typed on the device; a kart is the user's own, editable
/// record, assigned per session (``SessionIndex/assignKart(_:toSession:)``).
public struct Kart: Codable, Equatable, Hashable, Identifiable, Sendable {

    /// Stable identity; sessions reference a kart by it.
    public let id: String
    /// The user's name for the kart, e.g. "Race kart".
    public var name: String
    /// The class it races in, e.g. "F4".
    public var category: String
    /// The chassis, e.g. "Thunder".
    public var chassis: String
    /// The engine, e.g. "RBC Honda".
    public var engine: String
    /// Rated power in horsepower, e.g. 18, or `nil` when unknown.
    public var powerHP: Double?

    public init(id: String = UUID().uuidString, name: String, category: String = "",
                chassis: String = "", engine: String = "", powerHP: Double? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.chassis = chassis
        self.engine = engine
        self.powerHP = powerHP
    }

    /// The kart with its text fields trimmed and an unusable power (zero,
    /// negative, not finite) cleared — what the garage stores.
    public var normalized: Kart {
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        let power = powerHP.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        return Kart(id: id, name: clean(name), category: clean(category), chassis: clean(chassis),
                    engine: clean(engine), powerHP: power)
    }

    /// The name, or — when none was given — its specification, so a kart is
    /// never shown blank.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return specification.isEmpty ? "Unnamed kart" : specification
    }

    /// Category, chassis, engine and power in one line, e.g.
    /// `"F4 · Thunder · RBC Honda · 18 HP"`; blank fields are left out.
    public var specification: String {
        let parts = [category, chassis, engine]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (parts + [powerText].compactMap { $0 }).joined(separator: " · ")
    }

    /// `"18 HP"`, `"12.5 HP"`, or `nil` without a usable power.
    public var powerText: String? {
        guard let power = normalized.powerHP else { return nil }
        return String(format: power.rounded() == power ? "%.0f HP" : "%.1f HP", power)
    }
}
