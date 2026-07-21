#if canImport(RaceStudioFFIBindings)
import Foundation
import RaceStudioFFIBindings

/// The device panel's state machine (issue 6.7).
///
/// A single enum carries the whole flow so illegal states are unrepresentable:
/// you cannot be `.downloading` without knowing *which* device and session, and
/// there is no way to reach `.deleting`/`.downloading`/`.confirmingDeletion`
/// except from `.sessions`. Crucially, an armed delete confirmation lives *inside*
/// the state (`.confirmingDeletion`) rather than beside it, so it is bound to the
/// exact device + session list it was armed against — navigating away structurally
/// drops it, and a confirmation can never be routed to a different device's slot.
/// The thin SwiftUI shell renders whichever case is current; every transition is
/// driven by ``DevicePanelModel`` methods that guard on the current case, so an
/// out-of-order action is a safe no-op rather than a corrupt state.
public enum DevicePanelState: Equatable {
    /// Nothing loaded yet — the panel's initial state.
    case idle
    /// Discovery is running.
    case discovering
    /// Devices were discovered (possibly empty → the "no devices" empty state).
    case devices([Device])
    /// A device was selected and its session catalog is being enumerated.
    case enumerating(Device)
    /// The device's session table (possibly empty → the "no sessions" empty
    /// state).
    case sessions(Device, [SessionInfo])
    /// A delete confirmation is armed for `target`, over the device + session-list
    /// snapshot it was armed against (issue 6.6). The guarded API is not called
    /// until the user re-types `target`'s exact name.
    case confirmingDeletion(Device, [SessionInfo], target: SessionInfo)
    /// A session download is in flight; `progress` advances 0.0 → 1.0.
    case downloading(Device, SessionInfo, progress: Double)
    /// A guarded delete is in flight (the confirmation already matched).
    case deleting(Device, SessionInfo)
    /// A download completed — `data` is the reassembled, checksum-verified `.xrk`
    /// ready to hand to the import pipeline.
    case downloaded(Device, SessionInfo, data: Data)
    /// A transfer/enumeration/discovery failed; the message is user-facing.
    case failed(String)
}

/// The device operations the panel drives (issues 6.3–6.6), behind a protocol so
/// the model is tested with an injected fake fed by recorded fixtures — no live
/// MyChron, no networking, in CI. The live adapter (which wires the real
/// discovery/enumeration/download/delete transports) lives in the excluded
/// `@main` shell; a session-present live path awaits a real capture (#130).
public protocol DeviceService: Sendable {
    /// Discover devices (issue 6.3) — never empty in the live path (falls back to
    /// the AP-mode gateway).
    func discover() async throws -> [Device]

    /// Enumerate the on-device session catalog (issue 6.4); an empty on-device
    /// store yields an empty array (never an error).
    func enumerateSessions(on device: Device) async throws -> [SessionInfo]

    /// Download a session (issue 6.5), reporting fractional progress (0.0 → 1.0)
    /// to `onProgress` as bytes arrive; returns the reassembled `.xrk` bytes.
    func download(
        _ session: SessionInfo,
        from device: Device,
        onProgress: @Sendable (Double) async -> Void
    ) async throws -> Data

    /// Delete a session behind the 6.6 guard: the guarded API refuses (sending
    /// zero bytes) unless `armed` is `true` **and** `confirmation` matches
    /// `target`. The panel only ever calls this with a matching, armed
    /// confirmation, so the UI cannot bypass the guard.
    func delete(
        _ target: SessionInfo,
        confirmation: DeleteConfirmation?,
        armed: Bool,
        from device: Device
    ) async throws
}

/// The observable model behind the device panel (issue 6.7).
///
/// It owns the ``DevicePanelState`` machine and drives the injected
/// ``DeviceService``. All mutation happens on the main actor so SwiftUI observes
/// a consistent state; the download progress callback hops back to the main
/// actor before touching state. Delete is doubly guarded: the model refuses to
/// call the 6.6 API unless the user re-typed the session's exact name, and it
/// passes a matching, armed ``DeleteConfirmation`` so the core guard also holds.
/// A running discovery/enumeration/transfer is never interrupted by a navigation
/// or reset (see ``isBusy``), so a stale completion can never clobber newer state.
@MainActor
public final class DevicePanelModel: ObservableObject {

    /// The current phase of the flow (drives the whole UI).
    @Published public private(set) var state: DevicePanelState = .idle

    private let service: DeviceService

    /// - Parameter service: the device operations to drive (a live adapter in the
    ///   app, an injected fake fed by fixtures in tests).
    public init(service: DeviceService) {
        self.service = service
    }

    /// The session awaiting a delete confirmation, or `nil` when no delete dialog
    /// is open — derived from the state so it can never drift out of sync with
    /// the device/session-list it was armed against.
    public var pendingDeletion: SessionInfo? {
        if case let .confirmingDeletion(_, _, target) = state { return target }
        return nil
    }

    /// `true` while an async operation (discovery/enumeration/transfer) or a delete
    /// confirmation is in progress. Navigation (``loadDevices()``) and ``reset()``
    /// are ignored while busy so an in-flight operation's result cannot be
    /// clobbered by — nor clobber — a concurrent transition.
    private var isBusy: Bool {
        switch state {
        case .discovering, .enumerating, .downloading, .deleting, .confirmingDeletion:
            return true
        default:
            return false
        }
    }

    /// Run discovery and list the found devices, or surface a typed error.
    /// Ignored while an operation is in flight.
    public func loadDevices() async {
        guard !isBusy else { return }
        state = .discovering
        do {
            state = .devices(try await service.discover())
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Select a discovered device and enumerate its session catalog. Ignored
    /// unless a device list is currently shown.
    public func select(_ device: Device) async {
        guard case .devices = state else { return }
        state = .enumerating(device)
        do {
            state = .sessions(device, try await service.enumerateSessions(on: device))
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Download `session`, advancing progress 0 → 100%, then surface the decoded
    /// bytes (or a typed error). Ignored unless a session table is shown.
    public func download(_ session: SessionInfo) async {
        guard case let .sessions(device, _) = state else { return }
        state = .downloading(device, session, progress: 0)
        do {
            let data = try await service.download(session, from: device) { fraction in
                await MainActor.run {
                    if case let .downloading(currentDevice, currentSession, _) = self.state {
                        self.state = .downloading(currentDevice, currentSession, progress: fraction)
                    }
                }
            }
            state = .downloaded(device, session, data: data)
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Arm the delete-confirmation dialog for `session` (nothing is sent yet).
    /// Ignored unless a session table is shown; the armed confirmation is bound to
    /// the current device + session list.
    public func requestDeletion(of session: SessionInfo) {
        guard case let .sessions(device, sessions) = state else { return }
        state = .confirmingDeletion(device, sessions, target: session)
    }

    /// Dismiss the delete-confirmation dialog without deleting — sends nothing and
    /// returns to the session table it was armed over.
    public func cancelDeletion() {
        guard case let .confirmingDeletion(device, sessions, _) = state else { return }
        state = .sessions(device, sessions)
    }

    /// Confirm the pending delete. The guarded 6.6 API is called **only** when
    /// `typedName` exactly matches the target session's name; a mismatch sends
    /// nothing and leaves the dialog open. Because the device + session list come
    /// from the `.confirmingDeletion` snapshot, the delete can only ever target the
    /// session the dialog was armed against. On success the session is dropped from
    /// the table; a device rejection surfaces as an error.
    public func confirmDeletion(typedName: String) async {
        guard case let .confirmingDeletion(device, sessions, target) = state else { return }
        guard typedName == target.name else { return }

        state = .deleting(device, target)
        let confirmation = DeleteConfirmation(sessionId: target.id, expectedName: target.name)
        do {
            try await service.delete(target, confirmation: confirmation, armed: true, from: device)
            state = .sessions(device, sessions.filter { $0 != target })
        } catch {
            state = .failed(Self.message(for: error))
        }
    }

    /// Return to the initial state (the panel's "start over"/close action).
    /// Ignored while an operation is in flight.
    public func reset() {
        guard !isBusy else { return }
        state = .idle
    }

    /// A clean, user-facing message for a failure. ``DiscoveryError``'s generated
    /// `errorDescription` is a `String(reflecting:)` debug dump, so extract its
    /// carried message; any other error falls back to `localizedDescription`.
    private static func message(for error: Error) -> String {
        guard let discovery = error as? DiscoveryError else { return error.localizedDescription }
        switch discovery {
        case let .MalformedRecord(message), let .NoService(message), let .BadChecksum(message),
             let .TruncatedList(message), let .ChecksumMismatch(message), let .MissingChunk(message),
             let .ConfirmationMismatch(message), let .NotArmed(message), let .DeleteRejected(message):
            return message
        }
    }
}
#endif
