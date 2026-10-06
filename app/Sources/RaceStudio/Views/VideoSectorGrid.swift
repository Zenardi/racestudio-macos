import SwiftUI
import RaceStudioCore

// MARK: - Lap × sector grid

/// The review grid: one row per lap, one cell per split, showing the time spent
/// in that section. Clicking a cell sends the cursor **and** the playhead there;
/// clicking the lap label reviews the whole lap.
///
/// The fastest time in each column is marked, and a section the footage does not
/// cover is dimmed — both read straight off ``VideoReviewModel``.
struct VideoSectorGrid: View {
    @ObservedObject var review: VideoReviewModel
    let onSelectLap: (LapID) -> Void
    let onSelectSector: (SectorSpan) -> Void

    var body: some View {
        if review.timeline.isEmpty {
            ContentUnavailableHint(text: L10n.string(.videoNoLaps), symbol: "film")
        } else {
            ScrollView([.horizontal, .vertical]) {
                Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 4) {
                    ForEach(review.timeline.laps) { lap in
                        GridRow {
                            Button(L10n.format(.videoLapLabel, String(lap.lap.index + 1))) { onSelectLap(lap.lap) }
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
            Text(LapTimeFormatter.sectorString(from: sector.duration))
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
        let name = L10n.format(.videoLapLabel, String(sector.lap.index + 1)) + " · \(sector.name)"
        return review.sync.coverage(of: sector.span) == .none
            ? "\(name) — outside the attached footage"
            : "\(name) — review this section"
    }
}
