import Combine
import Foundation
@testable import RaceStudioCore

/// The synthetic session, saved workspace and recording doubles the
/// ``WorkspaceAutosave`` suites share (issue 9.20). No logic: fixed data, and
/// doubles that only record.
@MainActor
protocol WorkspaceAutosaveFixture {}

/// Every write a test store makes, and a switch that makes them fail.
final class WorkspaceDisk {
    var writes = 0
    var failing = false
}

/// The failure a failing ``WorkspaceDisk`` throws.
struct WorkspaceDiskFull: Error {}

/// An evaluator that gives every expression two samples.
struct TwoSampleEvaluator: ExpressionEvaluating {
    func evaluate(_ expression: String) async throws -> [MathSample] {
        [MathSample(time: 0, value: 1), MathSample(time: 1, value: 2)]
    }
}

/// A window's footage, as the autosave sees it: what is attached, and every
/// attachment it was asked to restore.
@MainActor
final class FakeWorkspaceVideo: WorkspaceVideo {
    @Published var attachment: VideoAttachment?
    private(set) var restored: [(attachment: VideoAttachment, epoch: Double)] = []

    var attachmentForSaving: VideoAttachment? { attachment }
    var attachmentChanges: AnyPublisher<Void, Never> {
        $attachment.dropFirst().map { _ in () }.eraseToAnyPublisher()
    }

    func restore(_ attachment: VideoAttachment, sessionStartEpoch: Double) async {
        restored.append((attachment, sessionStartEpoch))
        self.attachment = attachment
    }
}

/// One window's parts, wired as the app wires them.
@MainActor
struct WorkspaceWindow {
    let model: AnalysisWindowModel
    let overlay = OverlayEditorModel(layout: nil)
    let logSheet = LogSheetModel()
    let math = MathChannelsManagerModel(evaluator: TwoSampleEvaluator())
    let splits = SplitReportModel()
    let video = FakeWorkspaceVideo()

    var parts: WorkspaceAutosave.Parts {
        WorkspaceAutosave.Parts(window: model, overlay: overlay, logSheet: logSheet, mathChannels: math,
                                splits: splits, video: video)
    }
}

extension WorkspaceAutosaveFixture {
    typealias Disk = WorkspaceDisk
    typealias Window = WorkspaceWindow

    var session: Session {
        Session(
            metadata: SessionMetadata(vehicle: "Kart", track: "Synthetic Raceway", driver: "", session: "Practice 2",
                                      series: "", logDate: "", logTime: "", datetimeUtc: 1_700_000_000),
            channels: [Channel(name: "GPS Speed", unit: "km/h", sampleRateHz: 20, decimals: 1, sampleCount: 10),
                       Channel(name: "RPM", unit: "rpm", sampleRateHz: 20, decimals: 0, sampleCount: 10)],
            laps: [Lap(index: 0, startTimeS: 0, durationS: 60, endTimeS: 60),
                   Lap(index: 1, startTimeS: 60, durationS: 50, endTimeS: 110),
                   Lap(index: 2, startTimeS: 110, durationS: 49, endTimeS: 159)])
    }

    /// Footage synced on lap 2, with a made-up bookmark.
    var video: VideoAttachment {
        VideoAttachment(bookmark: Data("/synthetic/onboard.mp4".utf8), displayName: "onboard.mp4",
                        offset: -10.5, rate: 1.0002, status: .anchored(lap: LapID(1)))
    }

    var contentID: String { SessionIndex.contentID(for: session) }

    /// A new window on the session, its editor feeding the window's overlay.
    func window() -> Window {
        let window = Window(model: AnalysisWindowModel(session: session, analysis: nil))
        let model = window.model
        window.overlay.onCommit = { [weak model] layout in model?.videoOverlay = layout }
        return window
    }

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkspaceAutosaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A store in `dir` whose writes `disk` counts, and fails while it says so.
    func store(in dir: URL, disk: Disk = Disk(), validator: FakeExpressionValidator = .init()) -> WorkspaceStore {
        WorkspaceStore(directory: dir, validator: validator, write: { data, url in
            disk.writes += 1
            if disk.failing { throw WorkspaceDiskFull() }
            try data.write(to: url, options: .atomic)
        })
    }

    /// The workspace saved in `dir` for the session, if one reads.
    func saved(in dir: URL) -> ProjectDocument? {
        guard case let .document(document) = store(in: dir).load(session: contentID) else { return nil }
        return document
    }

    /// A workspace the operator set up: channels, laps and a reference, Video +
    /// Data with rearranged panes, a HUD, a log sheet, a math channel, five
    /// splits and synced footage.
    func setUp(_ window: Window) async {
        window.model.setSelection(channelNames: ["RPM"], lapIndices: [1, 2], reference: 2)
        window.model.select(layout: .videoReview)
        window.model.videoDataPanes.setVisible(false, for: .lapList)
        window.model.videoOverlay = OverlayPreset.minimal.layout(locale: Locale(identifier: "en"))
        window.logSheet.sheet.notes = "Wet track"
        _ = await window.math.add(name: "Double RPM", unit: "rpm", expression: "RPM * 2")
        window.splits.restore(SplitLayout.even(base: SplitReportModel.baseResolution, count: 5)
            .renaming(1, to: "Hairpin"))
        window.video.attachment = video
    }

    /// A workspace saved by an earlier window in `dir`.
    @discardableResult
    func savedWorkspace(in dir: URL) async throws -> ProjectDocument {
        let earlier = window()
        await setUp(earlier)
        let document = earlier.model.projectDocument(
            mathChannels: earlier.math.definitions, logSheet: earlier.logSheet.sheet,
            video: earlier.video.attachmentForSaving, splits: earlier.splits.layout)
        try store(in: dir).save(document, session: contentID)
        return document
    }
}
