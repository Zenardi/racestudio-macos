import CoreGraphics
import Foundation
import Testing
@testable import RaceStudioCore

/// The overlay renderer (issue 9.11): draws each available widget of a layout
/// in its resolved rect, caches the static layers per output size, and gives
/// the same bytes for the same inputs — on any thread.
@Suite struct OverlayRendererTests {

    private static let size = CGSize(width: 1280, height: 720)

    private func renderer(_ layout: OverlayLayout, session: OverlaySessionContext = OverlayRenderFixture.session(),
                          units: UnitSystem? = nil, theme: OverlayTheme? = nil) -> OverlayRenderer {
        OverlayRenderer(layout: layout, theme: theme, units: units, formatter: OverlayFormatter(), session: session,
                        track: OverlayRenderFixture.track, sectors: OverlayRenderFixture.sectors)
    }

    private func image(_ renderer: OverlayRenderer, _ frame: TelemetryFrame = OverlayRenderFixture.midLap,
                       size: CGSize = size) throws -> OverlayBitmap {
        OverlayBitmap(image: try #require(renderer.makeImage(frame, size: size)))
    }

    private func pixels(of widget: OverlayWidget, at size: CGSize = size) -> CGRect {
        OverlayRenderer.pixelRect(of: widget.frame.resolved(in: OverlayAspect(width: size.width, height: size.height),
                                                            anchor: widget.anchor),
                                  width: Int(size.width), height: Int(size.height))
    }

    private static let box = NormalizedRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)

    // MARK: - What is drawn

    /// Every kind of widget, alone in a layout, paints its rect.
    @Test(arguments: [OverlayWidgetKind.speed, .rpm, .gear, .lapTimer, .lapInfo, .delta, .gForce, .trackMap,
                      .pedals, .temperature, .sectorTimes, .channelValue(.role(.latG)),
                      .channelValue(.channel("Oil Temp")), .kartBadge, .sessionInfo])
    func test_every_widget_kind_paints_its_rect(_ kind: OverlayWidgetKind) throws {
        let widget = OverlayWidget(kind: kind, frame: Self.box)

        let bitmap = try image(renderer(OverlayLayout(name: "One", widgets: [widget])))

        #expect(bitmap.count(in: pixels(of: widget)) { !$0.isTransparent } > 100)
    }

    /// Every kind a layout can hold — the persisted `type`s — has a drawer.
    @Test func test_every_persisted_widget_kind_has_a_drawer() throws {
        let types = ["speed", "rpm", "gear", "lapTimer", "lapInfo", "delta", "gForce", "trackMap", "pedals",
                     "temperature", "sectorTimes", "kartBadge", "sessionInfo"]
        let plain = try types.map { type in
            try JSONDecoder().decode(OverlayWidgetKind.self, from: Data("{\"type\":\"\(type)\"}".utf8))
        }
        let readouts: [OverlayWidgetKind] = [.channelValue(.role(.rpm)), .channelValue(.channel("Oil Temp"))]

        #expect((plain + readouts).allSatisfy { $0.drawer != nil })
        #expect(OverlayWidgetKind.drawers.count == types.count + 1)
    }

    @Test func test_a_widget_the_session_cannot_feed_is_left_out() throws {
        let widget = OverlayWidget(kind: .rpm, frame: Self.box)
        let noRPM = OverlayRenderFixture.session(channels: OverlayRenderFixture.channels.filter { $0.name != "RPM" })

        let bitmap = try image(renderer(OverlayLayout(name: "RPM", widgets: [widget]), session: noRPM))

        #expect(bitmap.count { !$0.isTransparent } == 0)
    }

    @Test func test_a_degraded_widget_is_drawn_with_what_there_is() throws {
        let widget = OverlayWidget(kind: .pedals, frame: Self.box)
        let brakeOnly = OverlayRenderFixture.session(channels: OverlayRenderFixture.channels
            .filter { $0.name != "Throttle" })

        let bitmap = try image(renderer(OverlayLayout(name: "Pedals", widgets: [widget]), session: brakeOnly))

        #expect(bitmap.count(in: pixels(of: widget)) { !$0.isTransparent } > 100)
    }

    @Test func test_a_hidden_widget_is_not_drawn() throws {
        let widget = OverlayWidget(kind: .speed, frame: Self.box, isVisible: false)

        let bitmap = try image(renderer(OverlayLayout(name: "Hidden", widgets: [widget])))

        #expect(bitmap.count { !$0.isTransparent } == 0)
    }

    @Test func test_widget_opacity_fades_the_whole_widget() throws {
        let opaque = OverlayWidget(kind: .speed, frame: Self.box, plate: .solid)
        var faded = opaque
        faded.opacity = 0.5

        let full = try image(renderer(OverlayLayout(name: "Full", widgets: [opaque])))
        let half = try image(renderer(OverlayLayout(name: "Half", widgets: [faded])))

        let edge = CGPoint(x: pixels(of: opaque).midX, y: pixels(of: opaque).minY + 1)
        #expect(full.pixel(at: edge).alpha == 255)
        #expect(abs(Int(half.pixel(at: edge).alpha) - 128) <= 1)
    }

    @Test func test_widget_opacity_fades_the_g_trail_too() throws {
        var widget = OverlayWidget(kind: .gForce, frame: Self.box, plate: .none)
        let frame = TelemetryFrame(time: 1, values: [:],
                                   gTrail: [GForcePoint(time: 0.5, lateral: 0.8, longitudinal: 0.8),
                                            GForcePoint(time: 1, lateral: -0.8, longitudinal: 0.8)])
        let full = try image(renderer(OverlayLayout(name: "Full", widgets: [widget])), frame)
        widget.opacity = 0.5
        let half = try image(renderer(OverlayLayout(name: "Half", widgets: [widget])), frame)

        let trail = full.positions { $0.alpha > 0 && $0.red > $0.blue + 40 }
        let point = try #require(trail.max { full.pixel(at: $0).alpha < full.pixel(at: $1).alpha })
        let ratio = Double(half.pixel(at: point).alpha) / Double(full.pixel(at: point).alpha)
        #expect(abs(ratio - 0.5) < 0.05)
    }

    @Test func test_the_units_and_theme_default_to_the_layout() {
        var layout = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))
        layout.units = .imperial

        let plain = renderer(layout)
        let metric = renderer(layout, units: .metric)

        #expect(plain.layout.units == .imperial)
        #expect(metric.layout.units == .metric)
        #expect(plain.theme == layout.theme)
    }

    // MARK: - Static layers

    @Test func test_static_layers_are_built_once_per_output_size() {
        let renderer = renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")))

        _ = renderer.makeImage(OverlayRenderFixture.midLap, size: Self.size)
        _ = renderer.makeImage(OverlayRenderFixture.lapStartFrame, size: Self.size)
        _ = renderer.makeImage(OverlayRenderFixture.gap, size: Self.size)
        let afterOneSize = renderer.staticLayerBuildCount
        _ = renderer.makeImage(OverlayRenderFixture.midLap, size: CGSize(width: 1920, height: 1080))
        _ = renderer.makeImage(OverlayRenderFixture.midLap, size: Self.size)

        #expect(afterOneSize == 1)
        #expect(renderer.staticLayerBuildCount == 2)
    }

    @Test func test_the_static_layer_cache_keeps_only_recent_sizes() {
        let renderer = renderer(OverlayPreset.minimal.layout(locale: Locale(identifier: "en")))
        let sizes = (0...StaticLayerCache.capacity).map { CGSize(width: 320 + 16 * $0, height: 180) }

        for size in sizes { _ = renderer.makeImage(OverlayRenderFixture.midLap, size: size) }
        _ = renderer.makeImage(OverlayRenderFixture.midLap, size: sizes[0])

        #expect(renderer.staticLayerBuildCount == sizes.count + 1)
    }

    // MARK: - Determinism

    @Test func test_the_same_frame_renders_the_same_bytes() throws {
        let renderer = renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")))
        let other = self.renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")))

        let first = try image(renderer).bytes
        let second = try image(renderer).bytes
        let fresh = try image(other).bytes

        #expect(first == second)
        #expect(first == fresh)
    }

    @Test func test_rendering_on_many_threads_at_once_gives_the_same_bytes() throws {
        let renderer = renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")))
        let expected = try image(self.renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en"))))
            .bytes
        let results = ConcurrentResults()

        DispatchQueue.concurrentPerform(iterations: 8) { index in
            let image = renderer.makeImage(OverlayRenderFixture.midLap, size: Self.size)
            results.store(index, image.map { OverlayBitmap(image: $0).bytes } ?? [])
        }

        #expect(results.all.count == 8)
        #expect(results.all.allSatisfy { $0 == expected })
        #expect(renderer.staticLayerBuildCount == 1)
    }

    /// Given many renderers building their static layers on as many threads at
    /// once — plates being filled beside G-trails being drawn — then every
    /// render matches one made alone. (Blending the translucent plates raced
    /// inside CoreGraphics and corrupted a few of every 72 such renders.)
    @Test func test_renderers_built_on_many_threads_at_once_match_a_render_made_alone() throws {
        func make() -> OverlayRenderer {
            renderer(OverlayPreset.fullTelemetry.layout(locale: Locale(identifier: "en")))
        }
        let expected = try image(make()).bytes
        let results = ConcurrentResults()

        for round in 0..<3 {
            DispatchQueue.concurrentPerform(iterations: 12) { index in
                let image = make().makeImage(OverlayRenderFixture.midLap, size: Self.size)
                results.store(round * 12 + index, image.map { OverlayBitmap(image: $0).bytes } ?? [])
            }
        }

        #expect(results.all.count == 36)
        #expect(results.all.filter { $0 != expected }.isEmpty)
    }

    /// Results written by concurrent workers.
    private final class ConcurrentResults: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int: [UInt8]] = [:]

        func store(_ index: Int, _ bytes: [UInt8]) {
            lock.withLock { values[index] = bytes }
        }

        var all: [[UInt8]] { lock.withLock { Array(values.values) } }
    }
}
