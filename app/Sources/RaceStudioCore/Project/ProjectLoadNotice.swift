import Foundation

/// What a project load could not read, said once (issue 9.12): the
/// ``ProjectDocument/warnings`` (skipped overlay entries, unresolved sessions,
/// clamped lap selections) and the invalid math channels in its
/// ``ProjectDocument/diagnostics``. The workspace bar shows the ``summary(locale:)``
/// unobtrusively, with the ``details(locale:)`` on demand — a lossy load is
/// never silent, and a clean one says nothing.
public struct ProjectLoadNotice: Equatable, Sendable {

    private let warnings: [String]
    private let diagnostics: [ProjectError]

    /// The notice for a loaded `document`, or `nil` when it loaded cleanly.
    public init?(document: ProjectDocument) {
        guard !document.warnings.isEmpty || !document.diagnostics.isEmpty else { return nil }
        self.warnings = document.warnings
        self.diagnostics = document.diagnostics
    }

    /// "Opened with 3 warnings".
    public func summary(locale: Locale = .current) -> String {
        let count = warnings.count + diagnostics.count
        return count == 1
            ? L10n.string(.projectNoticeOne, locale: locale)
            : L10n.format(.projectNoticeOther, locale: locale, String(count))
    }

    /// Each thing that could not be read, one line each: the warnings, then the
    /// invalid math channels.
    public func details(locale: Locale = .current) -> [String] {
        warnings + diagnostics.map { diagnostic in
            if case .invalidMathChannel(let name) = diagnostic {
                return L10n.format(.projectNoticeInvalidMathChannel, locale: locale, name)
            }
            return String(describing: diagnostic)
        }
    }
}
