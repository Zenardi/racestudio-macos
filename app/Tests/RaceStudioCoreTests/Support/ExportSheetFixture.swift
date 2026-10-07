import Combine
import Foundation
@testable import RaceStudioCore

/// The export sheet suites' session and footage.
enum ExportSheetFixture {

    static let laps = [Lap(index: 0, startTimeS: 0, durationS: 21, endTimeS: 21),
                       Lap(index: 1, startTimeS: 21, durationS: 19, endTimeS: 40),
                       Lap(index: 2, startTimeS: 40, durationS: 20.5, endTimeS: 60.5)]

    static let footage = FootageInfo(duration: 50, frameRate: FrameGrid(numerator: 30, denominator: 1),
                                     naturalSize: CGSize(width: 1_920, height: 1_080), rotation: .none,
                                     audio: FootageAudio(sampleRate: 48_000, channels: 2), codec: "avc1")

    static let metadata = SessionMetadata(vehicle: "", track: "Adria Kart", driver: "", session: "", series: "",
                                          logDate: "01/23/2016", logTime: "12:09:04", datetimeUtc: 1_453_550_944)

    static func input(offset: Double = 5, status: SyncStatus = .anchored(lap: LapID(1)),
                      selection: SessionTimeSpan? = nil, selectedLaps: [LapID] = [],
                      hasWorkspaceOverlay: Bool = true) -> ExportSheetInput {
        ExportSheetInput(source: URL(fileURLWithPath: "/footage/onboard.mp4"), footage: footage,
                         sync: VideoSyncModel(videoDuration: footage.duration, offset: offset), status: status,
                         timeline: LapSectorTimeline.make(laps: laps, segments: [], layout: .even(base: 2, count: 2)),
                         laps: laps, session: SessionTimeSpan(start: 0, end: 62), selection: selection,
                         selectedLaps: selectedLaps, metadata: metadata, hasWorkspaceOverlay: hasWorkspaceOverlay)
    }

    @MainActor
    static func model(offset: Double = 5, status: SyncStatus = .anchored(lap: LapID(1)),
                      selection: SessionTimeSpan? = nil, selectedLaps: [LapID] = [],
                      hasWorkspaceOverlay: Bool = true, preferences: ExportPreferences = ExportPreferences(),
                      encoders: EncoderAvailability = .all, locale: Locale = Locale(identifier: "en"),
                      scheduler: any DelayScheduling = ManualScheduler()) -> ExportSheetModel {
        ExportSheetModel(input: input(offset: offset, status: status, selection: selection,
                                      selectedLaps: selectedLaps, hasWorkspaceOverlay: hasWorkspaceOverlay),
                         preferences: preferences, encoders: encoders, locale: locale, scheduler: scheduler)
    }

    /// A model over the same footage, but a session whose only lap has no
    /// valid time — no best lap, nothing to pick.
    @MainActor
    static func modelWithoutValidLaps() -> ExportSheetModel {
        var input = input()
        input.laps = [Lap(index: 0, startTimeS: 0, durationS: 0, endTimeS: 0)]
        input.timeline = LapSectorTimeline.make(laps: input.laps, segments: [], layout: .even(base: 2, count: 2))
        return ExportSheetModel(input: input, encoders: .all, locale: Locale(identifier: "en"),
                                scheduler: ManualScheduler())
    }
}

/// A clock for debounced work: what is scheduled runs only when the test
/// advances it, on the spot — no task, no real time.
@MainActor
final class ManualScheduler: DelayScheduling {
    private final class Item {
        let work: @MainActor () -> Void
        var isCancelled = false
        init(_ work: @escaping @MainActor () -> Void) { self.work = work }
    }

    /// Every delay asked for, in order.
    private(set) var delays: [Duration] = []
    private var items: [Item] = []

    nonisolated init() {}

    func schedule(after delay: Duration, _ work: @escaping @MainActor () -> Void) -> AnyCancellable {
        delays.append(delay)
        let item = Item(work)
        items.append(item)
        return AnyCancellable { item.isCancelled = true }
    }

    /// Run everything scheduled and not cancelled.
    func advance() {
        let due = items
        items.removeAll()
        due.filter { !$0.isCancelled }.forEach { $0.work() }
    }
}
