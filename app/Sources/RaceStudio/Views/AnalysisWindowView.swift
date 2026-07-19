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
            case .channelTable:
                ChannelTablePanel(model: model, cursor: model.linkedCursor)
            case .trackMap:
                TrackMapPanel(model: model, cursor: model.linkedCursor)
            case .summary:
                SessionSummaryView(viewModel: SessionSummaryViewModel(session: model.session))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Channel table / measures panel (issue 8.5)

/// Hosts the reused ``ChannelTableView`` bound to the shared cursor: it observes
/// ``LinkedCursor`` so the value-at-cursor readouts re-render as the cursor moves,
/// while the channels × selected-laps grid (and its per-lap extrapolation) is
/// derived in `RaceStudioCore.AnalysisWindowModel`. Tapping a channel name pins
/// it as a large readout; tapping a lap header makes it the reference the row
/// deltas are measured against.
private struct ChannelTablePanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        if model.readoutTable.rows.isEmpty || model.readoutTable.columns.isEmpty {
            ContentUnavailableHint(text: "Select channels and laps to compare")
        } else {
            ScrollView([.horizontal, .vertical]) {
                ChannelTableView(model: model.readoutTable,
                                 cursorX: cursor.timePosition,
                                 formatters: model.channelFormatters,
                                 pinned: model.pinnedChannels,
                                 referenceLap: model.selection.laps.reference,
                                 onPin: { model.togglePinned($0) },
                                 onSetReference: { model.setReferenceLap($0) })
            }
        }
    }
}

// MARK: - Track map panel (issue 8.6)

/// Hosts the reused ``TrackMapView`` bound to the shared cursor both ways: it
/// observes ``LinkedCursor`` so the position marker follows every cursor move
/// (``AnalysisWindowModel/gpsCursorIndex``), and a hover / click on the map drives
/// the window's cursor (``AnalysisWindowModel/moveTrackCursor(toFix:)``). A colour
/// picker chooses which selected channel colours the line, and a stepper sets the
/// sector count; the racing line, its colour-by-channel, the colour scale, and the
/// nearest-fix mapping are all derived in `RaceStudioCore`.
private struct TrackMapPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    // Observed so the position marker (`gpsCursorIndex`, read in the binding below)
    // re-renders on every cursor move — do not remove even though `body` reads it
    // only through the model.
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        let map = model.trackMap
        if map.coordinates.isEmpty {
            ContentUnavailableHint(text: "No GPS data for this session")
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                TrackMapView(coords: map.coordinates,
                             distances: map.distances,
                             channelValues: map.channelValues,
                             colorScale: map.colorScale,
                             lapDistance: map.lapDistance,
                             sectorSplits: model.sectorSplits,
                             cursorIndex: Binding(
                                get: { model.gpsCursorIndex },
                                set: { if let index = $0 { model.moveTrackCursor(toFix: index) } }))
                    .padding(8)
            }
        }
    }

    /// Colour-by-channel picker (over the selected channels) + sector-count stepper.
    private var controls: some View {
        HStack(spacing: 16) {
            if !model.selection.channels.isEmpty {
                Picker("Colour", selection: Binding(
                    get: { model.colorChannel },
                    set: { if let channel = $0 { model.setColorChannel(channel) } })) {
                    ForEach(model.selection.channels, id: \.self) { channel in
                        Text(channel.name).tag(Optional(channel))
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            Stepper("Sectors: \(model.sectorSplits)", value: Binding(
                get: { model.sectorSplits },
                set: { model.setSectorSplits($0) }), in: 0...12)
                .fixedSize()
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
