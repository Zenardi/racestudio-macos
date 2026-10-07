import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The whole Export Video with Overlay workflow, headless (issue 9.14) — the
/// `scripts/e2e.sh` smoke.
///
/// The public sample session (`fixtures/aim_official_test.xrk`, fetched by
/// `make fixtures`) is loaded the way the app loads it; onboard footage of its
/// best lap is generated at 320×180, 30 fps, with a second either side; the
/// footage is synced on the lap's start the way the operator does it (pick
/// the lap, scrub to its first frame, *Sync to Section*); the export sheet is
/// opened on it as ⌥⌘E opens it; and the lap is exported with the *Kart
/// coaching* overlay drawn by the HUD's own renderer.
///
/// The output must last exactly the lap, start on the lap's first frame, and
/// carry on every frame the overlay of that frame's own session time — a
/// timing bar drawn over the overlay shows it, as in the engine's tests.
///
/// Without the sample the test is skipped, unless `RS_REQUIRE_CORPUS` is set
/// (`scripts/e2e.sh` sets it), when its absence fails the run.
@Suite struct OverlayExportEndToEndTests {

    private static let english = Locale(identifier: "en")
    private static let frame = 1 / SyncedSample.frameRate

    @MainActor
    @Test func test_the_best_lap_exports_in_sync_with_its_overlay() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        guard let sample = try await SyncedSample.bestLap(in: sandbox) else { return }

        // Open the sheet as ⌥⌘E does: the best lap, Kart coaching, 1080p — the
        // 180p footage is never upscaled.
        let input = try #require(sample.data.exportSheetInput(source: sample.footageURL, footage: sample.footage,
                                                              session: sample.session, selectedLaps: [],
                                                              hasWorkspaceOverlay: false))
        let sheet = ExportSheetModel(input: input, preferences: ExportPreferences(), encoders: .system,
                                     locale: Self.english)
        #expect(sheet.range == .bestLap)
        #expect(sheet.overlay == .preset(.kartCoaching))
        #expect(sheet.syncWarning(locale: Self.english) == nil)
        #expect(sheet.suggestedFileName == "Adria Kart – 2016-01-23 – Lap 9 (0'49.765).mp4")
        let plan = try sheet.makePlan().get()
        let overlay = try #require(try await sample.data.exportOverlay(
            layout: sheet.layout(workspace: nil, locale: Self.english), kart: nil, metadata: sample.session.metadata,
            analysis: sample.analysis, locale: Self.english))
        let probe = TimingProbe(base: overlay.drawer, origin: sample.lap.start)

        let events = try await collect(sandbox.exporter().export(
            plan, overlay: ExportOverlay(drawer: probe, telemetry: overlay.telemetry), to: sandbox.destination))

        // The output is the lap, frame for frame, with each frame's own overlay.
        let checked = [0, 45, 1_000, plan.frameCount - 1]
        let movie = try await MovieReadback.read(sandbox.destination, decoding: Set(checked))
        #expect(plan.outputSize == CGSize(width: 320, height: 180), "never upscaled")
        #expect(movie.size == plan.outputSize)
        #expect(movie.codec == "avc1")
        #expect(abs(movie.duration - sample.lap.duration) <= Self.frame)
        #expect(movie.frameTimes.count == plan.frameCount)
        #expect(abs((movie.audioDuration ?? 0) - plan.duration) <= 1_024 / 48_000.0, "within one AAC packet")
        #expect(events.last?.phase == .complete)
        for index in checked {
            try expectFrame(index, of: movie, probe: probe, sample: sample)
        }
        let lapClock = try #require(overlay.telemetry.frame(at: plan.sessionSpan.start).lap)
        #expect(lapClock.lap == sample.best)
        #expect(lapClock.elapsed < Self.frame, "the lap timer starts on the lap's first frame")
    }

    /// Output frame `index` is the lap's frame `index`, carrying the overlay of
    /// its own session time, with the Kart coaching speed widget burned in.
    @MainActor
    private func expectFrame(_ index: Int, of movie: MovieReadback, probe: TimingProbe,
                             sample: SyncedSample) throws {
        let decoded = try #require(movie.frames[index])
        #expect(decoded.sourcePixel.frameIndex == (SyncedSample.lapStartFrame + index) % 512,
                "output frame \(index) is the lap's frame \(index)")
        // ±2 px absorbs codec edge blur; a one-frame error moves the bar 3 px.
        #expect(abs(decoded.barLength() - probe.length(at: sample.lap.start + Double(index) * Self.frame)) <= 2,
                "frame \(index)'s overlay is of its own session time")
        #expect(!decoded.pixel(x: 30, row: 160).isNear(decoded.sourcePixel, tolerance: 12),
                "the Kart coaching speed widget is burned in")
    }
}

/// The public sample session with synthetic onboard footage of its best lap,
/// synced on the lap's start as the operator does it: pick the lap, scrub to
/// its first frame, *Sync to Section*.
@MainActor
struct SyncedSample {
    /// The footage's frame rate.
    nonisolated static let frameRate = 30.0
    /// The footage frame the lap starts on: one second in.
    nonisolated static let lapStartFrame = 30

    let session: Session
    let analysis: AnalysisSession
    let data: VideoDataViewModel
    let footageURL: URL
    let footage: FootageInfo
    let best: LapID
    let lap: SessionTimeSpan

    /// The sample, its footage written into `sandbox` at 320×180 with a second
    /// either side of the lap — or `nil` (skipping) without the sample.
    static func bestLap(in sandbox: ExportSandbox) async throws -> SyncedSample? {
        guard let xrk = PublicSample.xrk() else { return nil }
        let loaded = try await FFISessionLoader().load(xrk) { _ in }
        let analysis = AnalysisSession(session: loaded.session, dataSource: try #require(loaded.dataSource))
        let timeline = LapSectorTimeline.make(laps: loaded.session.laps,
                                              segments: analysis.segmentTimes(splits: SplitReportModel.baseResolution),
                                              layout: SplitReportModel().layout)
        let best = try #require(SessionSummaryViewModel.bestLapIndex(loaded.session.laps)
            .map { LapID(Int(loaded.session.laps[$0].index)) })
        let lap = try #require(timeline.lapSpan(best)).span
        let margin = Double(lapStartFrame) / frameRate
        let footageURL = try await sandbox.footage(TestMediaFactory.Spec(
            frames: Int(((lap.duration + 2 * margin) * frameRate).rounded(.up))))
        let footage = try await FootageProbe.probe(footageURL)
        let review = VideoReviewModel(timeline: timeline, sync: VideoSyncModel(videoDuration: footage.duration))
        review.setFrameRate(frameRate)
        review.select(lap: best)
        #expect(review.anchorSelection(toPlayhead: margin))
        let data = VideoDataViewModel(review: review)
        await data.loadTelemetry(from: analysis)
        return SyncedSample(session: loaded.session, analysis: analysis, data: data, footageURL: footageURL,
                            footage: footage, best: best, lap: lap)
    }
}

/// The public sample session, or `nil` (skipping) where it hasn't been
/// fetched — unless `RS_REQUIRE_CORPUS` asks for it, when a missing sample
/// fails the test instead.
enum PublicSample {
    static func xrk() -> URL? {
        let url = FixtureLoader.url(for: "aim_official_test.xrk")
        if let handle = try? FileHandle(forReadingFrom: url), (try? handle.read(upToCount: 2)) == Data("<h".utf8) {
            try? handle.close()
            return url
        }
        if ProcessInfo.processInfo.environment["RS_REQUIRE_CORPUS"] != nil {
            Issue.record("aim_official_test.xrk is missing — run `make fixtures`")
        } else {
            print("skipping: aim_official_test.xrk is not present — run `make fixtures`")
        }
        return nil
    }
}

/// The export's real overlay with a timing bar over it: a white bar along the
/// top whose length is the frame's session time past `origin`, modulo three
/// seconds, at 90 px a second — so any decoded frame says which session time
/// its overlay was drawn for, to the frame. The bar's rows are blacked out
/// first, so neither the footage nor a widget can read as bar.
struct TimingProbe: OverlayFrameDrawing {
    let base: any OverlayFrameDrawing
    let origin: Double
    private let period = 3.0
    private let pixelsPerSecond = 90.0

    func prepare(for size: CGSize) {
        base.prepare(for: size)
    }

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        base.draw(frame, in: context, size: size)
        let rows = SessionTimeBar.rows
        let top = size.height - CGFloat(rows.upperBound)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: top, width: size.width, height: CGFloat(rows.count)))
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: top, width: CGFloat(length(at: frame.time)), height: CGFloat(rows.count)))
    }

    /// The bar's length, in pixels, for session time `time`. A microsecond
    /// is added first, so float noise just below a whole period — the lap's
    /// first frame among them — never reads as a full bar.
    func length(at time: Double) -> Int {
        let phase = (time - origin + 1e-6).truncatingRemainder(dividingBy: period)
        return Int(((phase < 0 ? phase + period : phase) * pixelsPerSecond).rounded())
    }
}
