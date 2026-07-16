import SwiftUI
import RaceStudioCore

/// Thin `@main` shell for the RaceStudio macOS app.
///
/// This target is intentionally logic-free: it only wires SwiftUI scenes and
/// renders values owned by `RaceStudioCore`, so it can be excluded from the
/// coverage metric by target. All testable behaviour belongs in
/// `RaceStudioCore`.
///
/// The scene is a `DocumentGroup` over `XRKDocument`, making RaceStudio a
/// document-based app that opens `.xrk`/`.xrz` telemetry files (issue 2.1). As of
/// 2.3 it also wires an Open panel, drag-and-drop, and an "Open Recent" menu
/// (backed by security-scoped bookmarks) through the shared `AppModel` →
/// `ImportCoordinator`. The summary screen (2.4) and error surfacing (2.5) build
/// on the resulting `SessionStore` state.
@main
struct RaceStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        DocumentGroup(viewing: XRKDocument.self) { _ in
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open…") { model.presentOpenPanel() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("Open Recent") {
                    ForEach(model.recents.entries, id: \.self) { url in
                        Button(url.lastPathComponent) { model.openRecent(url) }
                    }
                    if model.recents.entries.isEmpty {
                        Text("No Recent Files")
                    }
                }
            }
        }
    }
}
