import SwiftUI
import RaceStudioCore

/// *Auto-sync from engine sound* (issue 9.8): the button — always there, so
/// focus and the result popover keep their anchor — with the run's progress and
/// Cancel beside it while it decodes and matches, and the result popover with
/// the proposed offset, a confidence bar and Apply / Dismiss.
///
/// Deliberately thin. Whether the button can run and why not
/// (``AudioSyncAvailability``), the progress text (``AudioSyncPhase``), the
/// result's wording and whether it may be applied (``AudioSyncProposal``) and
/// the run itself (``VideoReviewModel/startAutoSync(_:searchRange:)``) all live in
/// `RaceStudioCore`; ``VideoReviewController`` starts, cancels and applies.
struct AutoSyncControl: View {
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var controller: VideoReviewController
    let analysis: AnalysisSession?

    var body: some View {
        HStack(spacing: 8) {
            button
            if case .running(let phase) = review.autoSyncState {
                progress(phase)
            }
        }
    }

    // MARK: - Button

    private var availability: AudioSyncAvailability {
        .evaluate(hasVideo: review.hasVideo, hasAudioTrack: controller.hasAudioTrack,
                  rpmChannel: controller.rpmChannels.channelName(in: analysis),
                  canEstimate: analysis?.canEstimateAudioSync ?? false)
    }

    private var button: some View {
        Button { controller.startAutoSync(analysis: analysis) } label: {
            Label(L10n.string(.controlAutoSyncEngineSound), systemImage: "waveform")
        }
        .disabled(!availability.isAvailable || review.autoSyncState.isRunning)
        .help(availability.help())
        .popover(isPresented: resultShown, arrowEdge: .bottom) { result }
    }

    /// The popover is up while a finished run's proposal waits; closing it
    /// dismisses the proposal without applying it.
    private var resultShown: Binding<Bool> {
        Binding(get: { review.autoSyncState.proposal != nil },
                set: { if !$0 { controller.dismissAutoSync() } })
    }

    // MARK: - Progress

    /// The bar and its line read as one element; Cancel stays its own button.
    /// Escape is left to the window — the panel shares it with other controls.
    private func progress(_ phase: AudioSyncPhase) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                if let fraction = phase.fraction {
                    ProgressView(value: fraction).frame(width: 80)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text(phase.label())
                    .font(.caption)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            Button(L10n.string(.controlCancelAutoSync)) { controller.cancelAutoSync() }
        }
    }

    // MARK: - Result

    @ViewBuilder
    private var result: some View {
        if let proposal = review.autoSyncState.proposal {
            VStack(alignment: .leading, spacing: 8) {
                Label(proposal.headline(), systemImage: proposal.isApplicable ? "waveform" : "questionmark.circle")
                    .font(.headline)
                if let confidence = proposal.confidence {
                    ProgressView(value: confidence)
                        .tint(proposal.isApplicable ? .green : .orange)
                        .accessibilityLabel(proposal.confidenceText() ?? "")
                }
                if let detail = proposal.detail() {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button(L10n.string(.controlDismissAutoSync)) { controller.dismissAutoSync() }
                    if proposal.isApplicable {
                        Button(L10n.string(.controlApplyAutoSync)) { controller.applyAutoSync() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(14)
            .frame(width: 320)
        }
    }
}
