import SwiftUI
import RaceStudioCore

/// What the focused Video + Data panel offers the **Video** menu (issue 9.12) —
/// published with `focusedSceneValue` while the panel is on screen.
struct VideoDataActions {
    var playLap: () -> Void
    var toggleLoop: () -> Void
    var toggleHUD: () -> Void
    var toggleEditing: () -> Void
    var loops: Bool
    var showsHUD: Bool
    var isEditing: Bool
}

private struct VideoDataActionsKey: FocusedValueKey {
    typealias Value = VideoDataActions
}

extension FocusedValues {
    /// The Video + Data panel's menu actions, while it is on screen.
    var videoDataActions: VideoDataActions? {
        get { self[VideoDataActionsKey.self] }
        set { self[VideoDataActionsKey.self] = newValue }
    }
}

/// The **Video** menu (issue 9.12): the Video + Data panel's commands with
/// their keyboard shortcuts, so they are discoverable and documented in the
/// menu bar. Disabled while no Video + Data panel is on screen. Undo and Redo
/// of overlay edits are the Edit menu's own (⌘Z / ⇧⌘Z).
struct VideoDataCommands: Commands {
    @FocusedValue(\.videoDataActions) private var actions

    var body: some Commands {
        CommandMenu(L10n.string(.menuVideo)) {
            Button(L10n.string(.controlPlayLap)) { actions?.playLap() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(actions == nil)
            Toggle(L10n.string(.controlLoopLap), isOn: Binding(
                get: { actions?.loops ?? false }, set: { _ in actions?.toggleLoop() }))
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(actions == nil)
            Divider()
            Toggle(L10n.string(.controlShowHUD), isOn: Binding(
                get: { actions?.showsHUD ?? false }, set: { _ in actions?.toggleHUD() }))
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(actions == nil)
            Toggle(L10n.string(.controlEditOverlay), isOn: Binding(
                get: { actions?.isEditing ?? false }, set: { _ in actions?.toggleEditing() }))
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
    }
}
