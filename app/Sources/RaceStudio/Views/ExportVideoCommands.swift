import SwiftUI
import AppKit
import Combine
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

/// The app's overlay export, handed down without observing it (issue 9.14):
/// it publishes several times a second while it runs, so views that only need
/// its state follow `$state` instead of redrawing on every tick.
private struct VideoExportKey: EnvironmentKey {
    static let defaultValue: ExportProgressModel? = nil
}

extension EnvironmentValues {
    /// The app's overlay export (``AppDelegate/videoExport``).
    var videoExport: ExportProgressModel? {
        get { self[VideoExportKey.self] }
        set { self[VideoExportKey.self] = newValue }
    }
}

extension ExportProgressModel.State {
    /// Whether an export is running or cleaning up after a cancel.
    var isActive: Bool { self == .running || self == .cancelling }
}

extension ExportProgressModel {
    /// `model`'s state as it changes — nothing without one.
    static func statePublisher(of model: ExportProgressModel?) -> AnyPublisher<State, Never> {
        model?.$state.eraseToAnyPublisher() ?? Empty<State, Never>().eraseToAnyPublisher()
    }
}

/// The Video + Data header's **Export Video…** button (issue 9.14): the same
/// command as the menu, enabled by the same rule, with the same tooltip.
struct ExportVideoButton: View {
    @Environment(\.videoExport) private var progress
    @ObservedObject var controller: VideoReviewController
    @ObservedObject var review: VideoReviewModel
    let data: VideoDataViewModel
    let open: () -> Void
    @State private var hasTelemetry = false
    @State private var exportState: ExportProgressModel.State = .idle

    var body: some View {
        let availability = ExportCommandAvailability.of(controller: controller, review: review,
                                                        hasTelemetry: hasTelemetry, isExporting: exportState.isActive)
        Button(L10n.string(.controlExportVideo), action: open)
            .disabled(!availability.isEnabled)
            .help(availability.help())
            .onReceive(data.$telemetry) { hasTelemetry = $0 != nil }
            .onReceive(ExportProgressModel.statePublisher(of: progress)) { exportState = $0 }
    }
}

extension ExportCommandAvailability {
    /// The command's state for a window's video and telemetry, with
    /// `isExporting` when the app's export runs — or this window is opening or
    /// preparing one.
    @MainActor
    static func of(controller: VideoReviewController, review: VideoReviewModel, hasTelemetry: Bool,
                   isExporting: Bool) -> ExportCommandAvailability {
        evaluate(hasVideo: controller.attachment != nil,
                 videoOpens: controller.loadFailure == nil && controller.videoURL != nil, hasTelemetry: hasTelemetry,
                 status: review.status, isExporting: isExporting)
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
///
/// The forwarding — `responds(to:)` and `forwardingTarget(for:)` — relies on
/// that delegate (SwiftUI's own) being an Objective-C object, as every
/// `NSWindowDelegate` AppKit calls is. Should SwiftUI replace the window's
/// delegate while the guard stands, the guard simply stops asking, and is
/// never put back over the new one.
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
