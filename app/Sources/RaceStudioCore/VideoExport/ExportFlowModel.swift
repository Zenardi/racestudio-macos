import Foundation

/// A window's part in the app's one overlay export (issue 9.14): which export
/// sheet is up, whether this window's export is being opened, prepared or run,
/// and what the window does as that export moves on.
///
/// The app runs one ``ExportProgressModel`` for every window; each window
/// keeps one of these, so only the window that started an export shows its
/// progress, its badge and its result, and asks before closing over it.
///
/// - **Opening** (``beginOpening()`` … ``opened(_:)``): one at a time — a
///   second ⌥⌘E while the footage is probed, or while a sheet is up, is
///   ignored.
/// - **Starting** (``beginExport(to:progress:)``): refused while the app's
///   export runs or this window prepares one. The settings sheet goes first;
///   the progress sheet comes up once it has gone (``sheetDismissed()``), so
///   one sheet is never swapped for another in place.
/// - **Preparing**: between the save panel and the first frame the overlay's
///   telemetry may load; ``cancelPreparation()`` stops it, and
///   ``endPreparation()`` says whether the export may still start.
/// - **Following** (``exportChanged(to:progress:)``): an export ending while
///   its sheet is hidden brings the result back; a cancel that has cleaned up
///   closes the sheet and ends the window's ownership.
///
/// Pure: the shell applies it to SwiftUI and AppKit.
@MainActor
public final class ExportFlowModel: ObservableObject {

    /// The export sheet on screen.
    public enum Route: Identifiable {
        /// The export's settings.
        case settings(ExportSheetModel)
        /// The running or ended export, or why it could not start.
        case progress

        public var id: String {
            switch self {
            case .settings: return "settings"
            case .progress: return "progress"
            }
        }
    }

    /// The sheet on screen — bound to the window's sheet, which clears it when
    /// the sheet is dismissed.
    @Published public var route: Route?
    /// Why the export could not start, before any progress.
    @Published public private(set) var failure: ExportUserMessage?
    /// Whether the footage is being probed to open the sheet.
    @Published public private(set) var isOpening = false
    /// Whether this window's export is being prepared — before its first frame.
    @Published public private(set) var isPreparing = false
    /// Where this window's export writes, while the window owns one.
    @Published public private(set) var destination: URL?

    /// One export's preparation (issue 9.14 review): what lets a preparation
    /// cancelled and then replaced by a new export be told from the new one,
    /// however late it returns.
    public struct Preparation: Equatable, Sendable {
        let number: Int
    }

    /// The sheet to show once the one on screen has gone.
    private var pendingRoute: Route?
    /// The preparation under way, if any.
    private var preparation: Preparation?
    /// How many preparations were begun.
    private var preparations = 0
    /// The app export's state last acted on — a replay of it is not acted on
    /// twice.
    private var lastState: ExportProgressModel.State?

    public init() {}

    /// The exported file's name, for the progress sheet.
    public var fileName: String { destination?.lastPathComponent ?? "" }

    /// Whether an export is being opened or prepared here — the command treats
    /// it as running.
    public var isBusy: Bool { isOpening || isPreparing }

    // MARK: - Opening

    /// Start opening the sheet; `false` while one is opening or a sheet is up.
    public func beginOpening() -> Bool {
        guard !isOpening, route == nil else { return false }
        isOpening = true
        return true
    }

    /// The footage is probed: show `sheet`.
    public func opened(_ sheet: ExportSheetModel) {
        isOpening = false
        failure = nil
        show(.settings(sheet))
    }

    /// The export could not start: show why. The window owns no export.
    public func failed(_ message: ExportUserMessage) {
        isOpening = false
        isPreparing = false
        preparation = nil
        destination = nil
        failure = message
        show(.progress)
    }

    // MARK: - Starting

    /// The save panel chose `destination`: this window's export is prepared,
    /// and its progress shown once the settings sheet has gone.
    ///
    /// - Returns: the preparation, to end (``endPreparation(_:)``) or fail
    ///   (``failPreparation(_:_:)``) — or `nil`, changing nothing, while the
    ///   app's export runs or one is prepared here.
    public func beginExport(to destination: URL, progress: ExportProgressModel) -> Preparation? {
        guard !progress.isActive, !isPreparing else { return nil }
        preparations += 1
        let begun = Preparation(number: preparations)
        preparation = begun
        self.destination = destination
        failure = nil
        isPreparing = true
        show(.progress)
        return begun
    }

    /// `preparation` is over: `true` when the export may start — `false` when
    /// it was cancelled meanwhile, or is not the one under way.
    public func endPreparation(_ preparation: Preparation) -> Bool {
        guard isPreparing, preparation == self.preparation else { return false }
        isPreparing = false
        self.preparation = nil
        return true
    }

    /// `preparation` failed: show why — unless it is no longer the one under way.
    public func failPreparation(_ preparation: Preparation, _ message: ExportUserMessage) {
        guard isPreparing, preparation == self.preparation else { return }
        failed(message)
    }

    /// Cancel the export being prepared: nothing starts, and the sheet goes.
    public func cancelPreparation() {
        guard isPreparing else { return }
        isPreparing = false
        preparation = nil
        destination = nil
        dismiss()
    }

    // MARK: - Sheets

    /// The sheet on screen has gone: show the one waiting, if any.
    public func sheetDismissed() {
        guard route == nil, let pending = pendingRoute else { return }
        pendingRoute = nil
        route = pending
    }

    /// Close the sheet; a running export carries on.
    public func dismiss() {
        pendingRoute = nil
        route = nil
    }

    /// Show the progress sheet again.
    public func showProgress() {
        show(.progress)
    }

    // MARK: - Following the app's export

    /// Whether `progress` is following the export this window started.
    public func owns(_ progress: ExportProgressModel) -> Bool {
        destination != nil && progress.destination == destination
    }

    /// The app's export moved to `state` — acted on once, however often it is
    /// told.
    ///
    /// - In the window that started it, an end brings a hidden result back,
    ///   and a cleaned-up cancel closes the progress sheet and ends the
    ///   window's ownership.
    /// - In any other window, an export starting closes an old result still on
    ///   screen, rather than showing that export's progress in its sheet; a
    ///   failure or a preparation on screen stays.
    public func exportChanged(to state: ExportProgressModel.State, progress: ExportProgressModel) {
        guard state != lastState else { return }
        lastState = state
        guard owns(progress) else {
            if state == .running, case .progress = route, failure == nil, !isPreparing { dismiss() }
            return
        }
        switch state {
        case .finished, .failed:
            if route == nil { show(.progress) }
        case .idle:
            destination = nil
            if case .progress = route, failure == nil { dismiss() }
        case .running, .cancelling:
            break
        }
    }

    /// *Done*: put the ended export away.
    public func finish(progress: ExportProgressModel) {
        if owns(progress) { progress.dismiss() }
        destination = nil
        failure = nil
        dismiss()
    }

    // MARK: - Guards

    /// Whether closing the window must ask first: this window's export is
    /// being prepared, or runs.
    public func guardsClose(progress: ExportProgressModel) -> Bool {
        isPreparing || (owns(progress) && progress.isActive)
    }

    /// Whether the workspace bar shows this window's running export, its
    /// sheet hidden.
    public func showsBadge(progress: ExportProgressModel) -> Bool {
        owns(progress) && progress.isActive && route == nil
    }

    // MARK: - Internals

    /// Show `route` now, or once the sheet on screen has gone — replacing any
    /// sheet already waiting for it. The progress sheet already up stays up:
    /// it shows whatever comes next itself.
    private func show(_ route: Route) {
        if case .progress = route, case .progress? = self.route { return }
        if pendingRoute != nil {
            pendingRoute = route
        } else if self.route == nil {
            self.route = route
        } else {
            pendingRoute = route
            self.route = nil
        }
    }
}
