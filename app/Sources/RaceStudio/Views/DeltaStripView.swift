import SwiftUI
import RaceStudioCore

/// The gain/loss strip under the overlay plot (issue 4.2): a horizontal band
/// along distance, colored green where the target lap is ahead (`dt < 0`) and
/// red where it is behind, with the cursor readout on top.
///
/// Thin: it maps distance→pixel with `RaceStudioCore.LinearScale` and takes the
/// already-computed `DeltaSample`s / `DeltaReadout`; it holds no delta math.
struct DeltaStripView: View {
    let strip: [DeltaSample]
    let readout: DeltaReadout?

    var body: some View {
        Canvas { context, size in
            guard let first = strip.first, let last = strip.last,
                  last.distance > first.distance else { return }
            let xScale = LinearScale(domain: first.distance...last.distance, range: 0...max(size.width, 1))
            for i in 1..<strip.count {
                let x0 = xScale.map(strip[i - 1].distance)
                let x1 = xScale.map(strip[i].distance)
                let dt = strip[i].dt
                let band = Path(CGRect(x: x0, y: 0, width: max(x1 - x0, 1), height: size.height))
                context.fill(band, with: .color(color(for: dt)))
            }
        }
        .frame(height: 18)
        .overlay(alignment: .leading) { readoutLabel }
        .accessibilityLabel("Delta-t gain/loss strip")
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
    /// tie; opacity scales with the magnitude of the gap.
    private func color(for dt: Double) -> Color {
        let base: Color = dt < 0 ? .green : (dt > 0 ? .red : .gray)
        return base.opacity(min(1, abs(dt) / 2 + 0.25))
    }
}
