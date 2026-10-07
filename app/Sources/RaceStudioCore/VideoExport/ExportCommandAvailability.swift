import Foundation

/// Why *Export Video with Overlay…* is disabled (issue 9.14).
public enum ExportUnavailableReason: Equatable, Sendable {
    /// No video is attached to the workspace.
    case noVideo
    /// The workspace's video could not be opened (moved or deleted).
    case videoUnavailable
    /// The session's telemetry is not loaded yet — Video + Data loads it.
    case noTelemetry
    /// An export is already running; one runs at a time.
    case exportRunning
}

/// Whether *Export Video with Overlay…* (⌥⌘E) and the Video + Data panel's
/// export button are enabled (issue 9.14), and their tooltip.
///
/// A video that was never synced, or only from its file date, still exports:
/// the sheet opens with a warning and a *Sync First* button instead.
public enum ExportCommandAvailability: Equatable, Sendable {
    /// Enabled; `syncWarning` when the sheet must warn that the video isn't synced.
    case available(syncWarning: Bool)
    /// Disabled, for this reason.
    case unavailable(ExportUnavailableReason)

    /// The command's state. A running export disables it first, then a
    /// missing video, a video that doesn't open, and telemetry not yet loaded.
    public static func evaluate(hasVideo: Bool, videoOpens: Bool, hasTelemetry: Bool, status: SyncStatus,
                                isExporting: Bool) -> ExportCommandAvailability {
        if isExporting { return .unavailable(.exportRunning) }
        if !hasVideo { return .unavailable(.noVideo) }
        if !videoOpens { return .unavailable(.videoUnavailable) }
        if !hasTelemetry { return .unavailable(.noTelemetry) }
        return .available(syncWarning: status == .notSynced || status == .estimated)
    }

    /// Whether the command can be chosen.
    public var isEnabled: Bool {
        if case .available = self { return true }
        return false
    }

    /// The tooltip: what the command does, or why it can't be chosen.
    public func help(locale: Locale = .current) -> String {
        switch self {
        case .available: return L10n.string(.exportHelpAvailable, locale: locale)
        case .unavailable(.noVideo): return L10n.string(.exportUnavailableNoVideo, locale: locale)
        case .unavailable(.videoUnavailable): return L10n.string(.exportUnavailableVideoMissing, locale: locale)
        case .unavailable(.noTelemetry): return L10n.string(.exportUnavailableNoTelemetry, locale: locale)
        case .unavailable(.exportRunning): return L10n.string(.exportUnavailableRunning, locale: locale)
        }
    }
}
