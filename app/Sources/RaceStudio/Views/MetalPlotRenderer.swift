import SwiftUI
import MetalKit
import RaceStudioCore

/// The primary Metal line-strip renderer (issue 4.1, ADR 0003).
///
/// Wraps an `MTKView` that draws one GPU line strip per trace. Vertices come
/// from ``plotPolyline(trace:mode:columns:)`` (the shared
/// `RaceStudioCore.envelope` decimation) placed into normalised device
/// coordinates by `RaceStudioCore.LinearScale`. All geometry is computed in the
/// core; this view only uploads and draws.
struct MetalPlotRenderer: NSViewRepresentable {
    let traces: [ChannelTrace]
    let mode: XAxisMode
    let viewport: PlotViewport
    let valueDomain: ClosedRange<Double>
    let columns: Int

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 0)
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.delegate = context.coordinator
        context.coordinator.configure(device: view.device)
        context.coordinator.rebuild(traces: traces, mode: mode, viewport: viewport,
                                    valueDomain: valueDomain, columns: columns)
        return view
    }

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.rebuild(traces: traces, mode: mode, viewport: viewport,
                                    valueDomain: valueDomain, columns: columns)
        view.setNeedsDisplay(view.bounds)
    }

    /// The `MTKViewDelegate` that owns the pipeline and per-trace vertex buffers.
    final class Coordinator: NSObject, MTKViewDelegate {
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipeline: MTLRenderPipelineState?
        private var strips: [(buffer: MTLBuffer, count: Int)] = []

        func configure(device: MTLDevice?) {
            guard let device else { return }
            self.device = device
            commandQueue = device.makeCommandQueue()

            let source = """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 plot_vertex(const device float2 *points [[buffer(0)]],
                                      uint vid [[vertex_id]]) {
                return float4(points[vid], 0.0, 1.0);
            }
            fragment float4 plot_fragment() {
                return float4(0.20, 0.78, 1.0, 1.0);
            }
            """
            guard let library = try? device.makeLibrary(source: source, options: nil) else { return }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "plot_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "plot_fragment")
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        /// Maps each trace's decimated polyline into NDC `[-1, 1]²` via
        /// `LinearScale` and uploads it to a vertex buffer.
        func rebuild(traces: [ChannelTrace], mode: XAxisMode, viewport: PlotViewport,
                     valueDomain: ClosedRange<Double>, columns: Int) {
            guard let device else { return }
            let xScale = LinearScale(domain: viewport.visible, range: -1...1)
            let yScale = LinearScale(domain: valueDomain, range: -1...1)

            strips = traces.compactMap { trace in
                let vertices = plotPolyline(trace: trace, mode: mode, columns: columns).map { point in
                    SIMD2<Float>(Float(xScale.map(point.x)), Float(yScale.map(point.y)))
                }
                guard vertices.count > 1,
                      let buffer = device.makeBuffer(
                        bytes: vertices,
                        length: vertices.count * MemoryLayout<SIMD2<Float>>.stride,
                        options: .storageModeShared) else { return nil }
                return (buffer, vertices.count)
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            guard let pipeline, let commandQueue,
                  let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
            encoder.setRenderPipelineState(pipeline)
            for strip in strips {
                encoder.setVertexBuffer(strip.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: strip.count)
            }
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }
}
