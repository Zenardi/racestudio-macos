import SwiftUI
import RaceStudioCore

/// Thin `@main` shell for the RaceStudio macOS app.
///
/// This target is intentionally logic-free: it only wires SwiftUI scenes and
/// renders values owned by `RaceStudioCore`, so it can be excluded from the
/// coverage metric by target. All testable behaviour belongs in
/// `RaceStudioCore`.
///
/// The **primary** scene is a `Window` showing the session library browser
/// (issue 8.14) — the RaceStudio 3 "choose what to analyze" landing window — so
/// launching the app shows a real UI, not a bare file-open panel. It shows the
/// analysis view once a session is opened (``LibraryRootView``). A secondary
/// `DocumentGroup` over `XRKDocument` keeps `.xrk`/`.xrz` files openable from
/// Finder (issue 2.1); because a `Window` scene comes first, macOS opens that at
/// launch instead of presenting the document open panel.
@main
struct RaceStudioApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("RaceStudio", id: "library") {
            LibraryRootView()
                .environmentObject(model)
                .environmentObject(model.store)
                .frame(minWidth: 900, minHeight: 560)
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

        DocumentGroup(viewing: XRKDocument.self) { _ in
            ContentView()
                .environmentObject(model)
                .environmentObject(model.store)
        }
    }
}
