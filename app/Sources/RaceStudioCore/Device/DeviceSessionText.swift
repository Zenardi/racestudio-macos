#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// A stored session is identified by its on-device file name (issue #179), so
/// the session table can select rows by it.
extension DeviceSession: Identifiable {
    public var id: String { fileName }
}

extension DeviceClock {
    /// The clock handed to the device on connect: `date` as wall-clock time in
    /// `timeZone`, and the same instant in UTC (issue #179).
    public init(date: Date, timeZone: TimeZone) {
        func fields(in zone: TimeZone) -> RaceStudioFFIBindings.SessionDate {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = zone
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return RaceStudioFFIBindings.SessionDate(
                year: UInt16(c.year ?? 0), month: UInt8(c.month ?? 0), day: UInt8(c.day ?? 0),
                hour: UInt8(c.hour ?? 0), minute: UInt8(c.minute ?? 0), second: UInt8(c.second ?? 0))
        }
        self.init(local: fields(in: timeZone), utc: fields(in: TimeZone(identifier: "UTC") ?? .gmt))
    }
}

/// How the device panel presents a session stored on the MyChron (issue #179),
/// and the name a downloaded copy gets in the library.
public enum DeviceSessionText {

    /// The longest track label kept in a library file name, so the name stays
    /// well inside the file system's 255-byte limit.
    static let maxLabelLength = 100

    /// Shown when a field is empty or was not recorded.
    public static let placeholder = LapTimeFormatter.placeholder

    /// `2025-07-11 17:45:28` (the logger's local time).
    public static func date(_ session: DeviceSession) -> String {
        let d = session.date
        return String(format: "%04d-%02d-%02d %02d:%02d:%02d",
                      d.year, d.month, d.day, d.hour, d.minute, d.second)
    }

    /// The track the logger matched, or a placeholder.
    public static func track(_ session: DeviceSession) -> String {
        session.trackName.isEmpty ? placeholder : session.trackName
    }

    /// The best lap as `0:53.951 (lap 2)`, or a placeholder when none was timed.
    public static func bestLap(_ session: DeviceSession) -> String {
        guard let millis = session.bestLapMs else { return placeholder }
        let time = LapTimeFormatter.string(from: Double(millis) / 1000)
        guard let lap = session.bestLapNumber else { return time }
        return "\(time) (lap \(lap))"
    }

    /// The session's length as `21:34` (or `1:02:03`), or a placeholder.
    public static func duration(_ session: DeviceSession) -> String {
        guard let millis = session.durationMs else { return placeholder }
        let seconds = Int(millis / 1000)
        let (hours, minutes, secs) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The stored size in decimal units: `3.9 MB`, `62 KB`, `512 B`.
    public static func size(_ session: DeviceSession) -> String {
        let bytes = Double(session.sizeBytes)
        if bytes >= 1_000_000 { return String(format: "%.1f MB", bytes / 1_000_000) }
        if bytes >= 1_000 { return String(format: "%.0f KB", bytes / 1_000) }
        return "\(session.sizeBytes) B"
    }

    /// The file name a downloaded copy is imported under:
    /// `2025-07-11 17-45-28 Track.xrk`, falling back to the device's own name
    /// when the logger recorded no track. Path separators and colons are
    /// replaced, control characters too, and the label is capped at
    /// ``maxLabelLength`` characters, so the name is always a single,
    /// Finder-safe component.
    public static func libraryFileName(_ session: DeviceSession) -> String {
        let d = session.date
        let stamp = String(format: "%04d-%02d-%02d %02d-%02d-%02d",
                           d.year, d.month, d.day, d.hour, d.minute, d.second)
        let label = session.trackName.isEmpty
            ? (session.fileName as NSString).deletingPathExtension
            : session.trackName
        let safe = label.prefix(maxLabelLength).map { character -> Character in
            let unsafe = "/:\\".contains(character)
                || character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
            return unsafe ? "-" : character
        }
        return "\(stamp) \(String(safe)).xrk"
    }
}
#endif
