import Foundation

/// The file name the export's save panel suggests (issue 9.14) —
/// `S.Marino AR – 2026-09-25 – Lap 9 (0'40.774).mp4`: the track, the
/// session's date and what was exported, joined by en dashes.
///
/// The name is made safe for any volume (``sanitized(_:)``): `/` and `:` —
/// the path separators of POSIX and of the Finder — become hyphens; control
/// characters, the invisible bidirectional overrides among them, become
/// spaces; runs of spaces collapse; a leading dot, which would hide the file,
/// is dropped; and the whole name, extension included, is cut to
/// ``maximumLength`` characters and 255 UTF-8 bytes, the longest name APFS and
/// HFS+ take. Letters are never folded: *Autódromo* stays *Autódromo*.
public enum ExportFileName {

    /// The longest suggested name, in characters, extension included.
    public static let maximumLength = 120
    /// The export's file extension.
    public static let fileExtension = "mp4"
    /// The name of an export with nothing else to go by.
    public static let fallback = "RaceStudio Export"

    /// The longest file name the Mac's volumes take, in UTF-8 bytes.
    static let maximumBytes = 255
    private static let separator = " – "

    /// `track – date – subject.mp4`, leaving out an empty track or a missing
    /// date, sanitized.
    public static func suggested(track: String, date: String?, subject: String) -> String {
        sanitized([track, date ?? "", subject].filter { !$0.isEmpty }.joined(separator: separator))
    }

    /// `base` made a safe file name, with the `.mp4` extension.
    public static func sanitized(_ base: String) -> String {
        let suffix = "." + fileExtension
        var name = clean(base)
        let budget = maximumLength - suffix.count
        if name.count > budget { name = String(name.prefix(budget)) }
        while name.utf8.count + suffix.utf8.count > maximumBytes { name.removeLast() }
        name = trimmed(name)
        return (name.isEmpty ? fallback : name) + suffix
    }

    /// A lap's subject — `Lap 9 (0'40.774)` — numbered from 1, in `locale`;
    /// just `Lap 9` without a valid time.
    public static func lapSubject(_ lap: LapID, lapTime: Double?, locale: Locale = .current) -> String {
        let number = SyncStatus.number(lap)
        guard let time = lapTime.flatMap(Self.lapTime) else {
            return L10n.format(.videoLapLabel, locale: locale, number)
        }
        return L10n.format(.exportFileNameLap, locale: locale, number, time)
    }

    /// A lap time as timing sheets write it, without a colon — `0'40.774`,
    /// `1h01'01.500` past an hour — or `nil` for a negative or non-finite time.
    public static func lapTime(_ seconds: Double) -> String? {
        let text = LapTimeFormatter.string(from: seconds)
        guard text != LapTimeFormatter.placeholder else { return nil }
        let parts = text.split(separator: ":")
        guard parts.count == 3 else { return parts.joined(separator: "'") }
        return "\(parts[0])h\(parts[1])'\(parts[2])"
    }

    /// The session's date as `yyyy-MM-dd`: the logger's own `MM/DD/YYYY`
    /// date when it is a real day of a four-digit year, else the UTC day of
    /// its start, else `nil`.
    public static func date(logDate: String, datetimeUtc: Int64) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let fields = logDate.split(separator: "/").compactMap { Int($0) }
        if fields.count == 3, (1_000...9_999).contains(fields[2]),
           DateComponents(calendar: calendar, year: fields[2], month: fields[0], day: fields[1]).isValidDate {
            return text(year: fields[2], month: fields[0], day: fields[1])
        }
        guard datetimeUtc > 0 else { return nil }
        let start = Date(timeIntervalSince1970: TimeInterval(datetimeUtc))
        return text(year: calendar.component(.year, from: start), month: calendar.component(.month, from: start),
                    day: calendar.component(.day, from: start))
    }

    /// `yyyy-MM-dd`.
    private static func text(year: Int, month: Int, day: Int) -> String {
        String(format: "%04ld-%02ld-%02ld", year, month, day)
    }

    // MARK: - Internals

    /// `/` and `:` as hyphens, control characters as spaces, whitespace runs
    /// collapsed, leading dots and surrounding spaces dropped.
    private static func clean(_ text: String) -> String {
        let scalars = text.unicodeScalars.map { scalar -> String in
            if scalar == "/" || scalar == ":" { return "-" }
            if CharacterSet.controlCharacters.contains(scalar) { return " " }
            return String(scalar)
        }
        let words = scalars.joined().split(whereSeparator: { $0.isWhitespace })
        return trimmed(words.joined(separator: " "))
    }

    /// `text` without leading dots, nor the spaces, dots and dashes a cut can
    /// leave dangling at either end.
    private static func trimmed(_ text: String) -> String {
        let edge = CharacterSet.whitespaces.union(CharacterSet(charactersIn: ".-–"))
        return text.trimmingCharacters(in: edge)
    }
}
