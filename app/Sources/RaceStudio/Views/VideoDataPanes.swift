import SwiftUI
import RaceStudioCore

// MARK: - Lap strip plot

/// The Video + Data strip plot (issue 9.12): speed and RPM across the plotted
/// lap, each in its own range, with the shared cursor drawn on it. A click or
/// drag scrubs the cursor (the panel pauses first, so the footage follows).
///
/// Thin: the samples, the scaling and the time ↔ position mapping are
/// ``LapStripPlot``'s.
struct LapStripPlotView: View {
    @ObservedObject var data: VideoDataViewModel
    @ObservedObject var cursor: LinkedCursor
    let units: UnitSystem
    /// Told the session time under a click or drag.
    let onScrub: (Double) -> Void

    private static let colors = [Color(PlotColor.palette[0]), Color(PlotColor.palette[1])]

    var body: some View {
        if let plot = data.stripPlot {
            VStack(alignment: .leading, spacing: 2) {
                legend(plot)
                GeometryReader { geometry in
                    Canvas { context, size in
                        draw(plot, in: context, size: size)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        guard geometry.size.width > 0 else { return }
                        onScrub(plot.time(atFraction: value.location.x / geometry.size.width))
                    })
                }
            }
            .padding(6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(L10n.string(.videoPanePlot))
        } else {
            ContentUnavailableHint(text: L10n.string(.videoLoadingTelemetry), symbol: "chart.xyaxis.line")
        }
    }

    private func legend(_ plot: LapStripPlot) -> some View {
        HStack(spacing: 12) {
            Text(L10n.format(.videoLapLabel, String(plot.lap.index + 1))).font(.caption.bold())
            ForEach(Array(plot.traces.enumerated()), id: \.offset) { index, trace in
                HStack(spacing: 4) {
                    Circle().fill(Self.colors[index % Self.colors.count]).frame(width: 8, height: 8)
                    Text(OverlayWidgetKind.channelValue(.role(trace.role)).title())
                    Text(trace.rangeLabel(units: units) ?? "—").foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
            Spacer()
        }
    }

    private func draw(_ plot: LapStripPlot, in context: GraphicsContext, size: CGSize) {
        let inset = size.height * 0.06
        let height = size.height - 2 * inset
        let last = max(plot.times.count - 1, 1)
        for (index, trace) in plot.traces.enumerated() {
            var path = Path()
            var drawing = false
            for sample in trace.values.indices {
                guard let level = trace.level(at: sample) else { drawing = false; continue }
                let point = CGPoint(x: size.width * CGFloat(sample) / CGFloat(last),
                                    y: inset + height * (1 - CGFloat(level)))
                if drawing { path.addLine(to: point) } else { path.move(to: point) }
                drawing = true
            }
            context.stroke(path, with: .color(Self.colors[index % Self.colors.count]), lineWidth: 1.5)
        }
        if let fraction = plot.fraction(atTime: cursor.timePosition) {
            let x = size.width * CGFloat(fraction)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(line, with: .color(.primary.opacity(0.8)), lineWidth: 1)
        }
    }
}

// MARK: - Track map

/// The Video + Data track map (issue 9.12): the plotted lap's racing line, the
/// review's sector marks and the kart's dot at the cursor, reusing the 4.3
/// ``TrackMapView``. A click or drag moves the cursor to that point of the lap.
struct VideoDataMapPane: View {
    @ObservedObject var data: VideoDataViewModel
    @ObservedObject var cursor: LinkedCursor
    /// Told the session time under a click or drag.
    let onSeek: (Double) -> Void
    @AppStorage("trackMap.backdrop") private var backdropRaw = TrackMapBackdrop.default.rawValue

    var body: some View {
        if let map = data.lapMap, !map.coordinates.isEmpty {
            TrackMapView(coords: map.coordinates, distances: map.sectorDistances, channelValues: [],
                         colorScale: map.colorScale, lapDistance: map.lapDistance, sectorSplits: 0,
                         runStarts: map.runStarts, runSlots: map.runSlots, runLapNumbers: map.runLapNumbers,
                         colorsByLap: true, markers: data.trackMarkers(atTime: cursor.timePosition),
                         backdrop: TrackMapBackdrop(rawValue: backdropRaw) ?? .default,
                         sectorMarks: data.sectorMarks,
                         cursorIndex: Binding(
                            get: { map.index(atTime: cursor.timePosition) },
                            set: { index in
                                if let index, let time = data.sessionTime(atFix: index) { onSeek(time) }
                            }))
                .padding(6)
        } else {
            ContentUnavailableHint(text: L10n.string(.videoNoGPS), symbol: "map")
        }
    }
}

// MARK: - Resizable split

/// Two panes split by a draggable divider (issue 9.12), sized by one of the
/// ``VideoDataPaneLayout`` fractions; either pane may be hidden, the other then
/// taking the whole length. The drag arithmetic is ``VideoDataPaneLayout``'s.
///
/// Each pane sits in its own fixed slot of one stack, so hiding the plot never
/// tears down the player beside it, and a hidden pane is not built at all (it
/// does no per-frame work). A drag is measured in window coordinates (the
/// divider moves under the pointer), previewed through gesture state — which
/// resets itself if the drag is cancelled — and written to the workspace when
/// it ends.
struct FractionSplit<Leading: View, Trailing: View>: View {
    let axis: Axis
    let divider: VideoDataDivider
    @Binding var panes: VideoDataPaneLayout
    let showsLeading: Bool
    let showsTrailing: Bool
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing
    /// How far the divider has been dragged, in points along the split.
    @GestureState private var dragTranslation: CGFloat = 0
    @State private var showsResizeCursor = false

    private static var handleThickness: CGFloat { 6 }

    var body: some View {
        GeometryReader { geometry in
            let both = showsLeading && showsTrailing
            let total = axis == .horizontal ? geometry.size.width : geometry.size.height
            let length = max(0, total - (both ? Self.handleThickness : 0))
            let sized = length * CGFloat(layout(draggedBy: dragTranslation, across: length).fraction(divider))
            // The map divider sizes the pane before it; the others the pane after.
            let leadingLength = divider == .map ? sized : length - sized
            let stack = axis == .horizontal ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            stack {
                if showsLeading {
                    leading()
                        .frame(width: both && axis == .horizontal ? leadingLength : nil,
                               height: both && axis == .vertical ? leadingLength : nil)
                        .frame(maxWidth: both ? nil : .infinity, maxHeight: both ? nil : .infinity)
                }
                if both { handle(length: length) }
                if showsTrailing {
                    trailing().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    /// The pane layout with the divider moved `translation` points along a
    /// `length`-point split.
    private func layout(draggedBy translation: CGFloat, across length: CGFloat) -> VideoDataPaneLayout {
        var dragged = panes
        dragged.drag(divider, from: panes.fraction(divider), by: Double(translation), across: Double(length))
        return dragged
    }

    private func handle(length: CGFloat) -> some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: axis == .horizontal ? Self.handleThickness : nil,
               height: axis == .vertical ? Self.handleThickness : nil)
        .contentShape(Rectangle())
        .onHover { setResizeCursor($0) }
        .onDisappear { setResizeCursor(false) }
        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .updating($dragTranslation) { value, state, _ in
                state = axis == .horizontal ? value.translation.width : value.translation.height
            }
            .onEnded { value in
                panes = layout(draggedBy: axis == .horizontal ? value.translation.width : value.translation.height,
                               across: length)
            })
    }

    /// Show or restore the resize cursor, pushing and popping it in pairs.
    private func setResizeCursor(_ shown: Bool) {
        guard shown != showsResizeCursor else { return }
        showsResizeCursor = shown
        if shown {
            (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
        } else {
            NSCursor.pop()
        }
    }
}
