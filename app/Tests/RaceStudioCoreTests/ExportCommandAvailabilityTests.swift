import Foundation
import Testing
@testable import RaceStudioCore

/// When *Export Video with Overlay…* (⌥⌘E) and the Video + Data panel's
/// button are enabled (issue 9.14): only with footage that opens and the
/// session's telemetry loaded, and never while an export is running. An
/// unsynced video still exports — the sheet warns about it instead.
@Suite struct ExportCommandAvailabilityTests {

    private let english = Locale(identifier: "en")

    private func evaluate(hasVideo: Bool = true, videoOpens: Bool = true, hasTelemetry: Bool = true,
                          status: SyncStatus = .anchored(lap: LapID(2)),
                          isExporting: Bool = false) -> ExportCommandAvailability {
        ExportCommandAvailability.evaluate(hasVideo: hasVideo, videoOpens: videoOpens, hasTelemetry: hasTelemetry,
                                           status: status, isExporting: isExporting)
    }

    /// A synced video with its telemetry in: enabled, no warning.
    @Test func test_a_synced_video_can_be_exported() {
        let availability = evaluate()

        #expect(availability == .available(syncWarning: false))
        #expect(availability.isEnabled)
    }

    /// Every confirmed sync counts as synced.
    @Test func test_every_confirmed_sync_needs_no_warning() {
        let confirmed: [SyncStatus] = [.anchored(lap: nil), .anchored(lap: LapID(0)),
                                       .twoPoint(lapA: LapID(1), lapB: LapID(9)), .autoAudio(confidence: 0.9)]

        #expect(confirmed.map { evaluate(status: $0) } == Array(repeating: .available(syncWarning: false),
                                                                     count: confirmed.count))
    }

    /// Never synced, or only guessed from the file date: still enabled, and
    /// the sheet opens with the sync warning.
    @Test func test_an_unsynced_video_opens_the_sheet_with_a_warning() {
        #expect(evaluate(status: .notSynced) == .available(syncWarning: true))
        #expect(evaluate(status: .estimated) == .available(syncWarning: true))
        #expect(evaluate(status: .notSynced).isEnabled)
    }

    /// No video attached: disabled, saying where to attach one.
    @Test func test_without_a_video_the_command_is_disabled() {
        let availability = evaluate(hasVideo: false, status: .notSynced)

        #expect(availability == .unavailable(.noVideo))
        #expect(!availability.isEnabled)
        #expect(availability.help(locale: english) == "Attach the session’s video in Video + Data first.")
    }

    /// A workspace video that moved or was deleted cannot be exported.
    @Test func test_a_video_that_does_not_open_disables_the_command() {
        #expect(evaluate(videoOpens: false) == .unavailable(.videoUnavailable))
    }

    /// The telemetry is loaded when Video + Data is first shown.
    @Test func test_without_telemetry_the_command_is_disabled() {
        #expect(evaluate(hasTelemetry: false) == .unavailable(.noTelemetry))
    }

    /// One export at a time — whatever else is true.
    @Test func test_a_running_export_disables_the_command() {
        #expect(evaluate(isExporting: true) == .unavailable(.exportRunning))
        #expect(evaluate(hasVideo: false, isExporting: true) == .unavailable(.exportRunning))
    }

    /// Every state has a tooltip in English and Portuguese; the enabled one
    /// names the shortcut.
    @Test func test_every_state_has_a_tooltip_in_both_languages() {
        let states: [ExportCommandAvailability] = [.available(syncWarning: false), .available(syncWarning: true),
                                                   .unavailable(.noVideo), .unavailable(.videoUnavailable),
                                                   .unavailable(.noTelemetry), .unavailable(.exportRunning)]

        for locale in [english, Locale(identifier: "pt-BR")] {
            let tips = states.map { $0.help(locale: locale) }
            #expect(!tips.contains { $0.isEmpty || L10n.isFlagged($0) }, "\(tips)")
        }
        #expect(ExportCommandAvailability.available(syncWarning: false).help(locale: english).contains("⌥⌘E"))
        #expect(ExportCommandAvailability.unavailable(.exportRunning).help(locale: Locale(identifier: "pt-BR"))
                == "Já há uma exportação em andamento.")
    }
}
