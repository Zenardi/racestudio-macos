import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The renderer's output is ready to alpha-blend (issue 9.11): premultiplied
/// BGRA in sRGB, fully transparent (alpha 0) everywhere outside the widgets, in
/// every preset, frame and aspect.
@Suite struct OverlayRendererTransparencyTests {

    private static let frames = [OverlayRenderFixture.midLap, OverlayRenderFixture.lapStartFrame,
                                 OverlayRenderFixture.gap]

    private func renderer(_ layout: OverlayLayout) -> OverlayRenderer {
        OverlayRenderer(layout: layout, session: OverlayRenderFixture.session(), track: OverlayRenderFixture.track,
                        sectors: OverlayRenderFixture.sectors)
    }

    /// The pixel rects of the widgets `layout` draws at `size`.
    private func widgetRects(_ layout: OverlayLayout, width: Int, height: Int) -> [CGRect] {
        layout.drawable(for: OverlayAspect(width: Double(width), height: Double(height)),
                        session: OverlayRenderFixture.session())
            .map { OverlayRenderer.pixelRect(of: $0.frame, width: width, height: height) }
    }

    @Test(arguments: OverlayPreset.allCases, [0, 1, 2])
    func test_pixels_outside_every_widget_are_transparent(_ preset: OverlayPreset, _ frameIndex: Int) throws {
        let layout = preset.layout(locale: Locale(identifier: "en"))
        let image = try #require(renderer(layout).makeImage(Self.frames[frameIndex],
                                                            size: CGSize(width: 1280, height: 720)))
        let bitmap = OverlayBitmap(image: image)
        let rects = widgetRects(layout, width: 1280, height: 720)

        let paintedOutside = bitmap.paintedPixels(outside: rects)

        #expect(rects.reduce(0) { $0 + $1.width * $1.height } < 1280 * 720)
        #expect(paintedOutside == 0, "\(paintedOutside) painted pixels outside the widgets")
        #expect(bitmap.paintedPixels(outside: []) > 0)
    }

    @Test(arguments: [(1080, 1080), (1080, 1920), (1440, 1080)])
    func test_other_aspects_stay_transparent_outside_the_widgets(_ width: Int, _ height: Int) throws {
        let layout = OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))
        let image = try #require(renderer(layout).makeImage(OverlayRenderFixture.midLap,
                                                            size: CGSize(width: width, height: height)))
        let bitmap = OverlayBitmap(image: image)
        let rects = widgetRects(layout, width: width, height: height)

        #expect(bitmap.paintedPixels(outside: rects) == 0)
    }

    @Test func test_drawing_clears_what_the_context_held_before() {
        let layout = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))
        let bitmap = OverlayBitmap(width: 640, height: 360)
        bitmap.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.context.fill(bitmap.bounds)

        renderer(layout).draw(OverlayRenderFixture.midLap, in: bitmap.context, size: CGSize(width: 640, height: 360))

        #expect(bitmap.pixel(x: 320, y: 180).isTransparent)
    }

    @Test func test_a_size_the_renderer_cannot_draw_leaves_the_context_untouched() {
        let layout = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))
        let bitmap = OverlayBitmap(width: 64, height: 64)
        bitmap.context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        bitmap.context.fill(bitmap.bounds)

        renderer(layout).draw(OverlayRenderFixture.midLap, in: bitmap.context, size: CGSize(width: 1e30, height: 64))

        #expect(bitmap.pixel(x: 32, y: 32).matches(BrandColor(red: 1, green: 0, blue: 0)))
    }

    /// A shadow or a dash left set on the caller's context changes nothing.
    @Test func test_drawing_ignores_shadow_and_dash_left_on_the_context() throws {
        let layout = OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))
        let clean = OverlayBitmap(width: 640, height: 360)
        let dirty = OverlayBitmap(width: 640, height: 360)
        dirty.context.setShadow(offset: CGSize(width: 4, height: -4), blur: 3,
                                color: CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        dirty.context.setLineDash(phase: 0, lengths: [2, 3])
        let size = CGSize(width: 640, height: 360)

        renderer(layout).draw(OverlayRenderFixture.midLap, in: clean.context, size: size)
        renderer(layout).draw(OverlayRenderFixture.midLap, in: dirty.context, size: size)

        #expect(clean.bytes == dirty.bytes)
    }

    @Test func test_an_overlay_switched_off_draws_nothing() throws {
        var layout = OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))
        layout.isEnabled = false

        let image = try #require(renderer(layout).makeImage(OverlayRenderFixture.midLap,
                                                            size: CGSize(width: 640, height: 360)))

        #expect(OverlayBitmap(image: image).count { !$0.isTransparent } == 0)
    }

    // MARK: - Format

    @Test func test_images_are_premultiplied_bgra_in_srgb() throws {
        let layout = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))

        let image = try #require(renderer(layout).makeImage(OverlayRenderFixture.midLap,
                                                            size: CGSize(width: 1280, height: 720)))

        #expect(image.width == 1280)
        #expect(image.height == 720)
        #expect(image.bitsPerPixel == 32)
        #expect(image.alphaInfo == .premultipliedFirst)
        #expect(image.bitmapInfo.contains(.byteOrder32Little))
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    @Test(arguments: [CGSize(width: 0, height: 720), CGSize(width: -5, height: 10),
                      CGSize(width: CGFloat.nan, height: 10), CGSize(width: 9_000, height: 100),
                      CGSize(width: 0.4, height: 0.4), CGSize(width: 1e30, height: 10),
                      CGSize(width: 10, height: -1e30)])
    func test_a_size_the_renderer_cannot_draw_makes_no_image(_ size: CGSize) {
        let layout = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))

        #expect(renderer(layout).makeImage(OverlayRenderFixture.midLap, size: size) == nil)
    }

    @Test func test_a_widget_rect_maps_top_left_normalized_space_to_whole_pixels() {
        let rect = OverlayRenderer.pixelRect(of: NormalizedRect(x: 0.1, y: 0.2, width: 0.25, height: 0.5),
                                             width: 1000, height: 500)

        #expect(rect == CGRect(x: 100, y: 150, width: 250, height: 250))
    }
}
