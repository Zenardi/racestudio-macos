import AVFoundation
import Darwin
import Foundation
import Testing
@testable import RaceStudioCore

/// The overlay export's performance budget (issue 9.13): ten minutes of 4K
/// 29.97 fps footage — synthetic moving noise at 56 Mb/s, like an action
/// camera's — exported to 1080p H.264 with the Full telemetry overlay in no
/// more than real time (≤ 600 s), using no more than 1.5 GB at peak.
///
/// A local benchmark, not a CI gate: it needs a 4 GB source and minutes of
/// encoding. Run it on a release build, from `app/`, in two processes — the
/// first writes the source into the work directory (once), the second
/// measures the export alone, so its peak memory is the export's:
///
///     swift build -c release --target RaceStudioCoreTests -Xswiftc -enable-testing
///     export RACESTUDIO_EXPORT_BENCH=/path/to/work
///     swift test -c release --skip-build --filter OverlayExportBenchmark/test_1
///     swift test -c release --skip-build --filter OverlayExportBenchmark/test_2
///
/// ADR 0008 records the numbers.
@Suite(.serialized, .enabled(if: benchmarkDirectory != nil,
                             "set RACESTUDIO_EXPORT_BENCH to a work directory to run the export benchmark"))
struct OverlayExportBenchmark {

    static var workDirectory: URL? { benchmarkDirectory }

    /// Ten minutes at 29.97 fps.
    private static let spec = TestMediaFactory.Spec(width: 3_840, height: 2_160,
                                                    frameRate: FrameGrid(numerator: 30_000, denominator: 1_001),
                                                    frames: 17_982, noise: true, bitRate: 56_000_000)

    private static var source: URL? { workDirectory?.appendingPathComponent("bench-4k-2997-10min.mp4") }

    /// Write the source, unless an earlier run already has.
    @Test func test_1_the_4k_source_is_written() async throws {
        let source = try #require(Self.source)
        if !FileManager.default.fileExists(atPath: source.path) {
            try FileManager.default.createDirectory(at: source.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let clock = ContinuousClock()
            let took = try await clock.measure { try await TestMediaFactory.writeMovie(Self.spec, to: source) }
            print("BENCH source: wrote \(source.lastPathComponent) in \(took)")
        }

        #expect(try await FootageProbe.probe(source).frameCount == Self.spec.frames)
    }

    /// The export: no slower than real time, no more than 1.5 GB at peak.
    @Test func test_2_a_10_minute_4k_source_exports_to_1080p_in_real_time() async throws {
        let source = try #require(Self.source)
        let footage = try await FootageProbe.probe(source)
        let built = TelemetryFixture.make(duration: footage.duration + 2)
        let telemetry = try await TelemetryTimeline.load(session: built.session, source: built.source,
                                                         sectors: built.sectors)
        let renderer = OverlayRenderer(layout: OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")),
                                       session: OverlayRenderFixture.session(), track: OverlayRenderFixture.track,
                                       sectors: OverlayRenderFixture.sectors)
        let request = ExportRequest(source: source, sync: VideoSyncModel(videoDuration: footage.duration),
                                    range: .wholeFootage,
                                    session: SessionTimeSpan(start: 0, end: footage.duration + 2),
                                    settings: ExportSettings(resolution: .p1080, codec: .h264))
        let plan = try ExportPlan.make(request: request, footage: footage, timeline: built.sectors,
                                       encoders: .system).get()
        let destination = try #require(Self.workDirectory).appendingPathComponent("bench-1080p.mp4")

        let clock = ContinuousClock()
        let took = try await clock.measure {
            _ = try await collect(OverlayVideoExporter().export(
                plan, overlay: ExportOverlay(drawer: renderer, telemetry: telemetry), to: destination))
        }

        let seconds = Double(took.components.seconds) + Double(took.components.attoseconds) / 1e18
        let peak = Double(peakMemoryFootprint()) / 1_073_741_824
        let bytes = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int ?? 0
        print(String(format: "BENCH export: %d frames 4K29.97 → 1080p H.264 in %.1f s (%.2f× real time), "
                     + "peak footprint %.2f GB, %.0f MB (estimate %.0f MB)", plan.frameCount, seconds,
                     seconds / plan.duration, peak, Double(bytes) / 1e6, Double(plan.estimatedBytes) / 1e6))
        #expect(seconds <= plan.duration, "no slower than real time")
        #expect(peak <= 1.5, "no more than 1.5 GB at peak")
        #expect(abs(try await AVURLAsset(url: destination).load(.duration).seconds - plan.duration) < 0.05)
    }
}

/// A guard on the export's pace that CI runs (issue 9.13): a three-second clip
/// exports well inside a ceiling generous enough for a debug, instrumented
/// build on a slow runner — only something pathological, like rebuilding the
/// overlay's static layers or a Core Image context every frame, breaks it.
@Suite struct OverlayExportThroughputTests {

    // Deliberately loose: locally the clip takes about 0.2 s in a debug build,
    // but CI runs it instrumented, beside every other suite, on a shared
    // virtual machine with no media engine (software decode and encode) about
    // three times slower — and a flaky gate is worse than none. 30 s still
    // catches what matters: per-frame work that should be per-export, or a
    // pull loop that stalls, which take minutes. The real budget is the local
    // OverlayExportBenchmark.
    #if DEBUG
    private static let ceiling = Duration.seconds(30)
    #else
    private static let ceiling = Duration.seconds(5)
    #endif

    @Test func test_a_short_export_keeps_pace() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage(TestMediaFactory.Spec(width: 640, height: 360)))
        let renderer = OverlayRenderer(layout: OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")),
                                       session: OverlayRenderFixture.session(), track: OverlayRenderFixture.track,
                                       sectors: OverlayRenderFixture.sectors)
        let overlay = ExportOverlay(drawer: renderer, telemetry: try await SessionTimeBar.timeline(from: 0, to: 5))

        let took = try await ContinuousClock().measure {
            _ = try await collect(sandbox.exporter().export(plan, overlay: overlay, to: sandbox.destination))
        }

        print("OverlayVideoExporter 640×360, 90 frames: \(took)")
        #expect(took <= Self.ceiling, "\(took) for a three-second clip")
    }
}

/// The export benchmark's work directory (`RACESTUDIO_EXPORT_BENCH`), or `nil`
/// to skip the benchmark.
let benchmarkDirectory = ProcessInfo.processInfo.environment["RACESTUDIO_EXPORT_BENCH"].map {
    URL(fileURLWithPath: $0)
}

/// The process's peak physical footprint so far, in bytes — what Activity
/// Monitor calls its memory high-water mark.
func peakMemoryFootprint() -> Int64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.ledger_phys_footprint_peak : 0
}
