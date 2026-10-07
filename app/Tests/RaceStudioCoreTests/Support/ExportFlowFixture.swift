import Foundation
import Testing
@testable import RaceStudioCore

/// The export flow suites' shared pieces (issue 9.14).
@MainActor
protocol ExportFlowTesting {}

typealias ExportFeed = AsyncThrowingStream<ExportProgress, Error>.Continuation

extension ExportFlowTesting {
    /// Where the window's export writes.
    var destination: URL { URL(fileURLWithPath: "/tmp/lap.mp4") }
    /// A failure to show.
    var message: ExportUserMessage { ExportUserMessage(title: "The video can’t be read", fix: "Attach it again.") }

    /// Begin `flow`'s export to `url` and end its preparation: the export runs.
    func started(_ flow: ExportFlowModel, to url: URL = URL(fileURLWithPath: "/tmp/lap.mp4")) {
        guard let preparation = flow.beginExport(to: url, progress: ExportProgressModel()) else {
            Issue.record("the export was refused")
            return
        }
        #expect(flow.endPreparation(preparation))
    }

    /// A sheet model to open.
    func sheet() -> ExportSheetModel { ExportSheetFixture.model() }

    /// An app export, running to `url`.
    func running(to url: URL) -> (ExportProgressModel, ExportFeed) {
        let progress = ExportProgressModel()
        let (stream, continuation) = AsyncThrowingStream<ExportProgress, Error>.makeStream()
        progress.start(stream, to: url, cancel: {})
        return (progress, continuation)
    }
}

extension ExportFlowModel.Route: Equatable {
    /// Test-only: routes compare by what they show.
    public static func == (lhs: ExportFlowModel.Route, rhs: ExportFlowModel.Route) -> Bool {
        lhs.id == rhs.id
    }
}
