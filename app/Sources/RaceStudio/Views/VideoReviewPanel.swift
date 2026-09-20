import SwiftUI
import AVKit
import AppKit
import UniformTypeIdentifiers
import RaceStudioCore

/// The analysis window's **Video Review** panel (issue 9.6): the attached session
/// video beside a lap × sector grid, so footage can be reviewed section by
/// section and the same corner watched lap after lap.
///
/// Deliberately thin, as every panel in this window is. The lap/sector windows
/// (``LapSectorTimeline``), the alignment (``VideoSyncModel``) and the selection,
/// navigation and end-of-section rules (``VideoReviewModel``) all live in
/// `RaceStudioCore`; this view lays the regions out, forwards clicks, and lets
/// ``VideoReviewController`` apply the decisions to AVKit.
struct VideoReviewPanel: View {
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var splitReport: SplitReportModel
    @ObservedObject var cursor: LinkedCursor
    @ObservedObject var controller: VideoReviewController
    let analysis: AnalysisSession?

    /// The whole-session base grid, read once per base resolution (as the 8.11
    /// panel reads it) and re-cut into absolute windows by the timeline.
    @State private var segments: [LapSegments] = []
    @State private var loadedBase: Int?

    var body: some View {
        Group {
            if model.session.laps.isEmpty {
                ContentUnavailableHint(text: "This session has no laps to review", symbol: "film")
            } else if controller.attachment == nil {
                attachPrompt
            } else {
                reviewLayout
            }
        }
        .onAppear {
            controller.start(driving: cursor)
            rebuildTimeline()
        }
        .onChange(of: splitReport.layout) { _ in rebuildTimeline() }
        .onChange(of: cursor.timePosition) { controller.seekFromCursor(to: $0) }
    }

    // MARK: - States

    /// Nothing attached yet: a designed prompt rather than an empty rectangle.
    private var attachPrompt: some View {
        BrandStateView(
            symbol: "film",
            title: L10n.string(.featureVideoReview),
            message: controller.loadFailure
                ?? "Attach the onboard video for this session to review it lap by lap and sector by sector.",
            actionLabel: L10n.string(.controlImportVideo),
            action: pickVideo)
    }

    /// The attached state: player on the left, grid and transport on the right.
    private var reviewLayout: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HSplitView {
                VStack(spacing: 0) {
                    VideoPlayer(player: controller.player)
                        .frame(minWidth: 280, minHeight: 180)
                        .accessibilityLabel(L10n.string(.featureVideoReview))
                    Divider()
                    transport
                }
                VideoSectorGrid(review: review, onSelectLap: selectLap, onSelectSector: selectSector)
                    .frame(minWidth: 280)
            }
        }
    }

    // MARK: - Header (file + alignment)

    private var header: some View {
        HStack(spacing: 12) {
            Label(controller.attachment?.displayName ?? "", systemImage: "film")
                .lineLimit(1)
            Button(L10n.string(.controlAnchorVideoToSection)) { controller.anchorToCurrentFrame() }
                .disabled(review.selectedSpan == nil)
                .help("Align the footage so the section under review starts on the frame on screen")
            Slider(value: offsetBinding, in: review.trimRange) {
                Text(L10n.string(.controlVideoOffset))
            }
            .frame(maxWidth: 200)
            .disabled(!review.hasVideo)
            Text(String(format: "%+.2f s", review.sync.offset))
                .monospacedDigit()
                .frame(width: 76, alignment: .trailing)
            Spacer()
            Button(L10n.string(.controlImportVideo), action: pickVideo)
            Button(L10n.string(.controlRemoveVideo)) { controller.removeVideo() }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    /// Edits the offset through the controller, which re-projects and re-seeks so
    /// a drag has no accumulated drift.
    private var offsetBinding: Binding<Double> {
        Binding(get: { review.sync.offset }, set: { controller.setOffset($0) })
    }

    // MARK: - Transport

    private var transport: some View {
        VStack(spacing: 6) {
            Text(review.label(atSessionTime: cursor.timePosition) ?? "—")
                .font(.headline)
                .monospacedDigit()
                .accessibilityLabel("Section at the cursor")
            HStack(spacing: 8) {
                Button { review.previousSector(); controller.goToSelection() }
                    label: { Image(systemName: "backward.end") }
                    .help("Previous sector")
                Button(playLabel) { controller.isPlaying ? controller.pause() : controller.playSelection() }
                    .disabled(review.selectedSpan != nil && !review.canPlaySelection)
                Button { review.nextSector(); controller.goToSelection() }
                    label: { Image(systemName: "forward.end") }
                    .help("Next sector")
                Divider().frame(height: 16)
                Button("Lap −") { review.previousLap(); controller.goToSelection() }
                    .help("Same section, previous lap")
                Button("Lap +") { review.nextLap(); controller.goToSelection() }
                    .help("Same section, next lap")
                Toggle(L10n.string(.controlLoopSection), isOn: $review.loops)
                    .toggleStyle(.switch)
                    .fixedSize()
            }
            .font(.callout)
            if review.selectedSpan != nil, !review.canPlaySelection {
                Text("This section is outside the attached footage.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
    }

    private var playLabel: String {
        controller.isPlaying ? "Pause" : L10n.string(.controlPlaySection)
    }

    // MARK: - Actions

    private func selectLap(_ lap: LapID) {
        review.select(lap: lap)
        controller.goToSelection()
    }

    private func selectSector(_ sector: SectorSpan) {
        review.select(lap: sector.lap, splitID: sector.splitID)
        controller.goToSelection()
    }

    private func pickVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await controller.attach(url, sessionStartEpoch: Double(model.session.metadata.datetimeUtc)) }
    }

    /// Re-cut the lap/sector windows whenever the split layout changes (the 8.11
    /// split-count control) — the grid and the Split Times table stay in step
    /// because both are derived from the same base grid.
    private func rebuildTimeline() {
        if loadedBase != splitReport.layout.base {
            segments = analysis?.segmentTimes(splits: splitReport.layout.base) ?? []
            loadedBase = splitReport.layout.base
        }
        review.update(timeline: LapSectorTimeline.make(
            laps: model.session.laps, segments: segments, layout: splitReport.layout))
    }
}

// MARK: - Lap × sector grid

/// The review grid: one row per lap, one cell per split, showing the time spent
/// in that section. Clicking a cell sends the cursor **and** the playhead there;
/// clicking the lap label reviews the whole lap.
///
/// The fastest time in each column is marked, and a section the footage does not
/// cover is dimmed — both read straight off ``VideoReviewModel``.
private struct VideoSectorGrid: View {
    @ObservedObject var review: VideoReviewModel
    let onSelectLap: (LapID) -> Void
    let onSelectSector: (SectorSpan) -> Void

    var body: some View {
        if review.timeline.isEmpty {
            ContentUnavailableHint(text: "No laps to review", symbol: "film")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(review.timeline.laps) { lap in
                        GridRow {
                            Button("Lap \(lap.lap.index + 1)") { onSelectLap(lap.lap) }
                                .buttonStyle(.plain)
                                .fontWeight(review.selectedLap == lap.lap ? .bold : .regular)
                            ForEach(lap.sectors) { sector in
                                cell(sector)
                            }
                        }
                    }
                }
                .font(.callout.monospacedDigit())
                .padding(10)
            }
        }
    }

    private func cell(_ sector: SectorSpan) -> some View {
        Button { onSelectSector(sector) } label: {
            Text(Self.time(sector.duration))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(background(sector))
                .cornerRadius(4)
                .opacity(review.sync.coverage(of: sector.span) == .none ? 0.35 : 1)
        }
        .buttonStyle(.plain)
        .help(helpText(sector))
    }

    private func background(_ sector: SectorSpan) -> Color {
        isSelected(sector) ? Color.accentColor.opacity(0.25)
            : isFastest(sector) ? Color.green.opacity(0.18) : .clear
    }

    private func isSelected(_ sector: SectorSpan) -> Bool {
        review.selectedLap == sector.lap && review.selectedSplitID == sector.splitID
    }

    /// Whether this is the fastest time any lap spent in this split — the
    /// column's best, the section worth watching.
    private func isFastest(_ sector: SectorSpan) -> Bool {
        let column = review.timeline.sectors
            .filter { $0.splitID == sector.splitID && $0.duration > 0 }
        guard let best = column.map(\.duration).min(), sector.duration > 0 else { return false }
        return sector.duration == best
    }

    private func helpText(_ sector: SectorSpan) -> String {
        let name = "Lap \(sector.lap.index + 1) · \(sector.name)"
        return review.sync.coverage(of: sector.span) == .none
            ? "\(name) — outside the attached footage"
            : "\(name) — review this section"
    }

    /// `m:ss.mmm`, matching the split-times table.
    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "—" }
        let minutes = Int(seconds) / 60
        let rest = seconds - Double(minutes * 60)
        return minutes > 0 ? String(format: "%d:%06.3f", minutes, rest) : String(format: "%.3f", rest)
    }
}
