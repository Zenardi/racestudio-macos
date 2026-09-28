import SwiftUI
import RaceStudioCore

// MARK: - Track map panel (issue 8.6)

/// Hosts the reused ``TrackMapView`` bound to the shared cursor both ways: it
/// observes ``LinkedCursor`` so each selected lap's position marker follows every
/// cursor move (``AnalysisWindowModel/trackMapMarkers``), and a hover / click on
/// the map drives the window's cursor (``AnalysisWindowModel/moveTrackCursor(toFix:)``).
/// A colour picker colours the line by lap or by a selected channel, and a stepper
/// sets the sector count; the racing line, its colouring, the colour scale, the
/// markers, and the nearest-fix mapping are all derived in `RaceStudioCore`.
struct TrackMapPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    // Observed so the position markers (`trackMapMarkers`, read below) re-render on
    // every cursor move — do not remove even though `body` reads the cursor only
    // through the model.
    @ObservedObject var cursor: LinkedCursor
    /// The map imagery under the racing line. Persisted, and off by default so the
    /// app stays readable and makes no network requests unless asked.
    @AppStorage("trackMap.backdrop") private var backdropRaw = TrackMapBackdrop.default.rawValue

    private var backdrop: TrackMapBackdrop {
        TrackMapBackdrop(rawValue: backdropRaw) ?? .default
    }

    var body: some View {
        let map = model.trackMap
        if model.trackMapNeedsLapSelection {
            ContentUnavailableHint(text: "Select one or more laps to show them on the map",
                                   symbol: "flag.checkered")
        } else if map.coordinates.isEmpty {
            ContentUnavailableHint(text: model.hasGPSTrack ? "No GPS data in the selected laps"
                                                           : "No GPS data for this session")
        } else {
            VStack(spacing: 0) {
                controls
                Divider()
                TrackMapView(coords: map.coordinates,
                             distances: map.sectorDistances,
                             channelValues: map.channelValues,
                             colorScale: map.colorScale,
                             lapDistance: map.lapDistance,
                             sectorSplits: model.sectorSplits,
                             runStarts: map.runStarts,
                             runSlots: map.runSlots,
                             runLapNumbers: map.runLapNumbers,
                             colorsByLap: model.trackMapColoring == .laps,
                             markers: model.trackMapMarkers,
                             backdrop: backdrop,
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
            Picker("Colour", selection: Binding(
                get: { model.trackMapColoring },
                set: { model.setTrackMapColoring($0) })) {
                Text("By lap").tag(TrackMapColoring.laps)
                ForEach(model.selection.channels, id: \.self) { channel in
                    Text(channel.name).tag(TrackMapColoring.channel(channel))
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Colour each selected lap on its own, or the line by a channel's value")
            Stepper("Sectors: \(model.sectorSplits)", value: Binding(
                get: { model.sectorSplits },
                set: { model.setSectorSplits($0) }), in: 0...12)
                .fixedSize()
            Picker("Map", selection: $backdropRaw) {
                ForEach(TrackMapBackdrop.allCases, id: \.rawValue) { style in
                    Text(style.title).tag(style.rawValue)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .help("Show satellite imagery under the racing line")
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}
