import SwiftUI
import RaceStudioCore

/// The StoryBoard lap strip (issue 8.13): a horizontal row of the shown laps with
/// the reference lap highlighted, controls to re-order them, mark the reference, and
/// hide (deselect) a lap. Deliberately **thin** — the cards, order, and reference
/// flag come from `RaceStudioCore.StoryBoardModel`; every action forwards straight
/// into `AnalysisWindowModel`, whose reorder/reference changes every panel reflects.
struct StoryBoardView: View {
    let board: StoryBoardModel
    let onSetReference: (LapID) -> Void
    let onHide: (LapID) -> Void
    let onMove: (Int, Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "film").foregroundColor(.secondary)
                .help("StoryBoard — the laps shown across every panel")
            if board.cards.isEmpty {
                Text("Select laps to build the StoryBoard")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(board.cards.enumerated()), id: \.element.id) { index, card in
                            cardView(card, index: index)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private func cardView(_ card: StoryBoardCard, index: Int) -> some View {
        HStack(spacing: 4) {
            Button { onMove(index, index - 1) } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.plain).disabled(index == 0).help("Move earlier")

            Button { onSetReference(card.lap) } label: {
                HStack(spacing: 4) {
                    Text(card.label).font(.caption.bold())
                    if card.isReference {
                        Text("REF").font(.caption2).foregroundColor(.white)
                            .padding(.horizontal, 4).background(Color.accentColor).cornerRadius(3)
                    }
                }
            }
            .buttonStyle(.plain)
            .help(card.isReference ? "Reference lap" : "Set as reference lap")

            Button { onMove(index, index + 1) } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.plain).disabled(index == board.cards.count - 1).help("Move later")

            Button { onHide(card.lap) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundColor(.secondary).help("Hide this lap")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(card.isReference ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.1))
        .cornerRadius(6)
        .overlay(RoundedRectangle(cornerRadius: 6)
            .strokeBorder(card.isReference ? Color.accentColor : .clear, lineWidth: 1))
    }
}
