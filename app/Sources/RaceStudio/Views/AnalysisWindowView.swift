import SwiftUI
import RaceStudioCore

/// The RaceStudio-3-style analysis window (issue 8.3): a left layout-selector
/// rail, a channels+laps side panel, a central panel host, and a bottom measures
/// bar, all sharing one window-level ``LinkedCursor``.
///
/// Deliberately **thin**: the layout/selection/cursor/measures logic all lives in
/// `RaceStudioCore.AnalysisWindowModel`, so this view only lays out the regions
/// and forwards taps/scrubs into the model. The Time/Distance layout reuses
/// ``TimeDistancePlotView``; the summary layout reuses ``SessionSummaryView``.
struct AnalysisWindowView: View {
    @StateObject private var model: AnalysisWindowModel

    init(viewModel: SessionViewModel) {
        _model = StateObject(wrappedValue: AnalysisWindowModel(viewModel: viewModel))
    }

    var body: some View {
        HStack(spacing: 0) {
            LayoutRail(layouts: model.layouts, active: model.activeLayout) { model.select(layout: $0) }
            Divider()
            ChannelsLapsPanelView(model: model)
                .frame(width: 240)
            Divider()
            VStack(spacing: 0) {
                PanelHost(model: model)
                Divider()
                MeasuresBar(model: model, cursor: model.linkedCursor)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("Analysis window")
    }
}

// MARK: - Layout rail

/// The left rail: one button per layout, highlighting the active one.
private struct LayoutRail: View {
    let layouts: [WindowLayout]
    let active: WindowLayout
    let onSelect: (WindowLayout) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(layouts) { layout in
                Button { onSelect(layout) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: layout.systemImageName).font(.title3)
                        Text(layout.title).font(.caption2).multilineTextAlignment(.center)
                    }
                    .frame(width: 64, height: 56)
                    .background(layout == active ? Color.accentColor.opacity(0.2) : Color.clear)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .help(layout.title)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .frame(width: 80)
    }
}

// MARK: - Central panel host

/// Swaps the central panel for the active layout, preserving the surrounding
/// selection/cursor state (owned by the model).
private struct PanelHost: View {
    @ObservedObject var model: AnalysisWindowModel

    var body: some View {
        Group {
            switch model.activeLayout {
            case .timeDistance:
                if model.selection.isEmpty {
                    ContentUnavailableHint(text: "Select a channel to plot")
                } else {
                    TimeDistancePlotView(traces: model.traces, mode: .time)
                }
            case .summary:
                SessionSummaryView(viewModel: SessionSummaryViewModel(session: model.session))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A centered, secondary placeholder shown when a panel has nothing to render.
private struct ContentUnavailableHint: View {
    let text: String
    var body: some View {
        Text(text).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Measures bar (scrubber + value-at-cursor)

/// The bottom bar: a cursor scrubber (moving the shared cursor along the time
/// axis) and the value-at-cursor for every selected channel.
private struct MeasuresBar: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        VStack(spacing: 6) {
            scrubber
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(model.measures) { measure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(measure.channel.name).font(.caption2).foregroundColor(.secondary)
                            Text(measure.formatted)
                                .font(.body.monospacedDigit())
                                .foregroundColor(measure.readout.extrapolated ? .secondary : .primary)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity)
    }

    /// A slider bound to the cursor's time position over its scrub range; hidden
    /// when the session has no positive-width extent (decided in Core).
    @ViewBuilder private var scrubber: some View {
        if let range = cursor.scrubRange {
            HStack(spacing: 12) {
                Text(String(format: "t = %.2f s", cursor.timePosition))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                    .frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { cursor.timePosition },
                                      set: { cursor.moveTime($0) }),
                       in: range)
            }
        }
    }
}
