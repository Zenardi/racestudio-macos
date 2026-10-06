import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `ProjectLoadNotice` (issue 9.12): what a project load could not
/// read — skipped overlay entries, unresolved sessions, invalid math channels —
/// is said once, unobtrusively, rather than dropped on the floor.
@Suite struct ProjectLoadNoticeTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private func document(warnings: [String] = [], diagnostics: [ProjectError] = []) -> ProjectDocument {
        var document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time))
        document.warnings = warnings
        document.diagnostics = diagnostics
        return document
    }

    /// A clean load has nothing to say.
    @Test func test_a_clean_load_has_no_notice() {
        #expect(ProjectLoadNotice(document: document()) == nil)
    }

    /// One warning is said in the singular, in the reader's language.
    @Test func test_one_warning_is_counted_in_the_singular() throws {
        let notice = try #require(ProjectLoadNotice(document: document(
            warnings: ["video overlay: 1 unreadable entry skipped"])))

        #expect(notice.summary(locale: en) == "Opened with 1 warning")
        #expect(notice.summary(locale: ptBR) == "Aberto com 1 aviso")
        #expect(notice.details(locale: en) == ["video overlay: 1 unreadable entry skipped"])
    }

    /// Warnings and invalid math channels are counted together and each listed.
    @Test func test_warnings_and_invalid_channels_are_listed() throws {
        let notice = try #require(ProjectLoadNotice(document: document(
            warnings: ["unresolved session reference: s9", "clamped lap selection for session s1"],
            diagnostics: [.invalidMathChannel(name: "Grip")])))

        #expect(notice.summary(locale: en) == "Opened with 3 warnings")
        #expect(notice.summary(locale: ptBR) == "Aberto com 3 avisos")
        #expect(notice.details(locale: en) == ["unresolved session reference: s9",
                                               "clamped lap selection for session s1",
                                               "Math channel “Grip” has an invalid expression"])
    }

    /// A diagnostic that is not about a math channel is still counted, plainly.
    @Test func test_other_diagnostics_are_listed_plainly() throws {
        let notice = try #require(ProjectLoadNotice(document: document(diagnostics: [.ioFailure])))

        #expect(notice.details(locale: en) == ["ioFailure"])
    }
}
