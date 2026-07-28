#if canImport(RaceStudioFFIBindings)
import SwiftUI
import RaceStudioCore
import RaceStudioFFIBindings

/// The MyChron device panel (issue 6.7) — a thin SwiftUI shell over the tested
/// ``DevicePanelModel`` state machine in `RaceStudioCore`. This view holds no
/// logic (it only renders whichever ``DevicePanelState`` is current and forwards
/// button taps to the model), so it lives in the coverage-excluded `@main`
/// target. All behaviour is exercised by `DevicePanelModelTests`.
struct DevicePanelView: View {
    @StateObject private var model: DevicePanelModel
    /// The name the user re-types to confirm a destructive delete (issue 6.6).
    @State private var typedName = ""
    /// The active locale (issue 7.3) — drives the localized control labels, and
    /// honours a SwiftUI `\.locale` override in previews/tests.
    @Environment(\.locale) private var locale
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    /// Inject a model (used by previews/tests-of-the-shell).
    init(model: DevicePanelModel) {
        _model = StateObject(wrappedValue: model)
    }

    /// The app's entry point: drive the live 6.3–6.6 adapter.
    init() {
        _model = StateObject(wrappedValue: DevicePanelModel(service: LiveDeviceService()))
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .task {
                if case .idle = model.state { await model.loadDevices() }
            }
            .sheet(isPresented: deleteDialogShown) { deleteConfirmationSheet }
    }

    // MARK: - state → view

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .discovering:
            BrandLoadingView("Looking for MyChron devices…")
        case let .devices(devices):
            deviceList(devices)
        case let .enumerating(device):
            BrandLoadingView("Reading sessions from \(device.name)…")
        case let .sessions(device, sessions), let .confirmingDeletion(device, sessions, _):
            // The delete-confirmation sheet overlays the session table, so both
            // states render the same underlying table.
            sessionTable(device, sessions)
        case let .downloading(_, session, progress):
            BrandLoadingView("Downloading \(session.name)…", value: progress)
        case let .deleting(_, session):
            BrandLoadingView("Deleting \(session.name)…")
        case let .downloaded(_, session, data):
            BrandStateView(role: .success, symbol: "checkmark.circle.fill",
                           title: "Downloaded \(session.name)",
                           message: "\(data.count) bytes ready to import.",
                           actionLabel: "Done", action: { model.reset() })
        case let .failed(message):
            BrandStateView(role: .error, symbol: "exclamationmark.triangle.fill",
                           title: "Something went wrong",
                           message: message,
                           actionLabel: "Done", action: { model.reset() })
        }
    }

    private func deviceList(_ devices: [Device]) -> some View {
        Group {
            if devices.isEmpty {
                BrandStateView(symbol: "wifi.slash", title: "No MyChron devices found",
                               message: "Make sure the logger is powered on and on the same Wi-Fi network.")
            } else {
                List(devices, id: \.address) { device in
                    Button { Task { await model.select(device) } } label: {
                        VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                            Text(device.name)
                                .font(.token(theme.typography.headline))
                                .foregroundStyle(theme.palette.textPrimary.color(scheme))
                            Text("\(device.address):\(String(device.port)) · \(device.model)")
                                .font(.token(theme.typography.caption))
                                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func sessionTable(_ device: Device, _ sessions: [SessionInfo]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack {
                Text(device.name)
                    .font(.token(theme.typography.title))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                Button("Devices") { Task { await model.loadDevices() } }
            }
            if sessions.isEmpty {
                BrandStateView(symbol: "tray", title: "No sessions on this device")
            } else {
                List(sessions, id: \.id) { session in
                    HStack {
                        VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                            Text(session.name)
                                .font(.token(theme.typography.headline))
                                .foregroundStyle(theme.palette.textPrimary.color(scheme))
                            Text("\(session.lapCount) laps · \(session.sizeBytes) bytes")
                                .font(.token(theme.typography.caption))
                                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                        }
                        Spacer()
                        Button(ControlLabel.downloadSession.label(locale: locale)) {
                            Task { await model.download(session) }
                        }
                        Button(role: .destructive) {
                            typedName = ""
                            model.requestDeletion(of: session)
                        } label: { Text(ControlLabel.deleteSession.label(locale: locale)) }
                    }
                }
            }
        }
    }

    // MARK: - guarded delete dialog (issue 6.6)

    private var deleteDialogShown: Binding<Bool> {
        Binding(
            get: { model.pendingDeletion != nil },
            set: { shown in if !shown { model.cancelDeletion() } }
        )
    }

    @ViewBuilder
    private var deleteConfirmationSheet: some View {
        if let target = model.pendingDeletion {
            VStack(alignment: .leading, spacing: theme.spacing.md) {
                Text("Delete “\(target.name)”?")
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Text("This permanently erases the session from the device and cannot be undone. "
                    + "Type the session name to confirm.")
                    .font(.token(theme.typography.callout))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
                TextField("Session name", text: $typedName)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Spacer()
                    Button("Cancel") { model.cancelDeletion() }
                    Button(ControlLabel.deleteSession.label(locale: locale), role: .destructive) {
                        Task { await model.confirmDeletion(typedName: typedName) }
                    }
                    // The guarded API is unreachable until the typed name matches
                    // exactly — the UI cannot bypass the confirmation.
                    .disabled(typedName != target.name)
                }
            }
            .padding()
            .frame(width: 360)
        }
    }
}

/// The live ``DeviceService`` binding the panel to the real 6.3–6.6 APIs.
///
/// Discovery uses the real ``BonjourBrowser`` (issue 6.3). Live session
/// enumeration/download/delete need an `NWConnection` transport that is out of
/// scope for 6.7 ("no new networking") and awaits a session-present capture
/// (#130); until then enumeration reports an empty catalog (the recorded reality)
/// and a transfer surfaces a clear, typed error rather than pretending to run.
struct LiveDeviceService: DeviceService {
    func discover() async throws -> [Device] {
        try await discoverDevices(using: BonjourBrowser())
    }

    func enumerateSessions(on device: Device) async throws -> [SessionInfo] {
        // The 6.4 parse path is covered against recorded bytes, but live catalog
        // enumeration needs an NWConnection transport that is out of 6.7 scope
        // ("no new networking", #130). Surface that honestly rather than returning
        // an empty catalog, which would masquerade as "device has no sessions".
        throw DiscoveryError.NoService(
            message: "Live session enumeration needs a connected device transport (tracked in #130).")
    }

    func download(
        _ session: SessionInfo,
        from device: Device,
        onProgress: @Sendable (Double) async -> Void
    ) async throws -> Data {
        throw DiscoveryError.NoService(
            message: "Live session download needs a connected device transport (tracked in #130).")
    }

    func delete(
        _ target: SessionInfo,
        confirmation: DeleteConfirmation?,
        armed: Bool,
        from device: Device
    ) async throws {
        throw DiscoveryError.NoService(
            message: "Live session delete needs a connected device transport (tracked in #130).")
    }
}
#endif
