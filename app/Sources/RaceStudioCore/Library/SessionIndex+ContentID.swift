import CryptoKit
import Foundation

extension SessionIndex {
    /// A stable, deterministic content id for `session` — a SHA-256 over its
    /// metadata, laps, and channel listing. Two decodes of the same file hash
    /// identically (so re-adding updates rather than duplicates); different
    /// content hashes differently. Deterministic across process runs, unlike
    /// `Hashable`, so it is safe to persist as a key.
    ///
    /// Every field is **length-prefixed** into the hash so the encoding is
    /// injective: a `|`/`:`/newline inside a value (e.g. a track named `"A|B"`)
    /// can never forge the field boundaries of a genuinely different session.
    public static func contentID(for session: Session) -> String {
        var hasher = SHA256()
        func feed(_ value: String) {
            var length = UInt64(value.utf8.count).littleEndian
            withUnsafeBytes(of: &length) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data(value.utf8))
        }
        let metadata = session.metadata
        for field in [metadata.vehicle, metadata.track, metadata.driver,
                      metadata.session, metadata.series, metadata.logDate,
                      metadata.logTime, String(metadata.datetimeUtc)] {
            feed(field)
        }
        feed(String(session.laps.count))
        for lap in session.laps {
            feed(String(lap.index)); feed(String(lap.startTimeS))
            feed(String(lap.durationS)); feed(String(lap.endTimeS))
        }
        feed(String(session.channels.count))
        for channel in session.channels {
            feed(channel.name); feed(channel.unit); feed(String(channel.sampleRateHz))
            feed(String(channel.decimals)); feed(String(channel.sampleCount))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
