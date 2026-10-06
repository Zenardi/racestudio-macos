import Foundation

/// How the attached footage is aligned to the session (issue 9.7) — what the
/// Video Review panel's status line says, and what a saved workspace remembers,
/// so the operator can tell a confirmed sync from a guess.
public enum SyncStatus: Equatable, Sendable {
    /// No alignment has been made; the footage runs from session time `0`.
    case notSynced
    /// The offset was proposed from the video file's creation date — a guess.
    case estimated
    /// The operator aligned the footage by eye: on the start of `lap` (a
    /// track-anchored sync), or by trimming the offset by hand when `lap` is `nil`.
    case anchored(lap: LapID?)
    /// Both offset and clock rate were solved from two lap-start anchors.
    case twoPoint(lapA: LapID, lapB: LapID)
    /// The offset was proposed from the engine sound (issue 9.8) and confirmed
    /// by the operator; `confidence` (`0...1`) is how clearly the match stood
    /// out. Added without a schema bump: builds from before 9.8 read it, through
    /// the lenient status decode, as ``notSynced``.
    case autoAudio(confidence: Double)

    /// The status as the panel shows it — `"Synced on lap 3 + lap 14"`, laps
    /// 1-based as everywhere in the UI.
    public func label(locale: Locale = .current) -> String {
        switch self {
        case .notSynced:
            return L10n.string(.videoStatusNotSynced, locale: locale)
        case .estimated:
            return L10n.string(.videoStatusEstimated, locale: locale)
        case .anchored(let lap?):
            return L10n.format(.videoStatusAnchored, locale: locale, Self.number(lap))
        case .anchored(nil):
            return L10n.string(.videoStatusManual, locale: locale)
        case let .twoPoint(lapA, lapB):
            return L10n.format(.videoStatusTwoPoint, locale: locale, Self.number(lapA), Self.number(lapB))
        case .autoAudio(let confidence):
            return L10n.format(.videoStatusAutoAudio, locale: locale, Self.percent(confidence, locale: locale))
        }
    }

    /// A `0...1` fraction as a whole percentage — `"87%"`.
    static func percent(_ fraction: Double, locale: Locale) -> String {
        L10n.formattedNumber(fraction * 100, fractionDigits: 0, locale: locale) + "%"
    }

    /// The panel's whole status line: how the footage is synced, then how much
    /// of the session it covers.
    public func statusLine(coverage: CoverageSummary, locale: Locale = .current) -> String {
        "\(label(locale: locale)) · \(coverage.label(locale: locale))"
    }

    /// A lap's 1-based number, as the UI shows it.
    static func number(_ lap: LapID) -> String { String(lap.index + 1) }
}

// MARK: - Persistence

/// Encoded as a readable `kind` plus 0-based lap indices — `{"kind": "twoPoint",
/// "lapA": 2, "lapB": 13}` — rather than Swift's synthesized enum shape, so the
/// `.rsproj` form stays stable and legible.
extension SyncStatus: Codable {

    private enum CodingKeys: String, CodingKey {
        case kind, lap, lapA, lapB, confidence
    }

    private enum Kind: String, Codable {
        case notSynced, estimated, anchored, twoPoint, autoAudio
    }

    /// The confidences a saved auto-audio status may carry.
    static let confidenceRange = 0.0...1.0

    /// The lap indices a saved status may name. A hand-edited or corrupt file can
    /// carry any `Int`; one outside this range is a decode error, never a lap —
    /// `Int.max` would otherwise trap when the status line adds one to it.
    static let lapIndexRange = 0...Int(Int32.max - 1)

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .notSynced:
            self = .notSynced
        case .estimated:
            self = .estimated
        case .anchored:
            self = .anchored(lap: try container.decodeIfPresent(Int.self, forKey: .lap)
                .map { try Self.lap($0, forKey: .lap, in: container) })
        case .twoPoint:
            let lapA = try container.decode(Int.self, forKey: .lapA)
            let lapB = try container.decode(Int.self, forKey: .lapB)
            self = .twoPoint(lapA: try Self.lap(lapA, forKey: .lapA, in: container),
                             lapB: try Self.lap(lapB, forKey: .lapB, in: container))
        case .autoAudio:
            let confidence = try container.decode(Double.self, forKey: .confidence)
            guard Self.confidenceRange.contains(confidence) else {
                throw DecodingError.dataCorruptedError(forKey: .confidence, in: container,
                                                       debugDescription: "confidence \(confidence) out of range")
            }
            self = .autoAudio(confidence: confidence)
        }
    }

    /// The lap a decoded `index` under `key` names, refused unless it is in
    /// ``lapIndexRange``.
    private static func lap(_ index: Int, forKey key: CodingKeys,
                            in container: KeyedDecodingContainer<CodingKeys>) throws -> LapID {
        guard lapIndexRange.contains(index) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: container,
                                                   debugDescription: "lap index \(index) out of range")
        }
        return LapID(index)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .notSynced:
            try container.encode(Kind.notSynced, forKey: .kind)
        case .estimated:
            try container.encode(Kind.estimated, forKey: .kind)
        case .anchored(let lap):
            try container.encode(Kind.anchored, forKey: .kind)
            try container.encodeIfPresent(lap?.index, forKey: .lap)
        case let .twoPoint(lapA, lapB):
            try container.encode(Kind.twoPoint, forKey: .kind)
            try container.encode(lapA.index, forKey: .lapA)
            try container.encode(lapB.index, forKey: .lapB)
        case .autoAudio(let confidence):
            try container.encode(Kind.autoAudio, forKey: .kind)
            try container.encode(confidence, forKey: .confidence)
        }
    }
}

// MARK: - Coverage summary

/// How much of the session the aligned footage holds (issue 9.7): the first and
/// last lap it covers **in full**, and how many of the session's laps that is —
/// "footage covers laps 2–15 (14 of 16)".
public struct CoverageSummary: Equatable, Sendable {
    /// The first fully filmed lap, or `nil` when none is.
    public let firstLap: LapID?
    /// The last fully filmed lap, or `nil` when none is.
    public let lastLap: LapID?
    /// How many laps are filmed in full.
    public let coveredLaps: Int
    /// How many reviewable laps the session has.
    public let totalLaps: Int

    public init(firstLap: LapID?, lastLap: LapID?, coveredLaps: Int, totalLaps: Int) {
        self.firstLap = firstLap
        self.lastLap = lastLap
        self.coveredLaps = coveredLaps
        self.totalLaps = totalLaps
    }

    /// Summarise which of `timeline`'s laps `sync` maps wholly inside the footage,
    /// reading the same ``VideoSyncModel/coverage(of:)`` the review grid dims by.
    public static func make(timeline: LapSectorTimeline, sync: VideoSyncModel) -> CoverageSummary {
        let covered = timeline.laps.filter { sync.coverage(of: $0.span) == .full }
        return CoverageSummary(firstLap: covered.first?.lap, lastLap: covered.last?.lap,
                               coveredLaps: covered.count, totalLaps: timeline.laps.count)
    }

    /// The summary as the panel shows it, laps 1-based.
    public func label(locale: Locale = .current) -> String {
        guard let firstLap, let lastLap else { return L10n.string(.videoCoverageNone, locale: locale) }
        let covered = String(coveredLaps), total = String(totalLaps)
        guard firstLap != lastLap else {
            return L10n.format(.videoCoverageSingle, locale: locale, SyncStatus.number(firstLap), covered, total)
        }
        return L10n.format(.videoCoverageRange, locale: locale,
                           SyncStatus.number(firstLap), SyncStatus.number(lastLap), covered, total)
    }
}
