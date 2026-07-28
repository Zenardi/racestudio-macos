import SwiftUI
import RaceStudioCore

/// The main window's root (issues 8.14 / Home dashboard). On launch it shows the
/// ``HomeView`` dashboard — so RaceStudio opens into a real UI with at-a-glance
/// stats and getting-started tips, not a file-open panel — with **Browse Library**
/// one click away, and switches to the analysis view once a session is opened.
///
/// The switch is driven by the shared ``SessionStore`` state: `.idle` shows the
/// chosen landing (Home or the library browser); loading/loaded/failed show the
/// analysis ``ContentView`` (which owns the progress bar, loaded workspace, and
/// error alert). A "Home" button resets the session and returns to the dashboard.
struct LibraryRootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    /// Which surface the idle window shows: the Home dashboard (the startup
    /// default) or the full library browser. Only affects the idle state.
    @State private var landing: Landing = .home

    private enum Landing { case home, library }

    var body: some View {
        Group {
            if case .idle = store.state {
                idleLanding
            } else {
                ContentView()
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { landing = .home; store.reset() } label: {
                                Label("Home", systemImage: "chevron.backward")
                            }
                            .help("Close this session and return to the Home dashboard")
                        }
                    }
            }
        }
    }

    /// The startup landing: the Home dashboard by default (with getting-started and
    /// how-to-analyze tips), or the library browser once the user chooses to browse.
    @ViewBuilder private var idleLanding: some View {
        switch landing {
        case .home:
            HomeView(library: model.library,
                     onImport: { model.presentOpenPanel() },
                     onBrowseLibrary: { landing = .library },
                     onOpen: { model.openFromLibrary($0) })
        case .library:
            LibraryBrowserView(
                library: model.library,
                onOpen: { model.openFromLibrary($0) },
                onImport: { model.presentOpenPanel() })
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button { landing = .home } label: { Label("Home", systemImage: "house") }
                            .help("Back to the Home dashboard")
                    }
                }
        }
    }
}
