#if canImport(RaceStudioFFIBindings)
import Foundation
@testable import RaceStudioCore
import RaceStudioFFIBindings

/// A `DeviceService` fake driving ``DevicePanelModel`` in tests (issues 6.7,
/// #179): scripted results plus lock-protected spies. `@unchecked Sendable` with
/// an `NSLock` matches the established fake pattern in this suite; the lock is
/// only ever taken inside **synchronous** helpers, never across an `await`.
///
/// With `holdsDownloads`, every download waits until ``cancel()`` and then
/// throws the device's `Cancelled`, as the live client does when its socket is
/// shut mid-transfer. A cancel is *consumed* by the download it stops — one
/// that arrives just before the download holds still stops it (it is never
/// lost, which would leave the download waiting forever), and a later download
/// (a retry) holds again.
final class FakeDeviceService: DeviceService, @unchecked Sendable {
    private let devicesResult: Result<[Device], Error>
    private let catalogResult: Result<DeviceCatalog, Error>
    private let failures: [String: Error]
    private let progressSequence: [Double]
    private let holdsDownloads: Bool

    private let lock = NSLock()
    private var recordedDownloads: [String] = []
    private var cancels = 0
    private var disconnects = 0
    private var cancelled = false
    private var waiter: CheckedContinuation<Void, Never>?

    init(
        devices: Result<[Device], Error> = .success([]),
        catalog: Result<DeviceCatalog, Error> = .success(DeviceCatalog(sessions: [], skippedRows: 0)),
        failures: [String: Error] = [:],
        progress: [Double] = [1.0],
        holdsDownloads: Bool = false
    ) {
        devicesResult = devices
        catalogResult = catalog
        self.failures = failures
        progressSequence = progress
        self.holdsDownloads = holdsDownloads
    }

    func discover() async throws -> [Device] { try devicesResult.get() }

    func enumerateSessions(on device: Device) async throws -> DeviceCatalog {
        try catalogResult.get()
    }

    func download(
        _ session: DeviceSession,
        from device: Device,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Data {
        record(session.fileName)
        for fraction in progressSequence { await onProgress(fraction) }
        if holdsDownloads {
            await withCheckedContinuation { hold($0) }
            throw DiscoveryError.Cancelled(message: "the transfer was cancelled")
        }
        if let failure = failures[session.fileName] { throw failure }
        return Data(session.fileName.utf8)
    }

    func cancel() async {
        let waiting = markCancelled()
        waiting?.resume()
    }

    func disconnect() async {
        lock.lock(); defer { lock.unlock() }
        disconnects += 1
    }

    // Synchronous, lock-protected helpers.

    /// Records a download.
    private func record(_ fileName: String) {
        lock.lock(); defer { lock.unlock() }
        recordedDownloads.append(fileName)
    }

    /// Holds the download until a cancel, or ends it at once — consuming the
    /// cancel — when one already arrived.
    private func hold(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if cancelled {
            cancelled = false
            lock.unlock()
            continuation.resume()
        } else {
            // The model downloads one session at a time; a second held download
            // would leak the first continuation.
            precondition(waiter == nil, "two downloads held at once")
            waiter = continuation
            lock.unlock()
        }
    }

    /// Counts a cancel and releases the held download, consuming the cancel;
    /// with none held, the cancel waits for the next download.
    private func markCancelled() -> CheckedContinuation<Void, Never>? {
        lock.lock(); defer { lock.unlock() }
        cancels += 1
        let waiting = waiter
        waiter = nil
        cancelled = waiting == nil
        return waiting
    }

    /// Whether a download is being held — what a test waits for before it
    /// cancels mid-transfer.
    var isHolding: Bool {
        lock.lock(); defer { lock.unlock() }
        return waiter != nil
    }

    var downloadCalls: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedDownloads
    }

    var cancelCount: Int {
        lock.lock(); defer { lock.unlock() }
        return cancels
    }

    var disconnectCount: Int {
        lock.lock(); defer { lock.unlock() }
        return disconnects
    }
}

/// A ``DownloadedSessionImporting`` spy: records each import, and fails the
/// sessions named in `failing`.
@MainActor
final class FakeSessionImporter: DownloadedSessionImporting {
    struct ImportFailed: Error, LocalizedError {
        var errorDescription: String? { "the session could not be decoded" }
    }

    private let failing: Set<String>
    private(set) var imported: [(data: Data, session: DeviceSession)] = []

    init(failing: Set<String> = []) {
        self.failing = failing
    }

    func importDownloaded(_ data: Data, for session: DeviceSession) async throws {
        if failing.contains(session.fileName) { throw ImportFailed() }
        imported.append((data, session))
    }
}
#endif
