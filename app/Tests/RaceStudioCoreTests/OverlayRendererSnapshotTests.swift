import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// Golden snapshots of the overlay renderer (issue 9.11): every built-in preset
/// at 1280×720 mid-lap, just after the line (the lap just finished showing as
/// the last lap) and in a channel gap, against `fixtures/overlay/golden/` —
/// synthetic data only. See ``OverlaySnapshotAssert`` for the tolerance and how
/// to re-record (`RECORD_OVERLAY_GOLDENS=1`).
///
/// The font-independent guarantees — transparency, the delta bar's side and
/// colour, the shift light, the G-ball and map dots — are asserted structurally
/// by the widget and transparency suites, so they hold whatever a runner's
/// text rasterisation does.
@Suite struct OverlayRendererSnapshotTests {

    /// A frame state each preset is snapshotted in.
    enum State: String, CaseIterable {
        case midLap = "mid-lap"
        case lapStart = "lap-start"
        case channelGap = "channel-gap"

        var frame: TelemetryFrame {
            switch self {
            case .midLap: return OverlayRenderFixture.midLap
            case .lapStart: return OverlayRenderFixture.lapStartFrame
            case .channelGap: return OverlayRenderFixture.gap
            }
        }
    }

    @Test(arguments: OverlayPreset.allCases, State.allCases)
    func test_the_preset_matches_its_golden(_ preset: OverlayPreset, _ state: State) throws {
        let renderer = OverlayRenderer(layout: preset.layout(locale: Locale(identifier: "en")),
                                       formatter: OverlayFormatter(), session: OverlayRenderFixture.session(),
                                       track: OverlayRenderFixture.track, sectors: OverlayRenderFixture.sectors)

        let image = try #require(renderer.makeImage(state.frame, size: OverlaySnapshotAssert.size))

        try OverlaySnapshotAssert.assertMatches(image, named: "\(preset.rawValue)-\(state.rawValue)")
    }

    // MARK: - The harness itself

    @Test func test_an_image_matches_itself() throws {
        let image = try #require(OverlayBitmap(width: 64, height: 32).context.makeImage())

        #expect(OverlaySnapshotAssert.compare(image, image).differing == 0)
    }

    @Test func test_a_change_beyond_the_channel_tolerance_counts_as_a_differing_pixel() throws {
        let blank = OverlayBitmap(width: 100, height: 100)
        let marked = OverlayBitmap(width: 100, height: 100)
        marked.context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        marked.context.fill(CGRect(x: 0, y: 0, width: 10, height: 10))

        let comparison = OverlaySnapshotAssert.compare(try #require(blank.context.makeImage()),
                                                       try #require(marked.context.makeImage()))

        #expect(comparison.differing == 100)
        #expect(comparison.matches == false)
    }

    @Test func test_a_change_within_the_channel_tolerance_is_not_a_difference() throws {
        let dark = OverlayBitmap(width: 10, height: 10)
        let darker = OverlayBitmap(width: 10, height: 10)
        dark.context.setFillColor(CGColor(srgbRed: 100 / 255, green: 100 / 255, blue: 100 / 255, alpha: 1))
        darker.context.setFillColor(CGColor(srgbRed: 102 / 255, green: 100 / 255, blue: 100 / 255, alpha: 1))
        dark.context.fill(dark.bounds)
        darker.context.fill(darker.bounds)

        let comparison = OverlaySnapshotAssert.compare(try #require(dark.context.makeImage()),
                                                       try #require(darker.context.makeImage()))

        #expect(comparison.differing == 0)
    }

    @Test func test_images_of_different_sizes_never_match() throws {
        let small = try #require(OverlayBitmap(width: 10, height: 10).context.makeImage())
        let large = try #require(OverlayBitmap(width: 20, height: 10).context.makeImage())

        #expect(OverlaySnapshotAssert.compare(small, large).matches == false)
    }
}
