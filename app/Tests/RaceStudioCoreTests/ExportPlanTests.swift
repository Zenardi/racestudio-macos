import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import RaceStudioCore

/// The overlay export's pure planning step (issue 9.13): a request — footage,
/// sync, range and output settings — resolved into the exact footage frames to
/// export, the output size, the bit rates and the estimated file size, or a
/// typed error. No AVFoundation: the footage is described by a plain
/// ``FootageInfo``.
@Suite struct ExportPlanTests {

    // MARK: - Fixtures

    private static let thirty = FrameGrid(numerator: 30, denominator: 1)
    private static let ntsc = FrameGrid(numerator: 30_000, denominator: 1_001)
    private static let stereo = FootageAudio(sampleRate: 48_000, channels: 2)

    /// Ten minutes of 4K at 30 fps with stereo audio, unless told otherwise.
    private static func footage(duration: Double = 600, frameRate: FrameGrid = thirty,
                                size: CGSize = CGSize(width: 3_840, height: 2_160),
                                rotation: FootageRotation = .none,
                                audio: FootageAudio? = stereo) -> FootageInfo {
        FootageInfo(duration: duration, frameRate: frameRate, naturalSize: size, rotation: rotation, audio: audio,
                    codec: "avc1")
    }

    /// Laps 1–5, each 60 s, the first starting at session time 30 s.
    private static let timeline = LapSectorTimeline(laps: (1...5).map { index in
        let start = 30 + Double(index - 1) * 60
        return LapSpan(lap: LapID(index), span: SessionTimeSpan(start: start, end: start + 60), sectors: [])
    })

    private static func request(_ range: ExportRange, offset: Double = 0, rate: Double = 1,
                                videoDuration: Double = 600,
                                session: SessionTimeSpan = SessionTimeSpan(start: 0, end: 400),
                                settings: ExportSettings = ExportSettings()) -> ExportRequest {
        ExportRequest(source: URL(fileURLWithPath: "/tmp/onboard.mp4"),
                      sync: VideoSyncModel(videoDuration: videoDuration, offset: offset, rate: rate),
                      range: range, session: session, settings: settings)
    }

    private func plan(_ request: ExportRequest, footage: FootageInfo = footage(),
                      encoders: EncoderAvailability = .all) throws -> ExportPlan {
        try ExportPlan.make(request: request, footage: footage, timeline: Self.timeline, encoders: encoders).get()
    }

    private func failure(_ request: ExportRequest, footage: FootageInfo = footage(),
                         encoders: EncoderAvailability = .all) -> OverlayExportError? {
        guard case .failure(let error) = ExportPlan.make(request: request, footage: footage,
                                                         timeline: Self.timeline, encoders: encoders) else {
            return nil
        }
        return error
    }

    // MARK: - Source range

    /// The whole footage is every frame, from the first.
    @Test func test_whole_footage_exports_every_frame() throws {
        let plan = try plan(Self.request(.wholeFootage))

        #expect(plan.firstFrame == 0)
        #expect(plan.frameCount == 18_000)
        #expect(plan.sourceRange == CMTimeRange(start: .zero, duration: CMTime(value: 600, timescale: 1)))
        #expect(plan.duration == 600)
    }

    /// The session is mapped through the sync: `video = session × rate + offset`.
    @Test func test_the_session_maps_through_the_sync_offset() throws {
        let plan = try plan(Self.request(.session, offset: 12.5))

        #expect(plan.firstFrame == 375, "session 0 s is video 12.5 s, frame 375 at 30 fps")
        #expect(plan.frameCount == 12_000, "400 s of session")
        #expect(plan.sessionSpan == SessionTimeSpan(start: 0, end: 400))
    }

    /// One lap exports that lap's window.
    @Test func test_a_single_lap_exports_its_window() throws {
        let plan = try plan(Self.request(.laps([LapID(2)]), offset: 5))

        #expect(plan.firstFrame == 2_850, "lap 2 starts at 90 s, video 95 s")
        #expect(plan.frameCount == 1_800, "a 60 s lap")
        #expect(plan.sessionSpan == SessionTimeSpan(start: 90, end: 150))
    }

    /// Several laps export as one continuous span, from the first lap's start to
    /// the last lap's end, whatever their order and gaps.
    @Test func test_several_laps_export_one_continuous_span() throws {
        let plan = try plan(Self.request(.laps([LapID(5), LapID(3)])))

        #expect(plan.sessionSpan == SessionTimeSpan(start: 150, end: 330))
        #expect(plan.frameCount == 5_400)
    }

    /// A custom span honours the sync's clock rate as well as its offset.
    @Test func test_a_custom_span_honours_the_clock_rate() throws {
        let plan = try plan(Self.request(.span(SessionTimeSpan(start: 100, end: 200)), offset: -1.5, rate: 1.002))

        // video 98.7 … 198.9 s → frames 2961 ..< 5967 (ceil of 2961.0 and 5967.0)
        #expect(plan.firstFrame == 2_961)
        #expect(plan.frameCount == 3_006)
    }

    /// At 29.97 fps the range starts on the first whole frame at or after the
    /// mapped time, and the source range is that frame's exact rational time.
    @Test func test_ntsc_footage_starts_on_an_exact_frame_boundary() throws {
        let plan = try plan(Self.request(.span(SessionTimeSpan(start: 10, end: 20))),
                            footage: Self.footage(frameRate: Self.ntsc))

        #expect(plan.firstFrame == 300, "10 s is frame 299.7 → frame 300")
        #expect(plan.sourceRange.start == CMTime(value: 300 * 1_001, timescale: 30_000))
        #expect(plan.frameCount == 300, "frames 300 ..< 600 (20 s is frame 599.4 → 600)")
        #expect(plan.sourceRange.duration == CMTime(value: 300 * 1_001, timescale: 30_000))
    }

    /// A range that runs off either end of the footage is clamped to it.
    @Test func test_a_range_partly_outside_the_footage_is_clamped() throws {
        let early = try plan(Self.request(.span(SessionTimeSpan(start: -20, end: 10)), offset: 5))
        let late = try plan(Self.request(.span(SessionTimeSpan(start: 590, end: 700))))

        #expect(early.firstFrame == 0)
        #expect(early.frameCount == 450, "video 0 … 15 s")
        #expect(late.firstFrame == 17_700)
        #expect(late.frameCount == 300, "video 590 … 600 s")
    }

    /// A range wholly before or after the footage — or one holding no frame —
    /// has nothing to export.
    @Test(arguments: [SessionTimeSpan(start: -100, end: -50), SessionTimeSpan(start: 700, end: 800),
                      SessionTimeSpan(start: 10.001, end: 10.002), SessionTimeSpan(start: 20, end: 10),
                      SessionTimeSpan(start: .nan, end: 10), SessionTimeSpan(start: 0, end: .infinity)])
    func test_a_range_outside_the_footage_is_rejected(_ span: SessionTimeSpan) {
        #expect(failure(Self.request(.span(span))) == .rangeOutsideFootage)
    }

    /// No laps, or only laps the timeline does not know, select nothing.
    @Test(arguments: [[LapID](), [LapID(42)]])
    func test_an_empty_lap_selection_is_rejected(_ laps: [LapID]) {
        #expect(failure(Self.request(.laps(laps))) == .rangeOutsideFootage)
    }

    /// The plan names the session time its first frame and its end map back to.
    @Test func test_the_plan_reports_the_session_span_it_covers() throws {
        let plan = try plan(Self.request(.wholeFootage, offset: 12.5))

        #expect(plan.sessionSpan == SessionTimeSpan(start: -12.5, end: 587.5))
    }
}

/// The output size, bit rate and size estimate of an export plan (issue 9.13).
@Suite struct ExportPlanOutputTests {

    private static func footage(width: Double, height: Double, rotation: FootageRotation = .none,
                                audio: FootageAudio? = FootageAudio(sampleRate: 48_000, channels: 2),
                                duration: Double = 600) -> FootageInfo {
        FootageInfo(duration: duration, frameRate: FrameGrid(numerator: 30, denominator: 1),
                    naturalSize: CGSize(width: width, height: height), rotation: rotation, audio: audio,
                    codec: "avc1")
    }

    private func plan(_ footage: FootageInfo, _ settings: ExportSettings = ExportSettings(),
                      range: ExportRange = .wholeFootage, encoders: EncoderAvailability = .all)
        -> Result<ExportPlan, OverlayExportError> {
        let request = ExportRequest(source: URL(fileURLWithPath: "/tmp/onboard.mp4"),
                                    sync: VideoSyncModel(videoDuration: footage.duration), range: range,
                                    session: SessionTimeSpan(start: 0, end: footage.duration), settings: settings)
        return ExportPlan.make(request: request, footage: footage, timeline: .empty, encoders: encoders)
    }

    private func size(_ footage: FootageInfo, _ resolution: ExportResolution) throws -> [Int] {
        let plan = try plan(footage, ExportSettings(resolution: resolution)).get()
        return [plan.outputWidth, plan.outputHeight]
    }

    // MARK: - Output size

    /// Each preset scales the short edge to its height, keeping the aspect.
    @Test func test_presets_scale_4k_footage() throws {
        let uhd = Self.footage(width: 3_840, height: 2_160)

        #expect(try size(uhd, .source) == [3_840, 2_160])
        #expect(try size(uhd, .p2160) == [3_840, 2_160])
        #expect(try size(uhd, .p1080) == [1_920, 1_080])
        #expect(try size(uhd, .p720) == [1_280, 720])
    }

    /// A preset larger than the footage never upscales it.
    @Test func test_a_larger_preset_never_upscales() throws {
        let fullHD = Self.footage(width: 1_920, height: 1_080)

        #expect(try size(fullHD, .p2160) == [1_920, 1_080])
        #expect(try size(fullHD, .p1080) == [1_920, 1_080])
        #expect(try size(fullHD, .p720) == [1_280, 720])
    }

    /// A 4:3 source keeps its aspect.
    @Test func test_a_four_by_three_source_keeps_its_aspect() throws {
        let fourByThree = Self.footage(width: 1_440, height: 1_080)

        #expect(try size(fourByThree, .p720) == [960, 720])
        #expect(try size(fourByThree, .p1080) == [1_440, 1_080])
    }

    /// A rotated (portrait phone) source is sized upright: its short edge is
    /// the displayed width.
    @Test func test_a_rotated_source_is_sized_upright() throws {
        let portrait = Self.footage(width: 1_920, height: 1_080, rotation: .clockwise90)

        #expect(try size(portrait, .source) == [1_080, 1_920])
        #expect(try size(portrait, .p720) == [720, 1_280])
    }

    /// Odd dimensions are rounded down to even ones — the encoder's 4:2:0
    /// chroma needs even sizes — never up.
    @Test func test_odd_dimensions_round_down_to_even() throws {
        let odd = Self.footage(width: 1_281, height: 721)
        let widescreen = Self.footage(width: 1_366, height: 768)

        #expect(try size(odd, .source) == [1_280, 720])
        #expect(try size(widescreen, .p720) == [1_280, 720])
    }

    // MARK: - Codec support

    /// HEVC is rejected up front where no HEVC encoder is available.
    @Test func test_hevc_without_an_encoder_is_unsupported() {
        let result = plan(Self.footage(width: 1_920, height: 1_080), ExportSettings(codec: .hevc),
                          encoders: EncoderAvailability(supportsHEVC: false))

        #expect(result.failureValue == .unsupportedOutput(.codecUnavailable(.hevc)))
    }

    /// H.264 cannot carry an 8K frame; HEVC can.
    @Test func test_an_8k_source_needs_hevc() throws {
        let eightK = Self.footage(width: 7_680, height: 4_320)

        #expect(plan(eightK, ExportSettings(resolution: .source, codec: .h264)).failureValue
                == .unsupportedOutput(.dimensionsTooLarge(width: 7_680, height: 4_320, codec: .h264)))
        #expect(try plan(eightK, ExportSettings(resolution: .source, codec: .hevc)).get().outputWidth == 7_680)
        #expect(try plan(eightK, ExportSettings(resolution: .p2160, codec: .h264)).get().outputWidth == 3_840)
    }

    /// A frame too small to encode is rejected.
    @Test func test_a_tiny_source_is_unsupported() {
        #expect(plan(Self.footage(width: 9, height: 9), ExportSettings(resolution: .source)).failureValue
                == .unsupportedOutput(.dimensionsTooSmall(width: 8, height: 8)))
    }

    // MARK: - Bit rate and size estimate

    /// The bit rate grows with the output resolution, and HEVC needs less than
    /// H.264 for the same frame.
    @Test func test_the_bit_rate_grows_with_resolution_and_is_lower_for_hevc() throws {
        let uhd = Self.footage(width: 3_840, height: 2_160)
        let rates = try [ExportResolution.p720, .p1080, .p2160].map {
            try plan(uhd, ExportSettings(resolution: $0)).get().videoBitRate
        }
        let hevc = try plan(uhd, ExportSettings(resolution: .p1080, codec: .hevc)).get().videoBitRate

        #expect(rates == rates.sorted() && Set(rates).count == 3)
        #expect(hevc < rates[1])
        #expect((8_000_000...16_000_000).contains(rates[1]), "about 12 Mb/s for 1080p30 H.264")
    }

    /// The size estimate grows with the duration and the resolution.
    @Test func test_the_estimate_grows_with_duration_and_resolution() throws {
        let uhd = Self.footage(width: 3_840, height: 2_160)
        let short = try plan(uhd, range: .span(SessionTimeSpan(start: 0, end: 60))).get()
        let long = try plan(uhd, range: .span(SessionTimeSpan(start: 0, end: 120))).get()
        let small = try plan(uhd, ExportSettings(resolution: .p720), range: .span(SessionTimeSpan(start: 0, end: 60)))
            .get()

        #expect(short.estimatedBytes < long.estimatedBytes)
        #expect(small.estimatedBytes < short.estimatedBytes)
        // 60 s at the video and audio rates, within a few percent of container overhead.
        let payload = Double(short.videoBitRate + short.audioBitRate) * 60 / 8
        #expect(Double(short.estimatedBytes) >= payload && Double(short.estimatedBytes) < payload * 1.05)
    }

    /// Dropping the audio — or footage without any — leaves it out of the plan
    /// and the estimate.
    @Test func test_audio_is_planned_only_when_kept_and_present() throws {
        let uhd = Self.footage(width: 3_840, height: 2_160)
        let kept = try plan(uhd).get()
        let dropped = try plan(uhd, ExportSettings(audio: .drop)).get()
        let silent = try plan(Self.footage(width: 3_840, height: 2_160, audio: nil)).get()

        #expect(kept.includesAudio && kept.audioBitRate > 0)
        #expect(!dropped.includesAudio && dropped.audioBitRate == 0)
        #expect(!silent.includesAudio && silent.audioBitRate == 0)
        #expect(dropped.estimatedBytes < kept.estimatedBytes)
    }

    /// The disk-space check asks for room for the file twice over — the
    /// writer's fast-start pass copies the finished file to move its index to
    /// the front — each with a 10% margin.
    @Test func test_the_required_space_covers_the_fast_start_copy() throws {
        let plan = try plan(Self.footage(width: 1_920, height: 1_080)).get()

        #expect(plan.requiredBytes == 2 * (plan.estimatedBytes + plan.estimatedBytes / 10))
    }
}

extension Result {
    /// The error, or `nil` on success.
    var failureValue: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
