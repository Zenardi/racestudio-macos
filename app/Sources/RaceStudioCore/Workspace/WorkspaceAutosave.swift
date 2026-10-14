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
/// Nothing the operator made is lost on the way:
/// - a change made while the workspace is still restoring is written once the
///   restore ends;
/// - a math channel that can't be re-created for the session stays in the saved
///   workspace (and is tried again on the next open) until one of the same name
///   replaces it;
/// - a write that fails is said (``saveFailed``) and tried again on the next
///   change or the close;
/// - a saved workspace that couldn't be read opens the defaults and says so
///   (``notice``); when it couldn't even be kept aside, nothing is written
///   over it;
/// - when two windows show one session, only the first saves — the other says
///   so — so they never write over each other.
///
/// It also keeps the last HUD (issue 9.22): every HUD change the window hears
/// after the open — each committed edit — is saved as the last HUD, and a
/// session that opens without a HUD of its own starts with it.
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

        /// What changes when the workspace does — the saved state only, so a
        /// channel search, a sort or a split's zoom never arms a write.
        var changes: [AnyPublisher<Void, Never>] {
            [Self.signal(window.$activeLayout), Self.signal(window.$selection), Self.signal(window.$videoOverlay),
             Self.signal(window.$videoDataPanes), Self.signal(logSheet.$sheet),
             Self.signal(mathChannels.$channels), Self.signal(splits.$layout), video.attachmentChanges]
        }

        /// `values` after the current one, as plain change signals.
        private static func signal<Value>(_ values: Published<Value>.Publisher) -> AnyPublisher<Void, Never> {
            values.dropFirst().map { _ in () }.eraseToAnyPublisher()
        }
    }

    /// What the open could not read in full, until dismissed.
    @Published public private(set) var notice: ProjectLoadNotice?
    /// Whether the last write failed. The next change, or the close, tries again.
    @Published public private(set) var saveFailed = false

    private let store: WorkspaceStore
    private let lastOverlay: LastOverlayStore?
    private let scheduler: DelayScheduling
    private let delay: Duration
    /// The restore under way or done — owned here, not by the caller's task,
    /// so a window torn down mid-open never leaves a half-restored workspace
    /// to be saved.
    private var opening: Task<Void, Never>?
    /// The window being saved and its session's content id — set once its
    /// workspace is restored, and never when it mustn't be written.
    private var saving: (parts: Parts, session: String)?
    /// What the file holds, as far as this window knows.
    private var lastWritten: ProjectDocument?
    /// Saved math channels this session couldn't re-create, kept in the file.
    private var keptMathChannels: [MathChannelDef] = []
    private var pending: AnyCancellable?
    private var watches: [AnyCancellable] = []
    private var lastHUDWatch: AnyCancellable?
    private static let logger = Logger(subsystem: "com.racestudio.core", category: "workspace")

    /// Which window saves each workspace file in this process.
    private static var savers: [URL: Saver] = [:]

    /// A window saving a workspace file, held weakly so a closed window frees it.
    private final class Saver {
        weak var autosave: WorkspaceAutosave?
        init(_ autosave: WorkspaceAutosave) { self.autosave = autosave }
    }

    /// - Parameters:
    ///   - store: where the session's workspace is kept.
    ///   - lastOverlay: where the last HUD is kept, or `nil` to keep none.
    ///   - scheduler: runs the delayed write (the tests advance a manual clock).
    ///   - delay: how long after a change the workspace is written.
    public init(store: WorkspaceStore, lastOverlay: LastOverlayStore? = nil,
                scheduler: DelayScheduling = TaskDelayScheduler(), delay: Duration = WorkspaceAutosave.delay) {
        self.store = store
        self.lastOverlay = lastOverlay
        self.scheduler = scheduler
        self.delay = delay
    }

    // MARK: - Opening

    /// Restore the saved workspace of `parts`' session into `parts`, then save
    /// every change from now on. Nothing is written for the open itself. The
    /// restore runs once per window, to the end even when the caller is
    /// cancelled; a second call waits for it.
    public func open(_ parts: Parts) async {
        if opening == nil {
            opening = Task { [weak self] in await self?.restoreAndWatch(parts) }
        }
        await opening?.value
    }

    private func restoreAndWatch(_ parts: Parts) async {
        let session = parts.window.contentID
        let owns = claim(store.url(forSession: session))
        var warnings: [ProjectLoadWarning] = owns ? [] : [.openInAnotherWindow]
        var diagnostics: [ProjectError] = []
        var saved: ProjectDocument?
        var mayWrite = owns
        switch store.load(session: session) {
        case .none:
            break
        case .document(let document):
            warnings += document.loadWarnings
            diagnostics = document.diagnostics
            warnings += await restore(document, into: parts)
            saved = document
        case .unreadable(let keptAside):
            warnings.append(.unreadableWorkspace(keptAside: keptAside))
            mayWrite = mayWrite && keptAside
        }
        startWithTheLastHUD(parts)
        rememberHUDChanges(parts)
        notice = ProjectLoadNotice(warnings: warnings, diagnostics: diagnostics)
        guard mayWrite else { return }
        saving = (parts, session)
        // The file's own content, so a change made while restoring is written.
        lastWritten = saved ?? snapshot(of: parts)
        watches = parts.changes.map { change in
            change.sink { [weak self] in self?.noteChange() }
        }
        if snapshot(of: parts) != lastWritten { noteChange() }
    }

    /// Apply a saved `document` to the window, the editor, the log sheet, the
    /// splits, the math channels and the footage. Returns a warning for each
    /// math channel that couldn't be re-created and isn't already said to be
    /// invalid.
    private func restore(_ document: ProjectDocument, into parts: Parts) async -> [ProjectLoadWarning] {
        parts.window.restore(from: document)
        parts.overlay.load(document.overlay)
        parts.logSheet.apply(document.logSheet)
        if let splits = document.splits { parts.splits.restore(splits) }
        var warnings: [ProjectLoadWarning] = []
        for channel in document.mathChannels {
            guard !(await parts.mathChannels.restore(channel)) else { continue }
            keptMathChannels.append(channel)
            if !document.diagnostics.contains(.invalidMathChannel(name: channel.name)) {
                warnings.append(.unrestoredMathChannel(channel.name))
            }
        }
        if let video = document.video {
            await parts.video.restore(video, sessionStartEpoch: Double(parts.window.session.metadata.datetimeUtc))
        }
        return warnings
    }

    /// A window without a HUD of its own takes the last one, with a fresh
    /// history — in the window too, so the export's *Current overlay* draws it.
    private func startWithTheLastHUD(_ parts: Parts) {
        guard parts.window.videoOverlay == nil, let last = lastOverlay?.load() else { return }
        parts.window.videoOverlay = last
        parts.overlay.load(last)
    }

    /// Keep every HUD change the window hears from now on — each committed
    /// edit, never the open's own — as the last HUD.
    private func rememberHUDChanges(_ parts: Parts) {
        guard let lastOverlay else { return }
        lastHUDWatch = parts.window.$videoOverlay.dropFirst().compactMap { $0 }.sink { layout in
            do {
                try lastOverlay.save(layout)
            } catch {
                Self.logger.error("could not keep the last HUD: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Make this window the one saving `file`, unless a live window already is.
    private func claim(_ file: URL) -> Bool {
        if let saver = Self.savers[file]?.autosave, saver !== self { return false }
        Self.savers[file] = Saver(self)
        return true
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
    /// A HUD drag still open is recorded first, so it is kept.
    public func flush() {
        pending = nil
        saving?.parts.overlay.endGesture()
        write()
    }

    /// The workspace as it stands, with the math channels kept from the file.
    private func snapshot(of parts: Parts) -> ProjectDocument {
        let live = parts.mathChannels.definitions
        let liveNames = Set(live.map(\.name))
        let kept = keptMathChannels.filter { !liveNames.contains($0.name) }
        return parts.window.projectDocument(mathChannels: live + kept, logSheet: parts.logSheet.sheet,
                                            video: parts.video.attachmentForSaving, splits: parts.splits.layout)
    }

    /// Write the workspace when it differs from what the file holds.
    private func write() {
        guard let saving else { return }
        let document = snapshot(of: saving.parts)
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
