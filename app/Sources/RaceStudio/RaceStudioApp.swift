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
/// document-based app that opens `.xrk`/`.xrz` telemetry files (issue 2.1). The
/// actual file-loading UI, drag/drop, recents, and summary screen arrive in
/// issues 2.2–2.4; here the viewer is a placeholder.
@main
struct RaceStudioApp: App {
    var body: some Scene {
        DocumentGroup(viewing: XRKDocument.self) { _ in
            ContentView()
        }
    }
}

/// Placeholder root view. Displays a Core-owned value so the shell carries no
/// logic of its own.
struct ContentView: View {
    var body: some View {
        Text(RaceStudioCore.appName)
            .padding()
    }
}
