import Foundation

/// A user-facing import failure (issue 2.5): a short `title`, a `message`, and an
/// optional `recoverySuggestion`. The shell renders these directly in an
/// `.alert`, so no decode detail leaks into the UI.
public struct ImportError: Error, Equatable, Sendable {
    public let title: String
    public let message: String
    public let recoverySuggestion: String?

    public init(title: String, message: String, recoverySuggestion: String? = nil) {
        self.title = title
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    /// Map every ``DecodeError`` to a distinct, non-empty message — with a
    /// recovery suggestion where the user can actually act — keeping the mapping
    /// total, including the catch-all ``DecodeError/other(message:)``.
    public init(decodeError: DecodeError) {
        let reExport = "The file looks truncated — try re-exporting it from RaceStudio."
        switch decodeError {
        case let .io(message):
            self.init(
                title: "Couldn't Read File",
                message: "The file couldn't be read from disk: \(message).",
                recoverySuggestion: "Check that the file still exists and that you have permission to open it.")
        case .badMagic:
            self.init(
                title: "Unsupported File",
                message: "This file isn't a recognized AiM telemetry file.",
                recoverySuggestion: "Make sure you're opening a .xrk or .xrz file.")
        case .truncatedHeader:
            self.init(title: "Corrupt File", message: "The file's header is incomplete.", recoverySuggestion: reExport)
        case .truncatedChannel:
            self.init(
                title: "Corrupt File",
                message: "A channel's samples run past the end of the file.",
                recoverySuggestion: reExport)
        case .badSampleCount:
            self.init(
                title: "Corrupt File",
                message: "A data burst declared an invalid sample count.",
                recoverySuggestion: reExport)
        case .truncatedGps:
            self.init(title: "Corrupt File", message: "The GPS data is incomplete.", recoverySuggestion: reExport)
        case .truncatedLaps:
            self.init(title: "Corrupt File", message: "The lap markers are incomplete.", recoverySuggestion: reExport)
        case let .channelOutOfRange(index, channelCount):
            self.init(
                title: "Decode Error",
                message: "Requested channel \(index) of \(channelCount).",
                recoverySuggestion: nil)
        case let .other(message):
            self.init(
                title: "Import Failed",
                message: message.isEmpty
                    ? "The file couldn't be decoded."
                    : "The file couldn't be decoded: \(message).",
                recoverySuggestion: nil)
        }
    }
}
