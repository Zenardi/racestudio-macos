import SwiftUI
import RaceStudioCore

/// The gain/loss strip under the overlay plot (issue 4.2): a horizontal band
/// along distance, colored green where the target lap is ahead (`dt < 0`) and
/// red where it is behind. Scrubbing it drives the cursor readout.
///
/// Thin: it maps distance↔pixel with `RaceStudioCore.LinearScale` and takes the
/// already-computed `DeltaSample`s / `DeltaReadout`; it holds no delta math. The
/// local scrub cursor is replaced by the shared workspace cursor in 4.7.
struct DeltaStripView: View {
    let strip: [DeltaSample]
    let readout: DeltaReadout?
    @Binding var cursorDistance: Double?

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard let scale = xScale(width: size.width) else { return }
                for i in 1..<strip.count {
                    // Clamp so a non-monotonic/out-of-range sample cannot draw
                    // a band outside the canvas.
                    let x0 = scale.mapClamped(strip[i - 1].distance)
                    let x1 = scale.mapClamped(strip[i].distance)
                    let band = Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height))
                    context.fill(band, with: .color(color(for: strip[i].dt)))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    if let scale = xScale(width: geometry.size.width) {
                        cursorDistance = scale.invertClamped(value.location.x)
                    }
                }
            )
        }
        .frame(height: 18)
        .overlay(alignment: .leading) { readoutLabel }
        .accessibilityLabel(L10n.string(.chartDeltaStrip))
    }

    /// The distance→pixel scale for the strip, or `nil` when it has no width.
    private func xScale(width: CGFloat) -> LinearScale? {
        guard let first = strip.first, let last = strip.last,
              last.distance > first.distance, width > 0 else { return nil }
        return LinearScale(domain: first.distance...last.distance, range: 0...width)
    }

    @ViewBuilder
    private var readoutLabel: some View {
        if let readout {
            Text(String(format: "\u{0394}t %+.3f s", readout.dt))
                .font(.caption2.monospacedDigit())
                .padding(.horizontal, 4)
                .background(.thinMaterial)
                .padding(.leading, 4)
        }
    }

    /// Green when the target is ahead (`dt < 0`), red when behind, neutral at a
    /// tie; opacity scales with the size of the gap. Non-finite data reads as a
    /// faint neutral band rather than a confident tie.
    private func color(for dt: Double) -> Color {
        guard dt.isFinite else { return .gray.opacity(0.15) }
        let base: Color = dt < 0 ? .green : (dt > 0 ? .red : .gray)
        return base.opacity(min(1, abs(dt) / 2 + 0.25))
    }
}
