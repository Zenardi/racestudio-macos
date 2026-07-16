import SwiftUI
import UniformTypeIdentifiers
import RaceStudioCore

/// Root view for a document window.
///
/// It renders the session summary (issue 2.4) once a file is loaded, and
/// otherwise a drop prompt. Drag-and-drop of `.xrk`/`.xrz` (issue 2.3) is
/// forwarded to the shared `AppModel`; all formatting/validation lives in
/// `RaceStudioCore`, so this view carries no logic of its own.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.xrk, .xrz], isTargeted: nil) { providers in
                model.receiveDrop(providers)
            }
    }

    @ViewBuilder
    private var content: some View {
        if let session = store.viewModel?.session {
            SessionSummaryView(viewModel: SessionSummaryViewModel(session: session))
        } else {
            Text("Drop a .xrk or .xrz file, or use File ▸ Open")
                .foregroundColor(.secondary)
                .padding()
        }
    }
}
