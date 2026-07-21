#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Delete a session from the device behind every safety guard (issue 6.6).
///
/// Only the guarded API is exposed: the delete refuses — transmitting **zero
/// bytes** — unless `armed` is `true` **and** `confirmation` matches `target`
/// (both id and name). Only then is exactly one delete frame sent via `channel`
/// (the live `NWConnection` transport in the 6.7 device panel, or a recorded
/// replay in tests), and the device's ack/reject interpreted; a non-ack is a
/// thrown ``DiscoveryError`` and is never blindly retried (no double-delete).
///
/// Throws a ``DiscoveryError`` — `.NotArmed` / `.ConfirmationMismatch` (nothing
/// was sent), `.DeleteRejected` (the device refused), or `.BadChecksum` /
/// `.TruncatedList` (the response frame did not verify) — never trapping.
///
/// Named distinctly from the generated `deleteSession` so a caller can import
/// both `RaceStudioCore` and `RaceStudioFFIBindings` without ambiguity.
public func deleteSessionFile(
    target: SessionInfo,
    confirmation: DeleteConfirmation?,
    armed: Bool,
    channel: DeleteChannel
) throws {
    try RaceStudioFFIBindings.deleteSession(
        target: target,
        confirmation: confirmation,
        armed: armed,
        channel: channel
    )
}
#endif
