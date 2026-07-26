import SwiftUI
import RaceStudioCore

/// A single-sided amplitude spectrum plot (issue 8.16): amplitude vs frequency
/// (Hz) for one channel, with the dominant-frequency peak marked — the RaceStudio
/// 3 **Frequency Analysis** view for damper / vibration work.
///
/// Thin: the FFT + resampling + window taper are the engine's (`fft_spectrum`),
/// and the point assembly + peak are `RaceStudioCore.SpectrumModel`; this view only
/// maps the points to pixels with the 4.1 `LinearScale` (both axes anchored at 0),
/// fills the spectrum area, and labels the axes with the 4.1 `TickGenerator`. It
/// carries no math of its own.
public struct SpectrumView: View {
    private let points: [SpectrumPoint]
    private let peak: SpectrumPoint?
    private let lineColor: PlotColor

    // Domains derived once from the (immutable) points, not per frame. Frequency
    // is anchored at 0 (spectra start at DC); amplitude at 0 (amplitudes are
    // non-negative), so the area reads as bars rising from the axis.
    private let freqDomain: ClosedRange<Double>
    private let ampDomain: ClosedRange<Double>

    public init(points: [SpectrumPoint], peak: SpectrumPoint? = nil,
                lineColor: PlotColor = PlotColor.palette[0]) {
        self.points = points
        self.peak = peak
        self.lineColor = lineColor
        let maxFreq = points.map(\.frequency).max() ?? 0
        let maxAmp = points.map(\.amplitude).max() ?? 0
        self.freqDomain = 0...max(maxFreq, 1)
        self.ampDomain = 0...max(maxAmp, 1)
    }

    public var body: some View {
        Canvas { context, size in
            guard !points.isEmpty else { return }
            let width = max(size.width, 1)
            let height = max(size.height, 1)
            let xScale = LinearScale(domain: freqDomain, range: 0...width)
            let yScale = LinearScale(domain: ampDomain, range: 0...height)

            // Grid + peak render for any non-empty spectrum; the area/line needs at
            // least two points to span (a lone DC bin shows just the grid + marker).
            drawGrid(context, width: width, height: height, xScale: xScale, yScale: yScale)
            drawSpectrum(context, height: height, xScale: xScale, yScale: yScale)
            drawPeak(context, height: height, xScale: xScale, yScale: yScale)
        }
        .padding(8)
        .accessibilityLabel(L10n.string(.chartSpectrum))
    }

    /// Fills the area under the amplitude curve and strokes its outline, so the
    /// spectrum reads as a solid shape rising from the frequency axis.
    private func drawSpectrum(_ context: GraphicsContext, height: CGFloat,
                              xScale: LinearScale, yScale: LinearScale) {
        guard points.count >= 2 else { return }
        func pixel(_ point: SpectrumPoint) -> CGPoint {
            CGPoint(x: xScale.map(point.frequency), y: height - yScale.map(point.amplitude))
        }
        var line = Path()
        line.move(to: pixel(points[0]))
        for point in points.dropFirst() { line.addLine(to: pixel(point)) }

        var area = line
        area.addLine(to: CGPoint(x: xScale.map(points[points.count - 1].frequency), y: height))
        area.addLine(to: CGPoint(x: xScale.map(points[0].frequency), y: height))
        area.closeSubpath()

        context.fill(area, with: .color(Color(lineColor).opacity(0.25)))
        context.stroke(line, with: .color(Color(lineColor)), lineWidth: 1.5)
    }

    /// Marks the dominant frequency with a vertical guide + dot, when present.
    private func drawPeak(_ context: GraphicsContext, height: CGFloat,
                          xScale: LinearScale, yScale: LinearScale) {
        guard let peak else { return }
        let px = xScale.map(peak.frequency)
        let py = height - yScale.map(peak.amplitude)
        var guideLine = Path()
        guideLine.move(to: CGPoint(x: px, y: height))
        guideLine.addLine(to: CGPoint(x: px, y: py))
        context.stroke(guideLine, with: .color(.secondary), lineWidth: 1)
        let dot = CGRect(x: px - 3, y: py - 3, width: 6, height: 6)
        context.fill(Path(ellipseIn: dot), with: .color(Color(lineColor)))
    }

    /// Faint gridlines with axis labels from `TickGenerator`.
    private func drawGrid(_ context: GraphicsContext, width: CGFloat, height: CGFloat,
                          xScale: LinearScale, yScale: LinearScale) {
        let grid = GraphicsContext.Shading.color(.secondary.opacity(0.25))
        for tick in TickGenerator.ticks(for: freqDomain, targetCount: 6) {
            let px = xScale.map(tick)
            var vertical = Path()
            vertical.move(to: CGPoint(x: px, y: 0))
            vertical.addLine(to: CGPoint(x: px, y: height))
            context.stroke(vertical, with: grid, lineWidth: 0.5)
            context.draw(AxisLabel.text(tick), at: CGPoint(x: px, y: height - 8))
        }
        for tick in TickGenerator.ticks(for: ampDomain, targetCount: 5) {
            let py = height - yScale.map(tick)
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: py))
            horizontal.addLine(to: CGPoint(x: width, y: py))
            context.stroke(horizontal, with: grid, lineWidth: 0.5)
            context.draw(AxisLabel.text(tick), at: CGPoint(x: 16, y: py))
        }
    }
}

// MARK: - Spectrum panel (issue 8.16)

/// Hosts the reused ``SpectrumView`` for the first selected channel's amplitude
/// spectrum: a window-function picker chooses the taper, and — as required — the
/// spectrum recomputes whenever that choice (or the selected channel) changes. The
/// FFT + resampling live in the engine (`fft_spectrum`) and the point assembly in
/// `RaceStudioCore.SpectrumModel`; this view only lays out the plot + controls.
///
/// The `fft_spectrum` read crosses the FFI synchronously on the main actor, so —
/// like ``SplitTimesPanel`` — it is cached in `@State` and recomputed only when the
/// `(channel, window function)` key changes, not on every unrelated
/// ``AnalysisWindowModel`` publish (a channel-search keystroke, a lap toggle). The
/// taper choice lives in the window-level ``SpectrumPanelModel`` so it survives
/// layout switches.
struct SpectrumPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var spectrum: SpectrumPanelModel
    /// The live analysis pump the spectrum is transformed from; `nil` in a non-FFI
    /// build/preview, which then shows a decoded-session hint.
    let analysis: AnalysisSession?

    /// The computed spectrum, cached so a re-render never re-marshals the FFT across
    /// the FFI; recomputed only when ``cacheKey`` changes.
    @State private var panel: SpectrumModel?
    @State private var loadedKey: CacheKey?

    /// The inputs that determine the spectrum — a change to either recomputes it.
    private struct CacheKey: Equatable {
        let channel: String
        let windowFunction: SpectrumWindowKind
    }

    /// The channel the spectrum is taken from — the first selected channel, or `nil`
    /// when none is selected.
    private var channel: String? { model.traces.first?.name }

    var body: some View {
        Group {
            if analysis == nil {
                ContentUnavailableHint(text: "Frequency analysis needs a decoded session")
            } else if let channel {
                VStack(spacing: 0) {
                    controls(channel: channel, peak: panel?.peak)
                    Divider()
                    plot
                }
            } else {
                ContentUnavailableHint(text: "Select a channel to see its frequency spectrum")
            }
        }
        .onAppear { recompute() }
        .onChange(of: channel) { _ in recompute() }
        .onChange(of: spectrum.windowFunction) { _ in recompute() }
    }

    /// The cached spectrum plot, or an empty-state hint when the channel has too few
    /// samples to transform (or the first compute has not landed yet).
    @ViewBuilder private var plot: some View {
        if let panel, !panel.isEmpty {
            SpectrumView(points: panel.points, peak: panel.peak)
        } else if panel != nil {
            ContentUnavailableHint(text: "This channel has too few samples to transform")
        } else {
            Color.clear // first compute lands on appear
        }
    }

    /// Recompute the spectrum only when the `(channel, window function)` key changes,
    /// so a re-render from an unrelated model publish does not re-cross the FFI.
    private func recompute() {
        guard let analysis, let channel else {
            panel = nil
            loadedKey = nil
            return
        }
        let key = CacheKey(channel: channel, windowFunction: spectrum.windowFunction)
        guard loadedKey != key else { return }
        panel = SpectrumModel.compute(from: analysis, channel: channel,
                                      windowFunction: spectrum.windowFunction)
        loadedKey = key
    }

    /// The channel title, the window-function picker (criterion 2), and the
    /// dominant-frequency readout (the headline number for a vibration read).
    private func controls(channel: String, peak: SpectrumPoint?) -> some View {
        HStack(spacing: 16) {
            Text(channel).font(.caption.bold())
            Picker("Window", selection: Binding(
                get: { spectrum.windowFunction },
                set: { spectrum.setWindowFunction($0) })) {
                ForEach(SpectrumWindowKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.menu)
            .fixedSize()
            if let peak {
                Text("Peak: \(peak.frequency, specifier: "%.1f") Hz")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
