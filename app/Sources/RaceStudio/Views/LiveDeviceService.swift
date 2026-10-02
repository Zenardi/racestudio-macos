#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioCore
import RaceStudioFFIBindings

/// The live ``DeviceService``: the Rust download client over the Mac's Wi-Fi
/// (issue #179).
///
/// One connection is kept open while the panel works with a device, so a queue
/// of downloads runs in one conversation, as the AiM app does. Every FFI call
/// blocks on the network, so it runs on a background queue; the actor is free
/// meanwhile, which is what lets ``cancel()`` reach a download in flight. A
/// failed call drops the connection (the Rust side has already closed it), and
/// the next call reconnects.
///
/// The actor suspends while a connection opens, so every open is stamped with a
/// generation: ``cancel()`` and ``disconnect()`` bump it, and an open that
/// finishes under an older generation closes its link instead of keeping it.
/// A cancel that arrives while nothing is running therefore never leaves a dead
/// link cached, and one that arrives mid-connect still stops the download.
///
/// Logic-free glue over tested code (`DevicePanelModel`, the Rust client), so it
/// lives in the coverage-excluded app target.
actor LiveDeviceService: DeviceService {

    /// How long the discovery probe listens for replies.
    private static let discoveryTimeoutMs: UInt32 = 1_500

    private var connection: DeviceConnection?
    private var connectedDevice: Device?
    /// Bumped by every cancel and disconnect; see the type's notes.
    private var generation = 0

    func discover() async throws -> [Device] {
        try await Self.offMain { try discoverDevices(timeoutMs: Self.discoveryTimeoutMs) }
    }

    func enumerateSessions(on device: Device) async throws -> DeviceCatalog {
        let link = try await open(device)
        return try await call(link) { try link.listSessions() }
    }

    func download(
        _ session: DeviceSession,
        from device: Device,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Data {
        let link = try await open(device)
        let relay = ProgressRelay(onProgress)
        return try await call(link) { try link.download(fileName: session.fileName, progress: relay) }
    }

    func cancel() async {
        let link = forget()
        // Cancelling is final on the Rust side; the link is never reused.
        link?.cancel()
        if let link { await Self.offMain { link.close() } }
    }

    func disconnect() async {
        if let link = forget() { await Self.offMain { link.close() } }
    }

    // MARK: - Private

    /// The open connection to `device`, connecting (and closing any other) first.
    private func open(_ device: Device) async throws -> DeviceConnection {
        if let connection, connectedDevice == device { return connection }
        await disconnect()
        let stamp = generation
        let clock = DeviceClock(date: Date(), timeZone: .current)
        let link = try await Self.offMain { try DeviceConnection.connect(device: device, clock: clock) }
        guard generation == stamp, connection == nil else {
            // Cancelled, disconnected or superseded while connecting.
            await Self.offMain { link.close() }
            throw DiscoveryError.Cancelled(message: "the transfer was cancelled")
        }
        connection = link
        connectedDevice = device
        return link
    }

    /// Drop the cached link and bump the generation; returns the link to close.
    private func forget() -> DeviceConnection? {
        generation += 1
        let link = connection
        connection = nil
        connectedDevice = nil
        return link
    }

    /// Run `work` on `link`, forgetting the link when it fails for any reason
    /// other than a rejected file name (which leaves the conversation in step).
    private func call<T>(_ link: DeviceConnection, _ work: @escaping @Sendable () throws -> T) async throws -> T {
        do {
            return try await Self.offMain(work)
        } catch {
            if case .InvalidPath = error as? DiscoveryError {} else if connection === link {
                connection = nil
                connectedDevice = nil
            }
            throw error
        }
    }

    private static func offMain<T>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    private static func offMain(_ work: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                work()
                continuation.resume()
            }
        }
    }
}

/// Forwards the Rust client's byte progress as a 0…1 fraction.
private final class ProgressRelay: DownloadProgress, @unchecked Sendable {
    private let report: @Sendable (Double) async -> Void

    init(_ report: @escaping @Sendable (Double) async -> Void) {
        self.report = report
    }

    func onProgress(bytesDone: UInt64, total: UInt64) {
        guard total > 0 else { return }
        let fraction = Double(bytesDone) / Double(total)
        let report = report
        Task { await report(fraction) }
    }
}
#endif
