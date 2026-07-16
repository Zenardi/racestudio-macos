import Foundation

/// A decode failure surfaced across the load boundary (issue 2.5).
///
/// This is `RaceStudioCore`'s own error domain, mirroring the 1.7 FFI
/// `FfiDecodeError` cases but independent of the generated bindings — the gated
/// `FFISessionLoader` translates the FFI error into this, so the store's error
/// handling and `ImportError` mapping stay pure and fully testable.
public enum DecodeError: Error, Equatable, Sendable {
    /// The file could not be read from disk.
    case io(message: String)
    /// The file does not begin with the `.xrk` header magic.
    case badMagic
    /// The first header message is cut short.
    case truncatedHeader
    /// A channel data message's samples run past end-of-file.
    case truncatedChannel
    /// A multi-sample burst declared an invalid sample count.
    case badSampleCount
    /// The GPS stream is not a whole number of records.
    case truncatedGps
    /// A lap marker is too short for its timing fields.
    case truncatedLaps
    /// A `samples(...)` call named a channel index outside `0..<channelCount`.
    case channelOutOfRange(index: UInt32, channelCount: UInt32)
    /// Any decode error the boundary does not distinguish (keeps the mapping
    /// total against the `#[non_exhaustive]` Rust `DecodeError`).
    case other(message: String)
}
