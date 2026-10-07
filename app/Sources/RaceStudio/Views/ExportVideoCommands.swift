import SwiftUI
import AppKit
import RaceStudioCore

/// What the focused analysis window offers **File ▸ Export Video with
/// Overlay…** (issue 9.14): whether it can, why not, and how to open the sheet.
struct ExportVideoAction {
    var availability: ExportCommandAvailability
    var open: () -> Void
}

private struct ExportVideoActionKey: FocusedValueKey {
    typealias Value = ExportVideoAction
}

extension FocusedValues {
    /// The focused analysis window's export command.
    var exportVideoAction: ExportVideoAction? {
        get { self[ExportVideoActionKey.self] }
        set { self[ExportVideoActionKey.self] = newValue }
    }
}

/// **File ▸ Export Video with Overlay…** (⌥⌘E, issue 9.14), enabled by the
/// focused window's ``ExportCommandAvailability``, with its reason as the
/// tooltip when it isn't.
struct ExportVideoCommands: Commands {
    @FocusedValue(\.exportVideoAction) private var action

    var body: some Commands {
        CommandGroup(after: .importExport) {
            Button(L10n.string(.menuFileExportVideo)) { action?.open() }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(!(action?.availability.isEnabled ?? false))
                .help(action?.availability.help() ?? ExportCommandAvailability.unavailable(.noVideo).help())
        }
    }
}

/// The Video + Data header's **Export Video…** button (issue 9.14): the same
/// command as the menu, enabled by the same rule, with the same tooltip.
struct ExportVideoButton: View {
    @EnvironmentObject private var progress: ExportProgressModel
    @ObservedObject var controller: VideoReviewController
    @ObservedObject var review: VideoReviewModel
    let data: VideoDataViewModel
    let open: () -> Void
    @State private var hasTelemetry = false

    var body: some View {
        let availability = ExportCommandAvailability.of(controller: controller, review: review,
                                                        hasTelemetry: hasTelemetry, progress: progress)
        Button(L10n.string(.controlExportVideo), action: open)
            .disabled(!availability.isEnabled)
            .help(availability.help())
            .onReceive(data.$telemetry) { hasTelemetry = $0 != nil }
    }
}

extension ExportCommandAvailability {
    /// The command's state for a window's video, telemetry and the app's export.
    @MainActor
    static func of(controller: VideoReviewController, review: VideoReviewModel, hasTelemetry: Bool,
                   progress: ExportProgressModel) -> ExportCommandAvailability {
        evaluate(hasVideo: controller.attachment != nil,
                 videoOpens: controller.loadFailure == nil && controller.videoURL != nil, hasTelemetry: hasTelemetry,
                 status: review.status, isExporting: progress.isActive)
    }
}

/// Asks before the window closes while the export it started runs (issue
/// 9.14). While `isActive`, it stands in as the window's delegate — passing
/// every message on to the delegate it replaced — and answers
/// `windowShouldClose(_:)` with `shouldClose`; when the export ends, the
/// original delegate is put back, so the window is otherwise untouched.
struct WindowCloseGuard: NSViewRepresentable {
    let isActive: Bool
    let shouldClose: @MainActor (NSWindow) -> Bool

    func makeNSView(context: Context) -> GuardView {
        GuardView()
    }

    func updateNSView(_ view: GuardView, context: Context) {
        view.shouldClose = shouldClose
        view.isActive = isActive
    }

    final class GuardView: NSView {
        var shouldClose: @MainActor (NSWindow) -> Bool = { _ in true }
        var isActive = false { didSet { refresh() } }
        private var proxy: CloseGuardDelegate?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            refresh()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { uninstall() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func refresh() {
            if isActive, window != nil { install() } else { uninstall() }
        }

        private func install() {
            guard let window, proxy == nil else { return }
            let proxy = CloseGuardDelegate(original: window.delegate) { [weak self] window in
                self?.shouldClose(window) ?? true
            }
            window.delegate = proxy
            self.proxy = proxy
        }

        private func uninstall() {
            guard let proxy else { return }
            if let window, window.delegate === proxy { window.delegate = proxy.original }
            self.proxy = nil
        }
    }
}

/// A window delegate that answers `windowShouldClose(_:)` itself and forwards
/// everything else to the delegate it stands in for.
final class CloseGuardDelegate: NSObject, NSWindowDelegate {
    /// The window's own delegate — held, so it outlives the swap.
    let original: NSWindowDelegate?
    private let shouldClose: @MainActor (NSWindow) -> Bool

    init(original: NSWindowDelegate?, shouldClose: @escaping @MainActor (NSWindow) -> Bool) {
        self.original = original
        self.shouldClose = shouldClose
    }

    @MainActor
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard shouldClose(sender) else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (original?.responds(to: selector) ?? false)
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}
