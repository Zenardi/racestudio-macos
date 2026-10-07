import AVFoundation
import Foundation
import Testing
@testable import RaceStudioCore

/// A cancel keeps `AVVideoCompositing`'s contract (issue 203): on
/// `cancelAllPendingVideoCompositionRequests` the compositor "must block until
/// it has either cancelled all pending frame requests … or … finished
/// processing" them, so no request outlives the read that asked for it.
/// (`AVAssetReader.cancelReading()` itself waits for the frame on this OS; the
/// contract is the compositor's, so the test asks the compositor directly.)
@Suite(.enabled(if: VideoTests.isEnabled, VideoTests.skipReason)) struct OverlayCompositorCancelTests {

    @Test(.timeLimit(.minutes(1)))
    func test_a_cancel_waits_for_the_frame_being_composed() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let gate = DrawGate()
        let overlay = ExportOverlay(drawer: GatedSessionTimeBar(gate: gate),
                                    telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))
        let composition = try await OverlayComposition.make(plan: plan, overlay: overlay)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await composition.asset.loadTracks(withMediaType: .video),
            videoSettings: OverlayCompositor.bgraAttributes)
        output.videoComposition = composition.videoComposition
        let reader = try AVAssetReader(asset: composition.asset)
        reader.add(output)
        #expect(reader.startReading())
        let compositor = try #require(output.customVideoCompositor as? OverlayCompositor)
        defer { reader.cancelReading() }

        let order = await cancelWhileDrawing(compositor, gate: gate)

        #expect(order == ["draw released", "cancel returned"])
    }

    /// Hold the first frame's draw — AVFoundation composes ahead once the read
    /// starts, with no sample asked for — cancel the compositor's requests, and
    /// release the draw a moment later; the order in which the draw was
    /// released and the cancel returned. Blocks a global queue, never a
    /// cooperative thread.
    private func cancelWhileDrawing(_ compositor: OverlayCompositor, gate: DrawGate) async -> [String] {
        return await withCheckedContinuation { done in
            DispatchQueue.global().async {
                let order = EventOrder()
                guard gate.waitUntilEntered() else {
                    done.resume(returning: ["the draw never started"])
                    return
                }
                let cancelled = DispatchSemaphore(value: 0)
                DispatchQueue.global().async {
                    compositor.cancelAllPendingVideoCompositionRequests()
                    order.record("cancel returned")
                    cancelled.signal()
                }
                Thread.sleep(forTimeInterval: 0.3)
                order.record("draw released")
                gate.open()
                _ = cancelled.wait(timeout: .now() + 10)
                done.resume(returning: order.events)
            }
        }
    }
}

/// Holds the first draw that passes it until ``open()``.
final class DrawGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private let entered = DispatchSemaphore(value: 0)
    private let opened = DispatchSemaphore(value: 0)

    /// Called by the drawer: the first caller waits for ``open()``.
    func pass() {
        let first = lock.withLock { () -> Bool in
            defer { held = true }
            return !held
        }
        guard first else { return }
        entered.signal()
        opened.wait()
    }

    /// Whether a draw reached the gate within 10 s.
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 10) == .success }

    func open() { opened.signal() }
}

/// The session-time bar, its first draw held at a ``DrawGate``.
struct GatedSessionTimeBar: OverlayFrameDrawing {
    let gate: DrawGate
    var bar = SessionTimeBar(origin: 0)

    func prepare(for size: CGSize) {}

    func draw(_ frame: TelemetryFrame, in context: CGContext, size: CGSize) {
        gate.pass()
        bar.draw(frame, in: context, size: size)
    }
}

/// Events recorded from several threads, in the order they happened.
private final class EventOrder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func record(_ event: String) { lock.withLock { recorded.append(event) } }
    var events: [String] { lock.withLock { recorded } }
}
