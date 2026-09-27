import SwiftUI
import AppKit
import RaceStudioCore

/// The **About RaceStudio** menu item, replacing the stock one so the panel also
/// names the Rust decode core's version — a stale or mismatched
/// `RaceStudioFFI.xcframework` is otherwise invisible to a user reporting a bug.
///
/// Lives here rather than in `RaceStudioApp.swift` because the `@main` scene file
/// is held to declaring no methods of its own (`SmokeTests`); the credits string
/// itself is ``AppVersion/creditsText`` in `RaceStudioCore`, where it is tested.
struct AboutCommand: View {
    let version: AppVersion

    var body: some View {
        Button("About RaceStudio") {
            let credits = NSAttributedString(
                string: version.creditsText,
                attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)])
            NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: credits])
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}
