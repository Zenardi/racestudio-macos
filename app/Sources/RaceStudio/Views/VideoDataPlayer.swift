import SwiftUI
import AppKit
import AVKit
import RaceStudioCore

/// The Video + Data player area (issue 9.12): the footage with the live HUD,
/// the "No footage here" plate, and — while editing — the overlay editor's
/// canvas over the visible video rect.
///
/// It observes the data model itself, so the per-frame HUD updates redraw this
/// view alone, not the whole panel.
struct VideoDataPlayer: View {
    @ObservedObject var data: VideoDataViewModel
    @ObservedObject var editor: OverlayEditorModel
    let player: AVPlayer
    let isEditing: Bool
    let kart: Kart?
    let metadata: SessionMetadata
    @State private var videoRect: CGRect = .zero
    @State private var renderers = HUDRendererCache()
    @State private var voiceOver = NSWorkspace.shared.isVoiceOverEnabled

    var body: some View {
        ZStack(alignment: .topLeading) {
            OverlayHUDView(player: player, renderer: renderer, frame: data.currentFrame,
                           dimsFootage: data.showsNoFootage, onVideoRect: { videoRect = $0 })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L10n.string(.hudAccessibilityLabel))
                .accessibilityValue(accessibilityValue)
            if data.showsNoFootage, videoRect.width > 0 {
                noFootagePlate
                    .position(x: videoRect.midX, y: videoRect.midY)
            }
            if isEditing, videoRect.width > 0, videoRect.height > 0 {
                OverlayEditCanvas(editor: editor,
                                  aspect: OverlayAspect(width: videoRect.width, height: videoRect.height),
                                  availability: availability)
                    .frame(width: videoRect.width, height: videoRect.height)
                    .offset(x: videoRect.minX, y: videoRect.minY)
                KeyNudgeMonitor { dx, dy, large in editor.nudge(dx: dx, dy: dy, large: large) }
                .frame(width: 0, height: 0)
            }
        }
        .frame(minWidth: 280, minHeight: 180)
        .background(Color.black)
        .clipped()
        // VoiceOver turned on while paused gets the sentence at once.
        .onReceive(NSWorkspace.shared.publisher(for: \.isVoiceOverEnabled)) { voiceOver = $0 }
    }

    /// The HUD's renderer: the layout as edited — shown while editing even with
    /// the HUD off, so it can be arranged — or none while the HUD is off.
    private var renderer: OverlayRenderer? {
        var layout = editor.layout
        if isEditing { layout.isEnabled = true }
        guard layout.isEnabled else { return nil }
        return renderers.renderer(layout: layout, revision: data.telemetryRevision, kart: kart) {
            data.makeRenderer(layout: layout, kart: kart, metadata: metadata)
        }
    }

    /// The HUD's sentence for VoiceOver — built only while VoiceOver runs, as
    /// it would otherwise be formatted for every video frame for nobody.
    private var accessibilityValue: String {
        voiceOver ? data.accessibilitySummary(units: editor.layout.units) : ""
    }

    private var availability: [OverlayWidget.ID: WidgetAvailability] {
        data.overlayContext(kart: kart, metadata: metadata).map { editor.layout.availability(for: $0) } ?? [:]
    }

    private var noFootagePlate: some View {
        VStack(spacing: 4) {
            Text(L10n.string(.videoNoFootage)).font(.headline)
            Text(L10n.string(.videoNoFootageDetail)).font(.caption).multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// Keeps the HUD's renderer across the per-frame redraws: a new one only when
/// the layout, the telemetry or the kart (any of its details) changes, so its
/// static layers stay warm.
@MainActor
final class HUDRendererCache {
    /// What a cached renderer was made for.
    private struct Key: Equatable {
        let layout: OverlayLayout
        let revision: Int
        let kart: Kart?
    }

    private var key: Key?
    private var cached: OverlayRenderer?

    func renderer(layout: OverlayLayout, revision: Int, kart: Kart?,
                  make: () -> OverlayRenderer?) -> OverlayRenderer? {
        let wanted = Key(layout: layout, revision: revision, kart: kart)
        if wanted == key, let cached { return cached }
        key = wanted
        cached = make()
        return cached
    }
}

/// The lap and sector at the cursor, under the player — observing the cursor
/// itself so it follows every frame without redrawing the panel.
struct VideoDataReadout: View {
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        Text(review.label(atSessionTime: cursor.timePosition) ?? "—")
            .font(.headline)
            .monospacedDigit()
            .accessibilityLabel(L10n.string(.videoSectionAtCursor))
    }
}

/// The transport under the player: section and lap navigation, play/pause,
/// *Play lap* and its loop.
struct VideoDataTransport: View {
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var controller: VideoReviewController
    let data: VideoDataViewModel
    let cursor: LinkedCursor
    let goToSelection: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VideoDataReadout(review: review, cursor: cursor)
            Spacer()
            Button { review.previousSector(); goToSelection() } label: { Image(systemName: "backward.end") }
                .help(L10n.string(.controlPreviousSector))
            Button(controller.isPlaying ? L10n.string(.controlPause) : L10n.string(.controlPlaySection)) {
                controller.isPlaying ? controller.pause() : controller.playSelection()
            }
            .disabled(review.selectedSpan != nil && !review.canPlaySelection)
            Button { review.nextSector(); goToSelection() } label: { Image(systemName: "forward.end") }
                .help(L10n.string(.controlNextSector))
            Divider().frame(height: 16)
            PlayLapButton(data: data, review: review, controller: controller)
            Toggle(L10n.string(.controlLoopLap), isOn: $review.loops)
                .toggleStyle(.switch)
                .fixedSize()
                .help(L10n.string(.controlLoopLap) + " (⌥⌘L)")
            Divider().frame(height: 16)
            Button(L10n.string(.controlLapMinus)) { review.previousLap(); goToSelection() }
                .help(L10n.string(.controlPreviousLap))
            Button(L10n.string(.controlLapPlus)) { review.nextLap(); goToSelection() }
                .help(L10n.string(.controlNextLap))
        }
        .font(.callout)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// *Play lap*, enabled only when there is a lap the footage holds — observing
/// the data model itself, so the rest of the transport doesn't redraw with it.
private struct PlayLapButton: View {
    @ObservedObject var data: VideoDataViewModel
    /// Observed too: attaching, removing or re-syncing the footage changes
    /// what is on film without the data model publishing.
    @ObservedObject var review: VideoReviewModel
    @ObservedObject var controller: VideoReviewController

    var body: some View {
        Button(L10n.string(.controlPlayLap)) { controller.playLap() }
            .disabled(!data.canPlayLap)
            .help(L10n.string(.controlPlayLap) + " (⌥⌘P)")
    }
}
