import Testing
import Foundation

@testable import RaceStudioCore

/// Tests for `ProjectLoadNotice` (issue 9.12): what a project load could not
/// read — skipped overlay entries, unresolved sessions, invalid math channels —
/// is said once, unobtrusively and in the reader's language, rather than
/// dropped on the floor.
@Suite struct ProjectLoadNoticeTests {

    private let en = Locale(identifier: "en_US")
    private let ptBR = Locale(identifier: "pt_BR")

    private func document(warnings: [ProjectLoadWarning] = [], diagnostics: [ProjectError] = []) -> ProjectDocument {
        var document = ProjectDocument(layout: AnalysisLayout(panes: [], xAxisMode: .time))
        document.loadWarnings = warnings
        document.diagnostics = diagnostics
        return document
    }

    /// A clean load has nothing to say.
    @Test func test_a_clean_load_has_no_notice() {
        #expect(ProjectLoadNotice(document: document()) == nil)
    }

    /// One warning is said in the singular, in the reader's language.
    @Test func test_one_warning_is_counted_in_the_singular() throws {
        let notice = try #require(ProjectLoadNotice(document: document(warnings: [.skippedOverlayEntries(1)])))

        #expect(notice.summary(locale: en) == "Opened with 1 warning")
        #expect(notice.summary(locale: ptBR) == "Aberto com 1 aviso")
        #expect(notice.details(locale: en) == ["Video overlay: 1 unreadable entry skipped"])
        #expect(notice.details(locale: ptBR) == ["Sobreposição de vídeo: 1 item ilegível ignorado"])
    }

    /// Warnings and invalid math channels are counted together and each listed.
    @Test func test_warnings_and_invalid_channels_are_listed() throws {
        let notice = try #require(ProjectLoadNotice(document: document(
            warnings: [.unresolvedSession("s9"), .clampedLapSelection("s1")],
            diagnostics: [.invalidMathChannel(name: "Grip")])))

        #expect(notice.summary(locale: en) == "Opened with 3 warnings")
        #expect(notice.summary(locale: ptBR) == "Aberto com 3 avisos")
        #expect(notice.details(locale: en) == ["A session this workspace uses isn’t in the library (s9)",
                                               "Some saved laps of session s1 no longer exist and were skipped",
                                               "Math channel “Grip” has an invalid expression"])
    }

    /// Every kind of warning reads in both languages.
    @Test(arguments: [ProjectLoadWarning.unresolvedSession("s"), .clampedLapSelection("s"), .unreadableOverlay,
                      .skippedOverlayEntries(1), .skippedOverlayEntries(4)])
    func test_every_warning_is_localized(warning: ProjectLoadWarning) {
        for locale in [en, ptBR] {
            #expect(!L10n.isFlagged(warning.label(locale: locale)))
        }
        #expect(warning.label(locale: en) != warning.label(locale: ptBR))
    }

    /// A load's warnings keep their log text, as the store has always written it.
    @Test func test_the_log_text_is_unchanged() {
        #expect(ProjectLoadWarning.unresolvedSession("s9").text == "unresolved session reference: s9")
        #expect(ProjectLoadWarning.clampedLapSelection("s1").text == "clamped lap selection for session s1")
        #expect(ProjectLoadWarning.unreadableOverlay.text == "unreadable video overlay; opened with the overlay off")
        #expect(ProjectLoadWarning.skippedOverlayEntries(2).text == "video overlay: 2 unreadable entries skipped")
        #expect(document(warnings: [.skippedOverlayEntries(1)]).warnings
                == ["video overlay: 1 unreadable entry skipped"])
    }

    /// A diagnostic that is not about a math channel is still counted, in plain
    /// words in the reader's language — never a type name.
    @Test func test_other_diagnostics_are_listed_in_plain_words() throws {
        let notice = try #require(ProjectLoadNotice(document: document(diagnostics: [.ioFailure])))

        #expect(notice.details(locale: en) == ["Part of the workspace could not be read"])
        #expect(notice.details(locale: ptBR) == ["Parte do espaço de trabalho não pôde ser lida"])
    }
}
