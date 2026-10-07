import Foundation
import Testing
@testable import RaceStudioCore

/// The file name the export's save panel suggests (issue 9.14): track, date
/// and what was exported — `S.Marino AR – 2026-09-25 – Lap 9 (0'40.774).mp4` —
/// made safe for any volume: no `/` or `:` (the path separators of POSIX and
/// of the Finder), no control or bidirectional-override characters, no
/// leading dot, at most 120 characters and 255 UTF-8 bytes, accents kept.
@Suite struct ExportFileNameTests {

    private let english = Locale(identifier: "en")
    private let portuguese = Locale(identifier: "pt-BR")

    // MARK: - The suggested name

    /// A lap export names the track, the session's date, the lap (1-based) and
    /// its time — written `0'40.774`, the timing-sheet form, since a colon
    /// cannot appear in a file name.
    @Test func test_a_lap_export_is_named_after_track_date_and_lap() {
        let name = ExportSheetModel.suggestedFileName(track: "S.Marino AR", date: "2026-09-25", lap: LapID(8),
                                                      lapTime: 40.774, locale: english)

        #expect(name == "S.Marino AR – 2026-09-25 – Lap 9 (0'40.774).mp4")
    }

    /// The lap is named in the export's language.
    @Test func test_the_lap_is_named_in_the_locale() {
        let name = ExportSheetModel.suggestedFileName(track: "Interlagos", date: "2026-03-01", lap: LapID(2),
                                                      lapTime: 62.345, locale: portuguese)

        #expect(name == "Interlagos – 2026-03-01 – Volta 3 (1'02.345).mp4")
    }

    /// Without a lap, a time or a date, the name keeps what it has.
    @Test func test_missing_parts_are_left_out() {
        #expect(ExportFileName.suggested(track: "Adria Kart", date: nil, subject: "Session")
                == "Adria Kart – Session.mp4")
        #expect(ExportFileName.suggested(track: "", date: "2026-01-23", subject: "Session")
                == "2026-01-23 – Session.mp4")
        #expect(ExportSheetModel.suggestedFileName(track: "Adria", date: nil, lap: LapID(0), lapTime: .nan,
                                                   locale: english) == "Adria – Lap 1.mp4")
    }

    /// A name with nothing usable left still names a file.
    @Test func test_an_empty_name_falls_back() {
        #expect(ExportFileName.sanitized("") == "RaceStudio Export.mp4")
        #expect(ExportFileName.sanitized(" /:\u{0007} ") == "RaceStudio Export.mp4")
    }

    // MARK: - Sanitising

    /// `/` and `:` become hyphens, so `A/B` stays two words apart.
    @Test func test_slashes_and_colons_are_replaced() {
        #expect(ExportFileName.sanitized("Interlagos 1/2: Treino") == "Interlagos 1-2- Treino.mp4")
    }

    /// Control characters — a tab, a newline, a NUL — and the invisible
    /// bidirectional overrides that could disguise a name are removed; the
    /// words they separated stay apart.
    @Test func test_control_characters_are_stripped() {
        let name = ExportFileName.sanitized("Track\tName\nTwo\u{0000}\u{202E}gpj.exe")

        #expect(name == "Track Name Two gpj.exe.mp4")
        #expect(!name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
    }

    /// A leading dot would hide the file; runs of spaces collapse.
    @Test func test_leading_dots_and_extra_spaces_are_trimmed() {
        #expect(ExportFileName.sanitized("..  hidden   lap  . ") == "hidden lap.mp4")
    }

    /// Accented Portuguese letters are kept exactly.
    @Test func test_accents_are_preserved() {
        let name = ExportFileName.sanitized("Autódromo José Carlos Pace – Sessão de classificação")

        #expect(name == "Autódromo José Carlos Pace – Sessão de classificação.mp4")
    }

    /// The whole name, extension included, is capped at 120 characters, and
    /// the extension survives the cut.
    @Test func test_the_name_is_capped_at_120_characters() {
        let long = String(repeating: "Autódromo ", count: 30)

        let name = ExportFileName.sanitized(long)

        #expect(name.count == 120)
        #expect(name.hasSuffix(" Autódr.mp4"))
    }

    /// A cut that lands just after a separator does not leave it dangling.
    @Test func test_the_cut_trims_a_dangling_separator() {
        let long = String(repeating: "a", count: 114) + " – tail"

        let name = ExportFileName.sanitized(long)

        #expect(name == String(repeating: "a", count: 114) + ".mp4")
    }

    /// A name of wide characters is cut to 255 UTF-8 bytes — the longest file
    /// name APFS and HFS+ take — even below 120 characters.
    @Test func test_the_name_fits_the_file_system() {
        let wide = String(repeating: "鈴鹿", count: 60)

        let name = ExportFileName.sanitized(wide)

        #expect(name.utf8.count <= 255)
        #expect(name.hasSuffix(".mp4"))
    }

    // MARK: - Parts

    /// The lap time in the timing-sheet form, hours included past one hour; an
    /// invalid time has none.
    @Test func test_lap_times_are_written_without_a_colon() {
        #expect(ExportFileName.lapTime(40.774) == "0'40.774")
        #expect(ExportFileName.lapTime(3_661.5) == "1h01'01.500")
        #expect(ExportFileName.lapTime(-1) == nil)
        #expect(ExportFileName.lapTime(.infinity) == nil)
    }

    /// The session's date as `yyyy-MM-dd`: the logger's own date, else the UTC
    /// day of its start, else none.
    @Test func test_the_date_comes_from_the_log() {
        #expect(ExportFileName.date(logDate: "09/25/2026", datetimeUtc: 0) == "2026-09-25")
        #expect(ExportFileName.date(logDate: "", datetimeUtc: 1_453_550_944) == "2016-01-23")
        #expect(ExportFileName.date(logDate: "13/45/2026", datetimeUtc: 0) == nil)
        #expect(ExportFileName.date(logDate: "garbage", datetimeUtc: 0) == nil)
    }
}
