import Foundation
import Testing
@testable import RaceStudioCore

/// How an overlay export fails (issue 9.13): cancelled or failing, it ends
/// with a typed ``OverlayExportError`` and leaves no partial file — neither at
/// the destination, where an existing file is only ever replaced by a
/// finished export, nor in its scratch directory.
@Suite struct OverlayVideoExporterFailureTests {

    private func overlay(_ drawer: any OverlayFrameDrawing = SessionTimeBar(origin: 0)) async throws -> ExportOverlay {
        ExportOverlay(drawer: drawer, telemetry: try await SessionTimeBar.timeline(from: -100, to: 100))
    }

    /// The plan of exporting `url`, described without reading it.
    private func blindPlan(_ url: URL) throws -> ExportPlan {
        let footage = FootageInfo(duration: 3, frameRate: FrameGrid(numerator: 30, denominator: 1),
                                  naturalSize: CGSize(width: 320, height: 180), rotation: .none, audio: nil,
                                  codec: "avc1")
        let request = ExportRequest(source: url, sync: VideoSyncModel(videoDuration: 3), range: .wholeFootage,
                                    session: SessionTimeSpan(start: 0, end: 3),
                                    settings: ExportSettings(resolution: .source))
        return try ExportPlan.make(request: request, footage: footage, timeline: .empty, encoders: .all).get()
    }

    /// The error the export ends with, or `nil` when it finishes.
    private func failure(of stream: AsyncThrowingStream<ExportProgress, Error>) async -> OverlayExportError? {
        do {
            _ = try await collect(stream)
            return nil
        } catch {
            return error as? OverlayExportError
        }
    }

    /// Wait up to `seconds` for `condition`.
    private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        return true
    }

    // MARK: - Cancelling

    /// Cancelled half-way, the export stops within about a second, its stream
    /// throws `cancelled`, and nothing of it is left on disk.
    @Test func test_cancelling_half_way_throws_cancelled_and_leaves_no_file() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let exporter = sandbox.exporter(progressInterval: .milliseconds(50))
        let stream = exporter.export(plan, overlay: try await overlay(SlowSessionTimeBar()), to: sandbox.destination)
        var cancelledAt: Date?

        var error: Error?
        do {
            for try await progress in stream where progress.fraction >= 0.5 && cancelledAt == nil {
                cancelledAt = Date()
                await exporter.cancel()
            }
        } catch let thrown {
            error = thrown
        }

        let latency = Date().timeIntervalSince(try #require(cancelledAt))
        #expect(error as? OverlayExportError == .cancelled)
        #expect(latency < 2, "stopped \(latency) s after the cancel")
        #expect(!sandbox.destinationExists)
        #expect(!sandbox.scratchExists)
    }

    /// A cancel made the moment an export is asked for — before it has started
    /// running — still cancels it.
    @Test func test_a_cancel_right_after_asking_still_cancels() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let exporter = sandbox.exporter()

        let stream = exporter.export(plan, overlay: try await overlay(), to: sandbox.destination)
        await exporter.cancel()

        #expect(await failure(of: stream) == .cancelled)
        #expect(!sandbox.destinationExists && !sandbox.scratchExists)
    }

    /// When the task reading the progress is cancelled, the export stops and
    /// cleans up after itself.
    @Test func test_cancelling_the_consuming_task_stops_the_export() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let stream = sandbox.exporter().export(plan, overlay: try await overlay(SlowSessionTimeBar()),
                                               to: sandbox.destination)
        let consumer = Task { try await collect(stream) }

        #expect(try await eventually { sandbox.scratchExists }, "the export started")
        consumer.cancel()

        #expect(try await eventually { !sandbox.scratchExists }, "the scratch directory is removed")
        #expect(!sandbox.destinationExists)
    }

    // MARK: - Typed failures

    /// Footage that is not media fails as unreadable.
    @Test func test_unreadable_footage_fails_typed() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let corrupt = sandbox.directory.appendingPathComponent("corrupt.mp4")
        try Data(repeating: 0x5A, count: 4_096).write(to: corrupt)

        let error = await failure(of: sandbox.exporter().export(try blindPlan(corrupt), overlay: try await overlay(),
                                                                to: sandbox.destination))

        #expect(error == .sourceUnreadable)
        #expect(!sandbox.destinationExists && !sandbox.scratchExists)
    }

    /// Footage with sound but no picture fails as having no video track.
    @Test func test_footage_without_video_fails_typed() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let sound = sandbox.directory.appendingPathComponent("sound.m4a")
        try await TestMediaFactory.writeAudioOnly(to: sound)

        let error = await failure(of: sandbox.exporter().export(try blindPlan(sound), overlay: try await overlay(),
                                                                to: sandbox.destination))

        #expect(error == .noVideoTrack)
        #expect(!sandbox.destinationExists && !sandbox.scratchExists)
    }

    /// Too little free space is caught before anything is written, naming the
    /// space the export needs — its estimate plus 10%.
    @Test func test_too_little_disk_space_fails_before_writing() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())

        let error = await failure(of: sandbox.exporter(available: 1_000).export(plan, overlay: try await overlay(),
                                                                                to: sandbox.destination))

        #expect(error == .insufficientDiskSpace(required: plan.requiredBytes, available: 1_000))
        #expect(!sandbox.destinationExists && !sandbox.scratchExists)
    }

    /// A destination folder that does not exist fails as a writer error, and
    /// the scratch file is still removed.
    @Test func test_a_missing_destination_folder_fails_as_a_writer_error() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let nowhere = sandbox.directory.appendingPathComponent("missing/export.mp4")

        let error = await failure(of: sandbox.exporter().export(plan, overlay: try await overlay(), to: nowhere))

        guard case .writerFailed = error else {
            Issue.record("expected a writer failure, got \(String(describing: error))")
            return
        }
        #expect(!sandbox.scratchExists)
    }

    // MARK: - Exporting onto the footage

    /// The footage itself — however its path is spelled — is never an export's
    /// destination: replacing it would destroy the source mid-read.
    @Test func test_the_footage_cannot_be_the_destination() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let footage = try await sandbox.footage()
        let plan = try await exportPlan(footage)
        let original = try Data(contentsOf: footage)
        let respelled = sandbox.directory.appendingPathComponent("scratch/../footage.mp4", isDirectory: false)

        let error = await failure(of: sandbox.exporter().export(plan, overlay: try await overlay(), to: respelled))

        #expect(error == .destinationIsSource)
        #expect(try Data(contentsOf: footage) == original)
        #expect(!sandbox.scratchExists)
    }

    /// A symbolic link to the footage resolves to it, and is refused.
    @Test func test_a_symlink_to_the_footage_cannot_be_the_destination() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let footage = try await sandbox.footage()
        let link = sandbox.directory.appendingPathComponent("link.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: footage)

        let error = await failure(of: sandbox.exporter().export(try await exportPlan(footage),
                                                                overlay: try await overlay(), to: link))

        #expect(error == .destinationIsSource)
    }

    /// A hard link — another path to the same file — is caught by the file's
    /// identity, not its path.
    @Test func test_a_hard_link_to_the_footage_cannot_be_the_destination() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let footage = try await sandbox.footage()
        let other = sandbox.directory.appendingPathComponent("same-file.mp4")
        try FileManager.default.linkItem(at: footage, to: other)

        let error = await failure(of: sandbox.exporter().export(try await exportPlan(footage),
                                                                overlay: try await overlay(), to: other))

        #expect(error == .destinationIsSource)
        #expect(try await FootageProbe.probe(footage).frameCount == 90, "the footage is untouched")
    }

    // MARK: - Replacing an existing file

    /// An existing file at the destination is replaced by the finished export.
    @Test func test_an_existing_destination_is_replaced_on_success() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        try Data("an older export".utf8).write(to: sandbox.destination)

        _ = try await collect(sandbox.exporter().export(plan, overlay: try await overlay(), to: sandbox.destination))

        #expect(try await MovieReadback.read(sandbox.destination).frameTimes.count == plan.frameCount)
    }

    /// A failed or cancelled export never touches an existing file at the destination.
    @Test func test_an_existing_destination_survives_a_failure() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let older = Data("an older export".utf8)
        try older.write(to: sandbox.destination)

        let error = await failure(of: sandbox.exporter(available: 1_000).export(plan, overlay: try await overlay(),
                                                                                to: sandbox.destination))

        #expect(error != nil)
        #expect(try Data(contentsOf: sandbox.destination) == older)
    }

    /// The free space is read where the export writes — its scratch directory,
    /// on the destination's volume and readable inside the sandbox, unlike the
    /// destination's folder — and a space that cannot be read does not block
    /// the export.
    @Test func test_free_space_is_read_in_the_scratch_directory_and_never_blocks_when_unknown() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let disk = UnreadableDiskSpace()
        let scratch = sandbox.scratch
        let exporter = OverlayVideoExporter(diskSpace: disk, scratchDirectory: { _ in
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            return scratch
        })

        _ = try await collect(exporter.export(plan, overlay: try await overlay(), to: sandbox.destination))

        #expect(disk.askedAbout == [scratch])
        #expect(sandbox.destinationExists)
    }

    /// Cancelled half-way through encoding, an export leaves an existing file
    /// at its destination exactly as it was.
    @Test func test_an_existing_destination_survives_a_cancel_mid_encode() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let older = Data("an older export".utf8)
        try older.write(to: sandbox.destination)
        let exporter = sandbox.exporter(progressInterval: .milliseconds(50))
        let stream = exporter.export(plan, overlay: try await overlay(SlowSessionTimeBar()), to: sandbox.destination)

        var error: Error?
        do {
            for try await progress in stream where progress.fraction >= 0.5 { await exporter.cancel() }
        } catch let thrown {
            error = thrown
        }

        #expect(error as? OverlayExportError == .cancelled)
        #expect(try Data(contentsOf: sandbox.destination) == older)
        #expect(!sandbox.scratchExists)
    }

    /// The production scratch directory cannot be made for a folder that does
    /// not exist: the export fails as a writer error, having written nothing.
    @Test func test_a_scratch_directory_that_cannot_be_made_fails_as_a_writer_error() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())
        let nowhere = sandbox.directory.appendingPathComponent("missing/export.mp4")
        let exporter = OverlayVideoExporter(diskSpace: FakeDiskSpace(available: nil))

        let error = await failure(of: exporter.export(plan, overlay: try await overlay(), to: nowhere))

        guard case .writerFailed = error else {
            Issue.record("expected a writer failure, got \(String(describing: error))")
            return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path) == ["footage.mp4"])
    }

    // MARK: - Production seams

    /// The production disk-space check reads the volume's free space.
    @Test func test_the_volume_reports_its_free_space() throws {
        let available = try VolumeDiskSpace().availableCapacity(for: FileManager.default.temporaryDirectory)

        #expect((available ?? 0) > 0)
    }

    /// By default the scratch file is written on the destination's volume and
    /// removed afterwards: only the export is left in the destination folder.
    @Test func test_the_default_scratch_directory_is_removed() async throws {
        let sandbox = try ExportSandbox()
        defer { sandbox.remove() }
        let plan = try await exportPlan(try await sandbox.footage())

        _ = try await collect(OverlayVideoExporter().export(plan, overlay: try await overlay(),
                                                            to: sandbox.destination))

        let left = try FileManager.default.contentsOfDirectory(atPath: sandbox.directory.path).sorted()
        #expect(left == ["export.mp4", "footage.mp4"])
    }
}
