import SwiftUI
import RaceStudioCore

/// The Video Review panel's sync controls (issues 9.6 + 9.7): single-section
/// anchoring, two-point (offset + rate) sync, the fine-trim slider with its
/// frame / 0.1 s / 1 s nudges on `,` / `.` (bare, `⇧`, `⌥`), and the status line
/// that says how the footage is aligned and how much of the session it covers.
///
/// Deliberately thin, like the panel it sits in. The step sizes, the key map,
/// every rule about which sync wins, the status text and every message come from
/// `RaceStudioCore` (``VideoReviewModel``, ``OffsetNudge``, ``SyncStatus``,
/// ``CoverageSummary``); this view lays them out and forwards clicks and keys to
/// ``VideoReviewController``, which re-seeks the player.
struct VideoSyncBar: View {
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var controller: VideoReviewController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                anchorControls
                Divider().frame(height: 16)
                trimControls
            }
            Text(review.statusLine())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(review.statusLine())
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
    }

    // MARK: - Anchoring

    private var anchorControls: some View {
        HStack(spacing: 6) {
            Button(L10n.string(.controlAnchorVideoToSection)) { controller.anchorToCurrentFrame() }
                .disabled(review.selectedSpan == nil)
                .help("Align the footage so the section under review starts on the frame on screen")
            anchorButton(.a, title: L10n.string(.controlSetAnchorA))
            anchorButton(.b, title: L10n.string(.controlSetAnchorB))
            Button(L10n.string(.controlTwoPointSync)) { controller.applyTwoPointSync() }
                .disabled(review.anchors.count < AnchorSlot.allCases.count)
                .help(review.anchors.count < AnchorSlot.allCases.count
                      ? TwoPointSyncError.missingAnchor.message()
                      : "Solve the offset and clock rate so both anchors land on their frames")
        }
    }

    /// "Set Anchor A/B": pins the frame on screen to the reviewed lap's start. A
    /// set anchor shows a check and speaks the lap it was set on.
    private func anchorButton(_ slot: AnchorSlot, title: String) -> some View {
        let anchor = review.anchors[slot]
        return Button { controller.setAnchor(slot) } label: {
            Label(title, systemImage: anchor == nil ? "circle" : "checkmark.circle.fill")
        }
        .disabled(review.selectedSpan == nil)
        .help(anchor?.label() ?? "Scrub to the frame where the selected lap starts, then set this anchor")
        .accessibilityValue(anchor?.label() ?? "")
    }

    // MARK: - Trimming

    private var trimControls: some View {
        HStack(spacing: 4) {
            ForEach([OffsetNudge.secondBackward, .tenthBackward, .frameBackward], id: \.self, content: nudgeButton)
            Slider(value: offsetBinding, in: review.trimRange) {
                Text(L10n.string(.controlVideoOffset))
            }
            .frame(minWidth: 120, maxWidth: 200)
            .disabled(!review.hasVideo)
            ForEach([OffsetNudge.frameForward, .tenthForward, .secondForward], id: \.self, content: nudgeButton)
            Text(readout)
                .monospacedDigit()
                .frame(minWidth: 84, alignment: .trailing)
                .accessibilityLabel(L10n.string(.controlVideoOffset))
                .accessibilityValue(readout)
        }
    }

    /// One nudge, bound to its key: `,` / `.` bare for a frame, with `⇧` for
    /// 0.1 s, with `⌥` for 1 s.
    private func nudgeButton(_ nudge: OffsetNudge) -> some View {
        Button { controller.nudge(nudge) } label: { nudgeSymbol(nudge) }
            .keyboardShortcut(KeyEquivalent(nudge.key), modifiers: nudge.modifier.eventModifiers)
            .disabled(!review.hasVideo)
            .help(nudge.label())
            .accessibilityLabel(nudge.label())
    }

    private func nudgeSymbol(_ nudge: OffsetNudge) -> some View {
        switch nudge.step {
        case .frames(let frames):
            return AnyView(Image(systemName: frames < 0 ? "backward.frame" : "forward.frame"))
        case .seconds(let seconds):
            let magnitude = L10n.formattedNumber(abs(seconds), fractionDigits: abs(seconds) < 1 ? 1 : 0)
            return AnyView(Text((seconds < 0 ? "−" : "+") + magnitude).monospacedDigit())
        }
    }

    /// Edits the offset through the controller, which re-projects and re-seeks so
    /// a drag has no accumulated drift.
    private var offsetBinding: Binding<Double> {
        Binding(get: { review.sync.offset }, set: { controller.setOffset($0) })
    }

    /// The offset to the millisecond — a 29.97 fps frame step reads as 0.033 s —
    /// plus the solved clock rate once a two-point sync set one.
    private var readout: String {
        let offset = String(format: "%+.3f s", review.sync.offset)
        return review.sync.rate == 1 ? offset : offset + String(format: " ×%.6f", review.sync.rate)
    }

    // MARK: - Messages

    /// A refused two-point sync explains itself first; otherwise a file date that
    /// cannot be right says so until the footage is aligned some other way.
    private var notice: String? {
        if let error = controller.twoPointError { return error.message() }
        guard review.status == .notSynced else { return nil }
        return controller.autoOffsetOutcome?.message()
    }
}

private extension NudgeModifier {
    /// The SwiftUI modifier set a nudge's key is pressed with.
    var eventModifiers: EventModifiers {
        switch self {
        case .none: return []
        case .shift: return .shift
        case .option: return .option
        }
    }
}
