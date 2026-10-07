import AVFoundation
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RaceStudioCore

/// The overlay export on real footage (issue 9.13) — a local check, never in
/// CI: the footage and the session are personal data and are never committed.
///
/// It exports, at the footage's own 1080p with the *Kart coaching* overlay
/// built the way the Video + Data HUD builds it:
///
/// 1. everything the footage and the session share, for the speed and the
///    size estimate on real content;
/// 2. the best lap alone;
///
/// and saves the session export's frames around the best lap's start as PNGs,
/// to check by eye that the lap timer restarts as the kart crosses the line.
///
/// Set, then run with the CLT route (`--filter OverlayExportRealFootage`):
///
///     RACESTUDIO_EXPORT_FOOTAGE=/path/to/onboard.mp4
///     RACESTUDIO_EXPORT_SESSION=/path/to/session.xrk
///     RACESTUDIO_EXPORT_OFFSET=-10.666        # video = session + offset
///     RACESTUDIO_EXPORT_OUT=/path/outside/the/repo
@Suite(.enabled(if: RealFootage.configured, "set RACESTUDIO_EXPORT_FOOTAGE, _SESSION, _OFFSET and _OUT"))
struct OverlayExportRealFootageTests {

    @MainActor
    @Test func test_real_footage_exports_at_1080p() async throws {
        let real = try #require(RealFootage())
        let loaded = try await FFISessionLoader().load(real.session) { _ in }
        let analysis = AnalysisSession(session: loaded.session, dataSource: try #require(loaded.dataSource))
        let laps = LapSectorTimeline.make(laps: loaded.session.laps, segments: [], layout: SplitLayout.even(base: 2,
                                                                                                             count: 2))
        let layout = OverlayPreset.kartCoaching.layout(locale: Locale(identifier: "en"))
        let telemetry = try await TelemetryTimeline.load(from: analysis, timeline: laps,
                                                         channels: layout.sessionChannelNames)
        let context = OverlaySessionContext(channelMap: telemetry.channelMap, hasLaps: !laps.isEmpty,
                                            hasSectors: false, hasTrackPosition: !telemetry.position.isEmpty,
                                            metadata: loaded.session.metadata)
        let renderer = OverlayRenderer(layout: layout, formatter: OverlayFormatter(locale: Locale(identifier: "en")),
                                       session: context, track: OverlayTrackMap(timeline: telemetry, sectors: laps),
                                       sectors: laps)
        let overlay = ExportOverlay(drawer: renderer, telemetry: telemetry)
        let footage = try await FootageProbe.probe(real.footage)
        let span = try #require(telemetry.timeRange)
        let session = SessionTimeSpan(start: span.lowerBound, end: span.upperBound)
        let best = try #require(SessionSummaryViewModel.bestLapIndex(loaded.session.laps)
            .map { LapID(Int(loaded.session.laps[$0].index)) })

        for (name, range) in [("session", ExportRange.session), ("best-lap", .laps([best]))] {
            let request = ExportRequest(source: real.footage,
                                        sync: VideoSyncModel(videoDuration: footage.duration, offset: real.offset),
                                        range: range, session: session, settings: ExportSettings(resolution: .source))
            let plan = try ExportPlan.make(request: request, footage: footage, timeline: laps).get()
            let destination = real.output.appendingPathComponent("real-\(name).mp4")
            let took = try await ContinuousClock().measure {
                _ = try await collect(OverlayVideoExporter().export(plan, overlay: overlay, to: destination))
            }
            let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
            let bytes = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
            print(String(format: "REAL %@: %d frames %dx%d in %.1f s (%.2f× real time), %.1f MB vs estimate %.1f MB "
                         + "(%+.1f%%)", name, plan.frameCount, plan.outputWidth, plan.outputHeight, seconds,
                         seconds / plan.duration, Double(bytes) / 1e6, Double(plan.estimatedBytes) / 1e6,
                         (Double(bytes) / Double(plan.estimatedBytes) - 1) * 100))
            #expect(try await AVURLAsset(url: destination).load(.duration).seconds > 0)
            if name == "session" { try await saveLapStart(of: destination, plan: plan, best: best, laps: laps, real) }
        }
    }

    /// Frames −2…+2 around the best lap's start in the session's export, as
    /// PNGs in the output folder.
    private func saveLapStart(of movie: URL, plan: ExportPlan, best: LapID, laps: LapSectorTimeline,
                              _ real: RealFootage) async throws {
        let start = try #require(laps.lapSpan(best)).span.start
        let grid = plan.footage.frameRate
        let first = plan.request.sync.videoTime(forCursorTime: start) - Double(plan.firstFrame) * grid.frameDuration
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: movie))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for offset in -2...2 {
            let frame = max(Int((first / grid.frameDuration).rounded(.up)) + offset, 0)
            let time = CMTime(value: CMTimeValue(frame * grid.denominator), timescale: CMTimeScale(grid.numerator))
            let image = try await generator.image(at: time).image
            let url = real.output.appendingPathComponent("lap-start\(offset >= 0 ? "+" : "")\(offset).png")
            let png = UTType.png.identifier as CFString
            let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, png, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
            let sessionTime = plan.request.sync.cursorTime(forVideoTime: Double(plan.firstFrame + frame)
                                                                         * grid.frameDuration)
            print("REAL lap start \(offset): output frame \(frame), session time \(sessionTime)")
        }
    }
}

/// The local real-footage pair, from the environment.
struct RealFootage {
    let footage: URL
    let session: URL
    let offset: Double
    let output: URL

    static var configured: Bool { RealFootage() != nil }

    init?() {
        let env = ProcessInfo.processInfo.environment
        guard let footage = env["RACESTUDIO_EXPORT_FOOTAGE"], let session = env["RACESTUDIO_EXPORT_SESSION"],
              let offset = env["RACESTUDIO_EXPORT_OFFSET"].flatMap(Double.init),
              let output = env["RACESTUDIO_EXPORT_OUT"] else { return nil }
        self.footage = URL(fileURLWithPath: footage)
        self.session = URL(fileURLWithPath: session)
        self.offset = offset
        self.output = URL(fileURLWithPath: output, isDirectory: true)
    }
}
