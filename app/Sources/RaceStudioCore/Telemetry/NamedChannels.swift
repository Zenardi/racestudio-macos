import Foundation

/// The values of the session channels a frame carries by name (issue 9.11) —
/// beside the roles, for readouts of channels no role covers. Keys are the
/// channel map's matching keys (``TelemetryChannelMap/key(for:)``), sorted, so
/// two frames sampled the same way compare equal.
struct NamedChannelValues: Equatable, Sendable {
    private let keys: [String]
    private let values: [Double?]

    /// No named channels — what a timeline loaded without any carries. Empty
    /// arrays allocate nothing.
    static let none = NamedChannelValues(keys: [], values: [])

    init(keys: [String], values: [Double?]) {
        self.keys = keys
        self.values = values
    }

    /// Values by channel name (``keyed(_:)`` resolves names that match alike).
    init(_ byName: [String: Double]) {
        let keyed = Self.keyed(byName)
        self.init(keys: keyed.map(\.key), values: keyed.map(\.value))
    }

    /// The value under `key`, or `nil` when there is none (or a gap).
    func value(forKey key: String) -> Double? {
        guard let index = keys.firstIndex(of: key) else { return nil }
        return values[index]
    }

    /// `byName` by matching key, sorted by key. Names that match alike are one
    /// channel: the name that sorts first keeps it — decided by the names, never
    /// by the dictionary's (per-process) iteration order.
    static func keyed<Value>(_ byName: [String: Value]) -> [(key: String, value: Value)] {
        var keyed: [(key: String, value: Value)] = []
        var seen = Set<String>()
        for (name, value) in byName.sorted(by: { $0.key < $1.key }) {
            let key = TelemetryChannelMap.key(for: name)
            if seen.insert(key).inserted { keyed.append((key, value)) }
        }
        return keyed.sorted { $0.key < $1.key }
    }
}

/// The session channels a timeline samples by name (issue 9.11): one series per
/// matching key, sorted by key like the frame's ``NamedChannelValues``.
struct NamedChannelSeries: Sendable {
    private let keys: [String]
    private let series: [TelemetrySeries]

    static let none = NamedChannelSeries([:])

    /// Series by channel name (``NamedChannelValues/keyed(_:)`` resolves names
    /// that match alike).
    init(_ byName: [String: TelemetrySeries]) {
        let keyed = NamedChannelValues.keyed(byName)
        self.keys = keyed.map(\.key)
        self.series = keyed.map(\.value)
    }

    var isEmpty: Bool { keys.isEmpty }

    /// The bytes the series retain.
    var byteCount: Int { series.reduce(0) { $0 + $1.byteCount } }

    /// Every channel's value at `t`, reusing `hints` (one per channel; any
    /// hints are safe — a stale or missing set is reset).
    func values(at t: Double, hints: inout [Int]) -> NamedChannelValues {
        guard !isEmpty else { return .none }
        if hints.count != series.count { hints = [Int](repeating: -1, count: series.count) }
        var values: [Double?] = []
        values.reserveCapacity(series.count)
        for index in series.indices {
            values.append(series[index].value(at: t, hint: &hints[index]))
        }
        return NamedChannelValues(keys: keys, values: values)
    }
}
