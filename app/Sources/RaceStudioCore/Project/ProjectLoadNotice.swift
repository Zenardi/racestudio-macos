import Foundation

/// What a project load could not read, said once (issue 9.12): the
/// ``ProjectDocument/warnings`` (skipped overlay entries, unresolved sessions,
/// clamped lap selections) and the invalid math channels in its
/// ``ProjectDocument/diagnostics``. The workspace bar shows the ``summary(locale:)``
/// unobtrusively, with the ``details(locale:)`` on demand — a lossy load is
/// never silent, and a clean one says nothing.
public struct ProjectLoadNotice: Equatable, Sendable {

    private let warnings: [ProjectLoadWarning]
    private let diagnostics: [ProjectError]

    /// The notice for a loaded `document`, or `nil` when it loaded cleanly.
    public init?(document: ProjectDocument) {
        self.init(warnings: document.loadWarnings, diagnostics: document.diagnostics)
    }

    /// The notice for `warnings` and `diagnostics`, or `nil` when there are none
    /// — e.g. a saved workspace that couldn't be read at all (issue 9.20).
    public init?(warnings: [ProjectLoadWarning], diagnostics: [ProjectError] = []) {
        guard !warnings.isEmpty || !diagnostics.isEmpty else { return nil }
        self.warnings = warnings
        self.diagnostics = diagnostics
    }

    /// "Opened with 3 warnings".
    public func summary(locale: Locale = .current) -> String {
        let count = warnings.count + diagnostics.count
        return count == 1
            ? L10n.string(.projectNoticeOne, locale: locale)
            : L10n.format(.projectNoticeOther, locale: locale, String(count))
    }

    /// Each thing that could not be read, one line each, in `locale`: the
    /// warnings, then the diagnostics — an invalid math channel by name,
    /// anything else in plain words.
    public func details(locale: Locale = .current) -> [String] {
        warnings.map { $0.label(locale: locale) } + diagnostics.map { diagnostic in
            if case .invalidMathChannel(let name) = diagnostic {
                return L10n.format(.projectNoticeInvalidMathChannel, locale: locale, name)
            }
            return L10n.string(.projectNoticeUnreadablePart, locale: locale)
        }
    }
}
