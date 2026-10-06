import Foundation

/// Something a project load could not read in full (issue 9.12) — typed, so the
/// workspace bar can say it in the reader's language (``label(locale:)``) while
/// the log keeps the store's own wording (``text``).
public enum ProjectLoadWarning: Equatable, Sendable {
    /// The library has no session with this content id.
    case unresolvedSession(String)
    /// Lap indices beyond this session's laps were dropped from its selection.
    case clampedLapSelection(String)
    /// The video overlay was not a layout at all; the workspace opened with it off.
    case unreadableOverlay
    /// This many widgets or settings of the overlay could not be read.
    case skippedOverlayEntries(Int)

    /// The warning as the store has always logged it, in English.
    public var text: String {
        switch self {
        case .unresolvedSession(let id): return "unresolved session reference: \(id)"
        case .clampedLapSelection(let id): return "clamped lap selection for session \(id)"
        case .unreadableOverlay: return "unreadable video overlay; opened with the overlay off"
        case .skippedOverlayEntries(let count):
            return "video overlay: \(count) unreadable \(count == 1 ? "entry" : "entries") skipped"
        }
    }

    /// The warning as the operator reads it, in `locale`.
    public func label(locale: Locale = .current) -> String {
        switch self {
        case .unresolvedSession(let id): return L10n.format(.projectWarningUnresolvedSession, locale: locale, id)
        case .clampedLapSelection(let id): return L10n.format(.projectWarningClampedLaps, locale: locale, id)
        case .unreadableOverlay: return L10n.string(.projectWarningUnreadableOverlay, locale: locale)
        case .skippedOverlayEntries(let count):
            return count == 1
                ? L10n.string(.projectWarningSkippedOverlayOne, locale: locale)
                : L10n.format(.projectWarningSkippedOverlayOther, locale: locale, String(count))
        }
    }
}
