#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// Download a session by reassembling its checksum-verified chunk stream (issue 6.5).
///
/// `source` supplies the raw STCP chunk frames — the live `NWConnection` transport
/// in the device panel (6.7), or a recorded replay in tests; `progress` receives
/// byte-progress so a UI can render a progress bar. The reassembled bytes are a
/// decodable `.xrk` (validated end-to-end against the M1 decoder in the Rust
/// `racestudio-device` transfer tests).
///
/// Throws a ``DiscoveryError`` — `.ChecksumMismatch` (a chunk stayed corrupt past
/// the retry budget, or the whole-file checksum failed), `.MissingChunk` (the
/// stream ended with a gap), or `.MalformedRecord` (a chunk overran the declared
/// size) — never surfacing a partial file as success, and never trapping.
///
/// Named distinctly from the generated `downloadSession` so a caller can import
/// both `RaceStudioCore` and `RaceStudioFFIBindings` without ambiguity.
public func downloadSessionFile(
    plan: DownloadPlan,
    source: ChunkSource,
    progress: DownloadProgress
) throws -> Data {
    try RaceStudioFFIBindings.downloadSession(plan: plan, source: source, progress: progress)
}
#endif
