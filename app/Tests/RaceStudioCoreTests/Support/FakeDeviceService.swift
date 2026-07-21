#if canImport(RaceStudioFFIBindings)
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// One recorded guarded-delete call, captured by ``FakeDeviceService`` so the
/// refusal paths can assert **zero** device traffic and the confirm path can
/// assert the guard arguments — including the *device* the delete was routed to,
/// which pins the "confirmation is bound to the armed device" safety property
/// (issue 6.6/6.7).
struct DeleteCall {
    let target: SessionInfo
    let confirmation: DeleteConfirmation?
    let armed: Bool
    let device: Device
}

/// A `DeviceService` fake driving ``DevicePanelModel`` in tests (issue 6.7):
/// immutable scripted results + lock-protected spies that record the
/// download/delete calls. `@unchecked Sendable` with an `NSLock` matches the
/// established fake pattern in this suite (`SpyChannel`, `RecordedChunkSource`);
/// the lock is only ever taken inside **synchronous** helpers (never lexically
/// across an `await`).
final class FakeDeviceService: DeviceService, @unchecked Sendable {
    private let devicesResult: Result<[Device], Error>
    private let sessionsResult: Result<[SessionInfo], Error>
    private let downloadResult: Result<Data, Error>
    private let progressSequence: [Double]
    private let deleteResult: Result<Void, Error>

    private let lock = NSLock()
    private var recordedDownloads: [SessionInfo] = []
    private var recordedDeletes: [DeleteCall] = []

    init(
        devices: Result<[Device], Error> = .success([]),
        sessions: Result<[SessionInfo], Error> = .success([]),
        download: Result<Data, Error> = .success(Data()),
        progress: [Double] = [1.0],
        delete: Result<Void, Error> = .success(())
    ) {
        devicesResult = devices
        sessionsResult = sessions
        downloadResult = download
        progressSequence = progress
        deleteResult = delete
    }

    func discover() async throws -> [Device] { try devicesResult.get() }

    func enumerateSessions(on device: Device) async throws -> [SessionInfo] {
        try sessionsResult.get()
    }

    func download(
        _ session: SessionInfo,
        from device: Device,
        onProgress: @Sendable (Double) async -> Void
    ) async throws -> Data {
        recordDownload(session)
        for fraction in progressSequence { await onProgress(fraction) }
        return try downloadResult.get()
    }

    func delete(
        _ target: SessionInfo,
        confirmation: DeleteConfirmation?,
        armed: Bool,
        from device: Device
    ) async throws {
        recordDelete(DeleteCall(target: target, confirmation: confirmation, armed: armed, device: device))
        try deleteResult.get()
    }

    // Synchronous, lock-protected recorders — kept out of the `async` bodies so
    // `NSLock` is never taken across a suspension point.
    private func recordDownload(_ session: SessionInfo) {
        lock.lock(); defer { lock.unlock() }
        recordedDownloads.append(session)
    }

    private func recordDelete(_ call: DeleteCall) {
        lock.lock(); defer { lock.unlock() }
        recordedDeletes.append(call)
    }

    var downloadCalls: [SessionInfo] {
        lock.lock(); defer { lock.unlock() }
        return recordedDownloads
    }

    var deleteCalls: [DeleteCall] {
        lock.lock(); defer { lock.unlock() }
        return recordedDeletes
    }
}
#endif
