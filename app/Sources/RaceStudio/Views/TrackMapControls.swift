import SwiftUI
import RaceStudioCore

/// The track map's zoom / pan controls: zoom in, zoom out, back to the fit, and a
/// pad of arrows that move the view. Every change goes through
/// `RaceStudioCore.MapViewport`, where the zoom limits and pan bounds are tested.
struct TrackMapControls: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @Binding var viewport: MapViewport
    /// The map view's size, which scales the pan steps and bounds.
    let size: CGSize

    var body: some View {
        HStack(alignment: .bottom, spacing: 6) {
            panPad
            VStack(spacing: 2) {
                button("plus.magnifyingglass", help: "Zoom in (or scroll / pinch)", disabled: !viewport.canZoomIn) {
                    viewport.zoomIn(in: size)
                }
                button("minus.magnifyingglass", help: "Zoom out (or scroll / pinch)",
                       disabled: !viewport.canZoomOut) {
                    viewport.zoomOut(in: size)
                }
                button("arrow.up.left.and.arrow.down.right", help: "Fit the laps to the view",
                       disabled: viewport.isFitted) {
                    viewport.reset()
                }
            }
        }
        .padding(4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
    }

    /// Arrows that move the view; a middle-button or ⌥-drag on the map does the
    /// same continuously.
    private var panPad: some View {
        VStack(spacing: 2) {
            arrow(.up)
            HStack(spacing: 2) {
                arrow(.left)
                arrow(.right)
            }
            arrow(.down)
        }
    }

    private func arrow(_ direction: MapViewport.PanDirection) -> some View {
        let symbol: String
        let name: String
        switch direction {
        case .up: symbol = "chevron.up"; name = "up"
        case .down: symbol = "chevron.down"; name = "down"
        case .left: symbol = "chevron.left"; name = "left"
        case .right: symbol = "chevron.right"; name = "right"
        }
        return button(symbol, help: "Move the map \(name) (or drag with the wheel pressed)", disabled: false) {
            viewport.panStep(direction, in: size)
        }
    }

    private func button(_ symbol: String, help: String, disabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(theme.palette.textPrimary.color(scheme))
        .disabled(disabled)
        .help(help)
        .accessibilityLabel(help)
    }
}
