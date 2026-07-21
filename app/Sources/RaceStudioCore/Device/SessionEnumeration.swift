#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// The catalog/session-list request bytes the MyChron answers with its on-device
/// session catalog (issue 6.4) — the observed request frame, built by the Rust
/// core so the wire format stays single-sourced with `docs/device/PROTOCOL.md`.
///
/// The 6.5 download step writes these bytes to the control connection.
public func sessionListRequest() -> Data {
    buildSessionListRequest()
}

/// Parse a recorded/observed catalog/session-list response into typed sessions
/// via the Rust core (issue 6.4).
///
/// The response frame's checksum is verified before parsing; an empty on-device
/// store yields an empty array (never an error).
///
/// - Throws: ``DiscoveryError`` — `.BadChecksum` if the frame fails checksum
///   verification, `.TruncatedList` if it is incomplete, or `.MalformedRecord`
///   for a bad record.
public func parseSessions(_ bytes: Data) throws -> [SessionInfo] {
    try parseSessionList(bytes: bytes)
}
#endif
