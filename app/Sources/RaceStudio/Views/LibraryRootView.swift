import SwiftUI
import RaceStudioCore

/// The main window's root (issue 8.14). It shows the session library browser on
/// launch — so RaceStudio opens into a real RS3-style UI, not a file-open panel —
/// and switches to the analysis view once a session is opened, with a "Library"
/// button to return.
///
/// The switch is driven by the shared ``SessionStore`` state: `.idle` shows the
/// browser; loading/loaded/failed show the analysis ``ContentView`` (which owns
/// the progress bar, loaded workspace, and error alert). ``SessionStore/reset()``
/// closes the session and returns to the browser.
struct LibraryRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore

    var body: some View {
        Group {
            if case .idle = store.state {
                LibraryBrowserView(
                    library: model.library,
                    onOpen: { model.openFromLibrary($0) },
                    onImport: { model.presentOpenPanel() })
            } else {
                ContentView()
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { store.reset() } label: {
                                Label("Library", systemImage: "chevron.backward")
                            }
                            .help("Close this session and return to the library")
                        }
                    }
            }
        }
    }
}
