#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// The device panel's state machine (issues 6.7, #179).
///
/// A single enum carries the whole flow so illegal states are unrepresentable:
/// you cannot be `.downloading` without knowing which device and which queue,
/// and a download can only start from a session table. Every transition is
/// driven by a ``DevicePanelModel`` method that guards on the current case, so
/// an out-of-order action is a safe no-op rather than a corrupt state.
///
/// The panel only ever **reads** from the device: there is no delete here. The
/// delete opcode has never been captured (#130), so offering it would mean
/// sending a guessed write command to the user's logger.
public enum DevicePanelState: Equatable {
    /// Nothing loaded yet — the panel's initial state.
    case idle
    /// Discovery is running.
    case discovering
    /// Devices were discovered.
    case devices([Device])
    /// A device was selected and its catalog is being read.
    case enumerating(Device)
    /// The sessions stored on the device (possibly none).
    case sessions(Device, [DeviceSession])
    /// A queue of sessions is downloading; `sessions` is the table to return to.
    case downloading(Device, [DeviceSession], DownloadProgressState)
    /// A queue finished (completely, partly, or cancelled).
    case finished(Device, [DeviceSession], DownloadReport)
    /// Discovery or the catalog read failed; the message is user-facing.
    case failed(String)
}

/// Where a running download queue is.
public struct DownloadProgressState: Equatable {
    /// The session downloading now.
    public let session: DeviceSession
    /// Its 1-based position in the queue.
    public let position: Int
    /// How many sessions the queue holds.
    public let count: Int
    /// This session's progress, 0.0 → 1.0.
    public let fraction: Double
}

/// A session that could not be downloaded or imported.
public struct DownloadFailure: Equatable {
    /// The session.
    public let session: DeviceSession
    /// Why, in words for the user.
    public let message: String
}

/// The outcome of a download queue.
public struct DownloadReport: Equatable {
    /// Sessions now in the library.
    public let imported: [DeviceSession]
    /// Sessions that failed, with the reason.
    public let failed: [DownloadFailure]
    /// Sessions not downloaded because the queue was cancelled.
    public let notDownloaded: [DeviceSession]

    /// Everything a retry should queue again.
    public var retryable: [DeviceSession] { failed.map(\.session) + notDownloaded }
}

/// The device operations the panel drives, behind a protocol so the model is
/// tested with an injected fake — no live MyChron, no networking, in CI. The
/// live adapter lives in the app shell.
public protocol DeviceService: Sendable {
    /// Discover devices — never empty in the live path (falls back to the
    /// access-point gateway).
    func discover() async throws -> [Device]

    /// Read the device's catalog of stored sessions.
    func enumerateSessions(on device: Device) async throws -> DeviceCatalog

    /// Download `session` and return its `.xrk` bytes, reporting fractional
    /// progress (0.0 → 1.0) as chunks arrive.
    func download(
        _ session: DeviceSession,
        from device: Device,
        onProgress: @escaping @Sendable (Double) async -> Void
    ) async throws -> Data

    /// Stop the download in progress; it then throws.
    func cancel() async

    /// Close any open connection (the panel was closed or went back to the
    /// device list).
    func disconnect() async
}

/// The observable model behind the device panel (issues 6.7, #179).
///
/// It owns the ``DevicePanelState`` machine, drives the injected
/// ``DeviceService``, and hands each downloaded session to the injected
/// ``DownloadedSessionImporting`` so it lands in the library. Downloads run one
/// after another; a failure is recorded and the queue moves on, a cancel stops
/// it, and the report offers the failed and skipped sessions for a retry.
@MainActor
public final class DevicePanelModel: ObservableObject {

    /// The current phase of the flow (drives the whole UI).
    @Published public private(set) var state: DevicePanelState = .idle

    /// Whether the Mac looked joined to a MyChron's own Wi-Fi at the last
    /// search. When it is not, the panel says how to join it.
    @Published public private(set) var onDeviceNetwork = true

    private let service: DeviceService
    private let importer: DownloadedSessionImporting
    private let isOnDeviceNetwork: @MainActor () -> Bool
    private var cancelRequested = false

    /// - Parameters:
    ///   - service: the device operations (a live adapter in the app, a fake in
    ///     tests).
    ///   - importer: puts each downloaded session into the library.
    ///   - isOnDeviceNetwork: whether the Mac is joined to a MyChron's Wi-Fi.
    public init(service: DeviceService, importer: DownloadedSessionImporting,
                isOnDeviceNetwork: @escaping @MainActor () -> Bool = { true }) {
        self.service = service
        self.importer = importer
        self.isOnDeviceNetwork = isOnDeviceNetwork
    }

    /// `true` while discovery, a catalog read or a download queue is running;
    /// navigation and ``reset()`` are ignored then, so a stale completion can
    /// never clobber newer state.
    private var isBusy: Bool {
        switch state {
        case .discovering, .enumerating, .downloading:
            return true
        default:
            return false
        }
    }

    /// Close any connection and search for devices again.
    public func loadDevices() async {
        guard !isBusy else { return }
        state = .discovering
        await service.disconnect()
        onDeviceNetwork = isOnDeviceNetwork()
        do {
            state = .devices(try await service.discover())
        } catch {
            state = .failed(message(for: error))
        }
    }

    /// Connect to `device` and read its catalog. Ignored unless the device list
    /// is shown.
    public func select(_ device: Device) async {
        guard case .devices = state else { return }
        await enumerate(device)
    }

    /// Read the catalog again (after downloads, or to pick up a new session).
    /// Ignored unless a session table or a finished report is shown.
    public func refresh() async {
        switch state {
        case let .sessions(device, _), let .finished(device, _, _):
            await enumerate(device)
        default:
            return
        }
    }

    /// Download `sessions` one after another, importing each into the library.
    /// Ignored unless a session table or a finished report is shown, or when
    /// nothing is selected.
    public func download(_ sessions: [DeviceSession]) async {
        guard !sessions.isEmpty, let (device, table) = currentTable else { return }
        cancelRequested = false
        var imported: [DeviceSession] = []
        var failed: [DownloadFailure] = []
        var remaining = sessions[...]

        for (offset, session) in sessions.enumerated() where !cancelRequested {
            state = .downloading(device, table, DownloadProgressState(
                session: session, position: offset + 1, count: sessions.count, fraction: 0))
            do {
                let data = try await service.download(session, from: device) { fraction in
                    await self.progressed(fraction, for: session)
                }
                try await importer.importDownloaded(data, for: session)
                imported.append(session)
            } catch where cancelRequested || error is CancellationError {
                break
            } catch {
                failed.append(DownloadFailure(session: session, message: message(for: error)))
            }
            remaining = remaining.dropFirst()
        }
        state = .finished(device, table, DownloadReport(
            imported: imported, failed: failed, notDownloaded: Array(remaining)))
    }

    /// Stop the running download queue. A session still downloading is not
    /// imported and is reported, with the rest of the queue, as not downloaded;
    /// one already importing finishes its import.
    public func cancelDownload() async {
        guard case .downloading = state else { return }
        cancelRequested = true
        await service.cancel()
    }

    /// Queue the failed and skipped sessions of the last report again.
    public func retry() async {
        guard case let .finished(_, _, report) = state else { return }
        await download(report.retryable)
    }

    /// Leave a finished report and return to the session table.
    public func showSessions() {
        guard case let .finished(device, table, _) = state else { return }
        state = .sessions(device, table)
    }

    /// The window closed: stop any download in flight and close the connection,
    /// so the logger is not left holding an idle conversation.
    public func close() async {
        await cancelDownload()
        await service.disconnect()
    }

    /// Return to the initial state. Ignored while an operation is in flight.
    public func reset() {
        guard !isBusy else { return }
        state = .idle
    }

    // MARK: - Private

    private var currentTable: (Device, [DeviceSession])? {
        switch state {
        case let .sessions(device, table), let .finished(device, table, _):
            return (device, table)
        default:
            return nil
        }
    }

    private func enumerate(_ device: Device) async {
        state = .enumerating(device)
        do {
            state = .sessions(device, try await service.enumerateSessions(on: device).sessions)
        } catch {
            state = .failed(message(for: error))
        }
    }

    private func progressed(_ fraction: Double, for session: DeviceSession) {
        guard case let .downloading(device, table, progress) = state,
              progress.session == session else { return }
        state = .downloading(device, table, DownloadProgressState(
            session: session, position: progress.position, count: progress.count,
            fraction: max(progress.fraction, min(max(fraction, 0), 1))))
    }

    /// A user-facing message for a failure. A link that failed while the Mac is
    /// not on a MyChron's Wi-Fi gets the instruction to join it.
    private func message(for error: Error) -> String {
        guard let discovery = error as? DiscoveryError else { return error.localizedDescription }
        switch discovery {
        case .ConnectionFailed, .Timeout, .ConnectionClosed:
            let problem = Self.linkProblem(discovery)
            return onDeviceNetwork ? problem : "\(problem) \(Self.joinNetworkHint)"
        case .Cancelled:
            return "The transfer was cancelled."
        case let .MalformedRecord(message), let .NoService(message), let .BadChecksum(message),
             let .TruncatedList(message), let .ChecksumMismatch(message), let .MissingChunk(message),
             let .ConfirmationMismatch(message), let .NotArmed(message), let .DeleteRejected(message),
             let .CorruptArchive(message), let .UnexpectedResponse(message), let .InvalidPath(message):
            return message
        }
    }

    private static func linkProblem(_ error: DiscoveryError) -> String {
        switch error {
        case .Timeout: return "The MyChron stopped responding."
        case .ConnectionClosed: return "The MyChron closed the connection."
        default: return "Couldn’t connect to the MyChron."
        }
    }

    /// How to get the Mac onto the logger's own network.
    public static let joinNetworkHint =
        "Join the MyChron’s Wi-Fi network (named AiM-MYC…) from the Wi-Fi menu, then try again."
}
#endif
