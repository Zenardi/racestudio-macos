import SwiftUI
import RaceStudioCore

/// Thin `@main` shell for the RaceStudio macOS app.
///
/// This target is intentionally logic-free: it only wires SwiftUI scenes and
/// renders values owned by `RaceStudioCore`, so it can be excluded from the
/// coverage metric by target. All testable behaviour belongs in
/// `RaceStudioCore`.
@main
struct RaceStudioApp: App {
    var body: some Scene {
        WindowGroup {
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
