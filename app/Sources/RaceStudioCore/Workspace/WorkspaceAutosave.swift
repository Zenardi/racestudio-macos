import Combine
import Foundation
import os

/// The footage a window holds, as its workspace saves and restores it (issue
/// 9.20). The shell's video controller adopts it: it owns the player and the
/// file's security scope, so the autosave only reads the attachment and hands
/// a saved one back.
@MainActor
public protocol WorkspaceVideo: AnyObject {
    /// The attached footage stamped with the alignment in force — offset, rate
    /// and status — or `nil` when none is attached.
    var attachmentForSaving: VideoAttachment? { get }
    /// Fires when the footage or its alignment changes.
    var attachmentChanges: AnyPublisher<Void, Never> { get }
    /// Re-open saved footage with the alignment it was saved with.
    func restore(_ attachment: VideoAttachment, sessionStartEpoch: Double) async
}

/// A session's workspace, kept with no Save command (issue 9.20).
///
/// ``open(_:)`` restores what the ``WorkspaceStore`` holds for the window's
/// session — the selection, the layouts, the HUD, the log sheet, the math
/// channels, the splits and the synced footage — and from then on every change
/// to any of them is written on its own, ``delay`` after it: the changes of a
/// burst (a drag, a sync scrub) are written once, a change undone before then
/// writes nothing, and ``flush()`` writes what is pending at once when the
/// session closes or the app quits.
///
/// A write that fails is said (``saveFailed``) and tried again on the next
/// change or the close; the window keeps its state meanwhile. A saved workspace
/// that couldn't be read opens the defaults and says so (``notice``); when it
/// couldn't even be kept aside, nothing is ever written over it.
@MainActor
public final class WorkspaceAutosave: ObservableObject {

    /// How long after a change the workspace is written.
    nonisolated public static let delay: Duration = .seconds(1)

    /// The parts of one window whose state is its workspace.
    @MainActor
    public struct Parts {
        public let window: AnalysisWindowModel
        public let overlay: OverlayEditorModel
        public let logSheet: LogSheetModel
        public let mathChannels: MathChannelsManagerModel
        public let splits: SplitReportModel
        public let video: WorkspaceVideo

        public init(window: AnalysisWindowModel, overlay: OverlayEditorModel, logSheet: LogSheetModel,
                    mathChannels: MathChannelsManagerModel, splits: SplitReportModel, video: WorkspaceVideo) {
            self.window = window
            self.overlay = overlay
            self.logSheet = logSheet
            self.mathChannels = mathChannels
            self.splits = splits
            self.video = video
        }

        /// The workspace as it stands.
        var document: ProjectDocument {
            window.projectDocument(mathChannels: mathChannels.definitions, logSheet: logSheet.sheet,
                                   video: video.attachmentForSaving, splits: splits.layout)
        }

        /// Everything that changes when the workspace does.
        var changes: [AnyPublisher<Void, Never>] {
            [window.objectWillChange.eraseToAnyPublisher(), logSheet.objectWillChange.eraseToAnyPublisher(),
             mathChannels.objectWillChange.eraseToAnyPublisher(), splits.objectWillChange.eraseToAnyPublisher(),
             video.attachmentChanges]
        }
    }

    /// What the open could not read in full, until dismissed.
    @Published public private(set) var notice: ProjectLoadNotice?
    /// Whether the last write failed. The next change, or the close, tries again.
    @Published public private(set) var saveFailed = false

    private let store: WorkspaceStore
    private let scheduler: DelayScheduling
    private let delay: Duration
    /// The window being saved and its session's content id — set once its
    /// workspace is restored, and never when it mustn't be written over.
    private var saving: (parts: Parts, session: String)?
    /// Whether ``open(_:)`` has run.
    private var isOpened = false
    /// What the file holds, as far as this window knows.
    private var lastWritten: ProjectDocument?
    private var pending: AnyCancellable?
    private var watches: [AnyCancellable] = []
    private static let logger = Logger(subsystem: "com.racestudio.core", category: "workspace")

    /// - Parameters:
    ///   - store: where the session's workspace is kept.
    ///   - scheduler: runs the delayed write (the tests advance a manual clock).
    ///   - delay: how long after a change the workspace is written.
    public init(store: WorkspaceStore, scheduler: DelayScheduling = TaskDelayScheduler(),
                delay: Duration = WorkspaceAutosave.delay) {
        self.store = store
        self.scheduler = scheduler
        self.delay = delay
    }

    // MARK: - Opening

    /// Restore the saved workspace of `parts`' session into `parts`, then save
    /// every change from now on. Nothing is written by the open itself. Called
    /// once per window; a second call does nothing.
    public func open(_ parts: Parts) async {
        guard !isOpened else { return }
        isOpened = true
        let session = parts.window.contentID
        switch store.load(session: session) {
        case .none:
            break
        case .document(let document):
            await restore(document, into: parts)
            notice = ProjectLoadNotice(document: document)
        case .unreadable(let keptAside):
            notice = ProjectLoadNotice(warnings: [.unreadableWorkspace(keptAside: keptAside)])
            guard keptAside else { return }
        }
        lastWritten = parts.document
        saving = (parts, session)
        watches = parts.changes.map { change in
            change.sink { [weak self] in self?.noteChange() }
        }
    }

    /// Apply a saved `document` to the window, the editor, the log sheet, the
    /// splits, the math channels and the footage.
    private func restore(_ document: ProjectDocument, into parts: Parts) async {
        parts.window.restore(from: document)
        parts.overlay.load(document.overlay)
        parts.logSheet.apply(document.logSheet)
        if let splits = document.splits { parts.splits.restore(splits) }
        for channel in document.mathChannels {
            _ = await parts.mathChannels.add(name: channel.name, unit: channel.unit, expression: channel.expression)
        }
        if let video = document.video {
            await parts.video.restore(video, sessionStartEpoch: Double(parts.window.session.metadata.datetimeUtc))
        }
    }

    /// Forget the open's notice.
    public func dismissNotice() {
        notice = nil
    }

    // MARK: - Saving

    /// The workspace changed: write it ``delay`` from now, unless a write is
    /// already due — so a burst is written once.
    public func noteChange() {
        guard saving != nil, pending == nil else { return }
        pending = scheduler.schedule(after: delay) { [weak self] in
            self?.pending = nil
            self?.write()
        }
    }

    /// Write what is pending now — the session is closing or the app quitting.
    public func flush() {
        pending = nil
        write()
    }

    /// Write the workspace when it differs from what the file holds.
    private func write() {
        guard let saving else { return }
        let document = saving.parts.document
        guard document != lastWritten else { return }
        do {
            try store.save(document, session: saving.session)
            lastWritten = document
            saveFailed = false
        } catch {
            Self.logger.error("workspace autosave failed: \(String(describing: error), privacy: .public)")
            saveFailed = true
        }
    }
}
