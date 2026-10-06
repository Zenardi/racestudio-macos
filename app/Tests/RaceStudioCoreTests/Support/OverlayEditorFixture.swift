import CoreGraphics
import Foundation
@testable import RaceStudioCore

/// The small hand-placed layout the overlay-editor suites share (issue 9.12):
/// speed bottom-left, a G-ball over it one level up, the map bottom-right and
/// the pedals beside the speed — all inside the 3% safe area, in the 16:9
/// reference frame.
enum OverlayEditorFixture {

    static let speedFrame = NormalizedRect(x: 0.03, y: 0.82, width: 0.14, height: 0.15)
    static let gForceFrame = NormalizedRect(x: 0.10, y: 0.70, width: 0.20, height: 0.20)
    static let mapFrame = NormalizedRect(x: 0.79, y: 0.65, width: 0.18, height: 0.32)
    static let pedalsFrame = NormalizedRect(x: 0.19, y: 0.82, width: 0.06, height: 0.15)

    static func layout(isEnabled: Bool = true) -> OverlayLayout {
        OverlayLayout(name: "Edited", widgets: [
            OverlayWidget(kind: .speed, frame: speedFrame, anchor: .bottomLeading),
            OverlayWidget(kind: .gForce, frame: gForceFrame, anchor: .bottomLeading, z: 1),
            OverlayWidget(kind: .trackMap, frame: mapFrame, anchor: .bottomTrailing),
            OverlayWidget(kind: .pedals, frame: pedalsFrame, anchor: .bottomLeading)
        ], units: .imperial, isEnabled: isEnabled)
    }

    /// An editor over ``layout(isEnabled:)`` with `id` selected.
    @MainActor
    static func editor(selecting id: OverlayWidget.ID? = nil) -> OverlayEditorModel {
        let editor = OverlayEditorModel(layout: layout())
        editor.select(id)
        return editor
    }

    /// The frame of widget `id` in `editor`'s layout.
    @MainActor
    static func frame(_ id: OverlayWidget.ID, in editor: OverlayEditorModel) -> NormalizedRect? {
        editor.layout.widgets.first { $0.id == id }?.frame
    }
}
