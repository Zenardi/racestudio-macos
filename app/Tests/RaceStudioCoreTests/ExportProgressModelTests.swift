import Foundation
import Testing
@testable import RaceStudioCore

/// The export's progress sheet (issue 9.14): it follows the exporter's
/// progress stream — the percent, the frames, the time elapsed and a smoothed
/// estimate of the time left — through `.running`, `.cancelling`, and an end:
/// `.finished(url)`, `.failed(error)`, or back to `.idle` once a cancel has
/// cleaned up.
@MainActor
@Suite struct ExportProgressModelTests {

    private let destination = URL(fileURLWithPath: "/tmp/out.mp4")
    private let english = Locale(identifier: "en")
    private let portuguese = Locale(identifier: "pt-BR")

    private func event(_ done: Int, of total: Int = 100, at elapsed: TimeInterval,
                       phase: ExportPhase = .encoding) -> ExportProgress {
        ExportProgress(framesDone: done, totalFrames: total, elapsed: elapsed, phase: phase)
    }

    // MARK: - States

    /// Before any export the sheet is idle.
    @Test func test_a_new_model_is_idle() {
        let model = ExportProgressModel()

        #expect(model.state == .idle)
        #expect(!model.isActive)
        #expect(model.progress == nil)
    }

    /// Progress keeps the model running and shows the latest event; a stream
    /// that ends leaves the file finished at its destination.
    @Test func test_a_successful_export_finishes_at_its_destination() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()

        model.start(stream, to: destination, cancel: {})
        #expect(model.state == .running)
        #expect(model.isActive)
        continuation.yield(event(40, at: 1))
        continuation.yield(event(100, at: 2.5, phase: .complete))
        continuation.finish()
        await model.wait()

        #expect(model.state == .finished(destination))
        #expect(!model.isActive)
        #expect(model.progress == event(100, at: 2.5, phase: .complete))
    }

    /// Cancel asks the exporter to stop and shows "Cancelling…"; when the
    /// exporter reports the cancel — its files removed — the sheet is idle.
    @Test func test_a_cancelled_export_returns_to_idle() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        let asked = CancelRecorder()

        model.start(stream, to: destination, cancel: { await asked.record() })
        continuation.yield(event(10, at: 0.5))
        model.cancel()
        #expect(model.state == .cancelling)
        #expect(model.isActive, "still cleaning up")
        await asked.waitForCall()
        continuation.finish(throwing: OverlayExportError.cancelled)
        await model.wait()

        #expect(model.state == .idle)
        #expect(model.progress == nil)
    }

    /// A failure is kept, typed, for the sheet to explain.
    @Test func test_a_failed_export_reports_its_error() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        let error = OverlayExportError.insufficientDiskSpace(required: 3_100_000_000, available: 1_200_000_000)

        model.start(stream, to: destination, cancel: {})
        continuation.finish(throwing: error)
        await model.wait()

        #expect(model.state == .failed(error))
        #expect(model.failureMessage(locale: english)
                == ExportUserMessage(title: "Not enough disk space — 3.1 GB needed, 1.2 GB free",
                                     fix: "Free up space on that disk, or save the video to another one."))
    }

    /// Anything else the stream throws is a typed failure too.
    @Test func test_an_untyped_failure_is_mapped() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()

        model.start(stream, to: destination, cancel: {})
        continuation.finish(throwing: CancellationError())
        await model.wait()

        #expect(model.state == .idle, "a cancelled task is a cancel")
    }

    /// A stream that ends successfully after a cancel was asked for still
    /// finished: the file is in place.
    @Test func test_an_export_finishing_despite_a_cancel_is_finished() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()

        model.start(stream, to: destination, cancel: {})
        model.cancel()
        continuation.finish()
        await model.wait()

        #expect(model.state == .finished(destination))
    }

    /// One export at a time: a second start while one runs is ignored.
    @Test func test_a_second_start_while_running_is_ignored() async {
        let model = ExportProgressModel()
        let (first, firstContinuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        let (second, _) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        let other = URL(fileURLWithPath: "/tmp/other.mp4")

        #expect(model.start(first, to: destination, cancel: {}))
        #expect(!model.start(second, to: other, cancel: {}), "refused")
        firstContinuation.finish()
        await model.wait()

        #expect(model.state == .finished(destination))
    }

    /// Dismissing a finished or failed sheet makes it idle again; dismissing
    /// a running one does nothing.
    @Test func test_dismiss_clears_an_ended_export_only() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        model.start(stream, to: destination, cancel: {})

        model.dismiss()
        #expect(model.state == .running)
        continuation.finish()
        await model.wait()
        model.dismiss()

        #expect(model.state == .idle)
        #expect(model.progress == nil)
    }

    /// Cancel on an idle model changes nothing.
    @Test func test_cancel_when_idle_does_nothing() {
        let model = ExportProgressModel()

        model.cancel()

        #expect(model.state == .idle)
    }

    /// Quitting cancels the export and waits until it has cleaned up.
    @Test func test_cancel_and_wait_returns_once_the_export_has_stopped() async {
        let model = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        model.start(stream, to: destination, cancel: { continuation.finish(throwing: OverlayExportError.cancelled) })

        await model.cancelAndWait()

        #expect(model.state == .idle)
    }

    // MARK: - Time left

    /// No estimate before 3% of the work is done…
    @Test func test_no_estimate_before_three_percent() {
        let model = ExportProgressModel()

        model.receive(event(2, at: 3))

        #expect(model.remaining == nil)
    }

    /// …nor in the first two seconds, however fast it starts.
    @Test func test_no_estimate_in_the_first_two_seconds() {
        let model = ExportProgressModel()

        model.receive(event(10, at: 1))

        #expect(model.remaining == nil)
    }

    /// The first estimate is the pace so far; later ones move only part of the
    /// way toward each new reading, the previous estimate counting down the
    /// time since — 30% of 16.2 s and 70% of (27.3 − 1) s.
    @Test func test_the_estimate_is_smoothed() throws {
        let model = ExportProgressModel()

        model.receive(event(10, at: 3))
        let first = try #require(model.remaining)
        model.receive(event(20, at: 4))
        let second = try #require(model.remaining)

        #expect(abs(first - 27.3) < 0.001)
        #expect(abs(second - 23.27) < 0.001)
    }

    /// While the file is being finished there is no frame pace to go by.
    @Test func test_no_estimate_while_finishing() {
        let model = ExportProgressModel()
        model.receive(event(50, at: 5))

        model.receive(event(100, at: 9, phase: .finishing))

        #expect(model.remaining == nil)
    }

    // MARK: - What the sheet says

    /// The progress line: percent, frames, time elapsed, time left.
    @Test func test_the_status_line_while_encoding() {
        let model = ExportProgressModel()
        model.receive(event(1_234, of: 2_940, at: 31))

        #expect(model.statusLine(locale: english) == "41% · frame 1,234 of 2,940 · 0:31 elapsed · about 0:43 left")
        #expect(model.statusLine(locale: portuguese)
                == "41% · quadro 1.234 de 2.940 · 0:31 decorridos · faltam cerca de 0:43")
    }

    /// Before the estimate settles, and while finishing, the line says so.
    @Test func test_the_status_line_before_an_estimate_and_while_finishing() {
        let early = ExportProgressModel()
        early.receive(event(1, at: 0.5))
        let finishing = ExportProgressModel()
        finishing.receive(event(100, at: 61, phase: .finishing))

        #expect(early.statusLine(locale: english) == "0% · frame 1 of 100 · 0:00 elapsed · estimating time left…")
        #expect(finishing.statusLine(locale: english) == "99% · frame 100 of 100 · 1:01 elapsed · finishing the file…")
        #expect(ExportProgressModel().statusLine(locale: english) == "")
    }

    /// The share done, for the progress bar.
    @Test func test_the_fraction_follows_the_progress() {
        let model = ExportProgressModel()
        #expect(model.fraction == 0)

        model.receive(event(50, of: 99, at: 3))

        #expect(model.fraction == 0.5)
    }

    // MARK: - Messages

    /// Every failure reads as a sentence with a fix, in both languages.
    @Test func test_every_failure_has_a_message_and_a_fix() {
        let errors: [OverlayExportError] = [
            .sourceUnreadable, .noVideoTrack, .rangeOutsideFootage, .destinationIsSource,
            .unsupportedOutput(.codecUnavailable(.hevc)),
            .unsupportedOutput(.dimensionsTooLarge(width: 7_680, height: 4_320, codec: .h264)),
            .unsupportedOutput(.dimensionsTooSmall(width: 8, height: 8)),
            .insufficientDiskSpace(required: 3_100_000_000, available: 1_000),
            .insufficientDiskSpace(required: 3_100_000_000, available: nil),
            .writerFailed("The operation couldn’t be completed."), .cancelled
        ]

        for locale in [english, portuguese] {
            let messages = errors.map { ExportProgressModel.userMessage(for: $0, locale: locale) }
            #expect(!messages.contains { $0.title.isEmpty || $0.fix.isEmpty }, "\(messages)")
            #expect(!messages.contains { L10n.isFlagged($0.title) || L10n.isFlagged($0.fix) }, "\(messages)")
            #expect(Set(messages.map(\.title)).count == errors.count, "every failure is told apart")
        }
    }

    /// The disk-space message names what is needed, in the locale's numbers.
    @Test func test_the_disk_space_message_names_the_space_needed() {
        let filledUp = ExportProgressModel.userMessage(
            for: .insufficientDiskSpace(required: 3_100_000_000, available: nil), locale: english)
        let portugueseTitle = ExportProgressModel.userMessage(
            for: .insufficientDiskSpace(required: 3_100_000_000, available: 1_200_000_000), locale: portuguese).title

        #expect(filledUp.title == "The disk filled up during the export — 3.1 GB needed")
        #expect(portugueseTitle == "Espaço em disco insuficiente — são necessários 3,1 GB, há 1,2 GB livres")
    }

    /// The codec and size failures say which output to pick instead.
    @Test func test_output_failures_suggest_another_output() {
        let hevc = ExportProgressModel.userMessage(for: .unsupportedOutput(.codecUnavailable(.hevc)), locale: english)
        let large = ExportProgressModel.userMessage(
            for: .unsupportedOutput(.dimensionsTooLarge(width: 7_680, height: 4_320, codec: .h264)), locale: english)

        #expect(hevc == ExportUserMessage(title: "This Mac can’t encode HEVC", fix: "Choose H.264."))
        #expect(large.title == "7680 × 4320 is too large for H.264")
        #expect(large.fix == "Choose a lower resolution, or HEVC.")
    }

    /// An export opened before the session's data is loaded says what to do.
    @Test func test_missing_telemetry_says_what_to_do() {
        #expect(ExportProgressModel.telemetryMissingMessage(locale: english)
                == ExportUserMessage(title: "The session’s data isn’t loaded",
                                     fix: "Open Video + Data, then export again."))
        #expect(ExportProgressModel.telemetryMissingMessage(locale: portuguese).title
                == "Os dados da sessão não estão carregados")
    }

    /// The writer's own words are kept.
    @Test func test_a_writer_failure_keeps_the_system_message() {
        let message = ExportProgressModel.userMessage(for: .writerFailed("Encoder busy"), locale: english)

        #expect(message.title == "The export failed: Encoder busy")
    }
}

/// Records that the exporter was asked to cancel.
private actor CancelRecorder {
    private var called = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func record() {
        called = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }

    func waitForCall() async {
        guard !called else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
