import SwiftUI
import RaceStudioCore

/// The Video Review panel's sync controls (issues 9.6 – 9.8): single-section
/// anchoring and two-point (offset + rate) sync on one row; auto-sync from
/// engine sound, with its progress, on its own row; the fine-trim slider with
/// its frame / 0.1 s / 1 s nudges on `,` / `.` (bare, `⇧`, `⌥`) on the next;
/// then the status line that says how the footage is aligned and how much of the
/// session it covers.
///
/// Deliberately thin, like the panel it sits in. The step sizes, the key map,
/// every rule about which sync wins, the readout, the status text and every
/// message come from `RaceStudioCore` (``VideoReviewModel``, ``OffsetNudge``,
/// ``SyncStatus``, ``CoverageSummary``); this view lays them out and forwards
/// clicks and keys to ``VideoReviewController``, which re-seeks the player.
struct VideoSyncBar: View {
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var controller: VideoReviewController
    /// The session the engine sound is matched against (issue 9.8).
    let analysis: AnalysisSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            anchorControls
            AutoSyncControl(review: review, controller: controller, analysis: analysis)
            trimControls
            Text(review.statusLine())
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let notice {
                Label(notice, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }
        }
    }

    // MARK: - Anchoring

    /// Anchoring needs footage to pick a frame from and a section to pin it to.
    private var canAnchor: Bool { review.hasVideo && review.selectedSpan != nil }

    private var hasBothAnchors: Bool { review.anchors.count == AnchorSlot.allCases.count }

    private var anchorControls: some View {
        HStack(spacing: 6) {
            Button(L10n.string(.controlAnchorVideoToSection)) { controller.anchorToCurrentFrame() }
                .disabled(!canAnchor)
                .help(L10n.string(.videoHelpAnchorToSection))
            Divider().frame(height: 16)
            anchorButton(.a, title: L10n.string(.controlSetAnchorA))
            anchorButton(.b, title: L10n.string(.controlSetAnchorB))
            Button(L10n.string(.controlTwoPointSync)) { controller.applyTwoPointSync() }
                .disabled(!review.hasVideo || !hasBothAnchors)
                .help(hasBothAnchors ? L10n.string(.videoHelpTwoPointSync) : TwoPointSyncError.missingAnchor.message())
        }
    }

    /// "Set Anchor A/B": pins the frame on screen to the reviewed lap's start. A
    /// set anchor shows a check and speaks the lap it was set on.
    private func anchorButton(_ slot: AnchorSlot, title: String) -> some View {
        let anchor = review.anchors[slot]
        return Button { controller.setAnchor(slot) } label: {
            Label(title, systemImage: anchor == nil ? "circle" : "checkmark.circle.fill")
        }
        .disabled(!canAnchor)
        .help(anchor?.label() ?? L10n.string(.videoHelpSetAnchor))
        .accessibilityValue(anchor?.label() ?? "")
    }

    // MARK: - Trimming

    private var trimControls: some View {
        HStack(spacing: 4) {
            ForEach([OffsetNudge.secondBackward, .tenthBackward, .frameBackward], id: \.self, content: nudgeButton)
            Slider(value: offsetBinding, in: review.trimRange) {
                Text(L10n.string(.controlVideoOffset))
            }
            .frame(minWidth: 120, maxWidth: 240)
            .disabled(!review.hasVideo)
            // The slider's range re-centres on the offset, so its percentage says
            // nothing; speak the offset itself.
            .accessibilityValue(review.offsetReadout())
            ForEach([OffsetNudge.frameForward, .tenthForward, .secondForward], id: \.self, content: nudgeButton)
            Text(review.offsetReadout())
                .monospacedDigit()
                .frame(minWidth: 84, alignment: .trailing)
                .accessibilityLabel(L10n.string(.controlVideoOffset))
                .accessibilityValue(review.offsetReadout())
        }
    }

    /// One nudge, bound to its key: `,` / `.` bare for a frame, with `⇧` for
    /// 0.1 s, with `⌥` for 1 s. The tooltip names the shortcut.
    private func nudgeButton(_ nudge: OffsetNudge) -> some View {
        Button { controller.nudge(nudge) } label: { nudgeSymbol(nudge) }
            .keyboardShortcut(KeyEquivalent(nudge.key), modifiers: nudge.modifier.eventModifiers)
            .disabled(!review.hasVideo)
            .help("\(nudge.label()) (\(nudge.shortcut))")
            .accessibilityLabel(nudge.label())
    }

    @ViewBuilder
    private func nudgeSymbol(_ nudge: OffsetNudge) -> some View {
        switch nudge.step {
        case .frames(let frames):
            Image(systemName: frames < 0 ? "backward.frame" : "forward.frame")
        case .seconds(let seconds):
            Text((seconds < 0 ? "−" : "+")
                 + L10n.formattedNumber(abs(seconds), fractionDigits: abs(seconds) < 1 ? 1 : 0))
                .monospacedDigit()
        }
    }

    /// Edits the offset through the controller, which re-projects and re-seeks so
    /// a drag has no accumulated drift.
    private var offsetBinding: Binding<Double> {
        Binding(get: { review.sync.offset }, set: { controller.setOffset($0) })
    }

    // MARK: - Messages

    /// Footage that could not be opened says so first; then a refused two-point
    /// sync explains itself; otherwise a file date that cannot be right says so
    /// until the footage is aligned some other way.
    private var notice: String? {
        if let failure = controller.loadFailure { return failure }
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
