import SwiftUI
import UniformTypeIdentifiers
import RaceStudioCore

/// Placeholder root view for a document window.
///
/// It accepts drag-and-drop of `.xrk`/`.xrz` files (issue 2.3), forwarding them
/// to the shared `AppModel` (which validates and imports via `RaceStudioCore`).
/// The summary screen that renders the loaded session is issue 2.4; here the
/// view carries no logic of its own.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Text(RaceStudioCore.appName)
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.xrk, .xrz], isTargeted: nil) { providers in
                model.receiveDrop(providers)
            }
    }
}
