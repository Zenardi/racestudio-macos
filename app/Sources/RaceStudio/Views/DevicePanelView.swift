#if canImport(RaceStudioFFIBindings)
import SwiftUI
import RaceStudioCore
import RaceStudioFFIBindings

/// The MyChron device window (issues 6.7, #179) — a thin SwiftUI shell over the
/// tested ``DevicePanelModel`` state machine in `RaceStudioCore`. It renders the
/// current ``DevicePanelState`` and forwards actions; all behaviour is exercised
/// by `DevicePanelModelTests`, so it lives in the coverage-excluded app target.
struct DevicePanelView: View {
    @ObservedObject var model: DevicePanelModel
    /// The rows ticked in the session table, by file name.
    @State private var selection = Set<DeviceSession.ID>()
    @Environment(\.locale) private var locale
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .task {
                if case .idle = model.state { await model.loadDevices() }
            }
            .onDisappear { Task { await model.close() } }
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
        case let .sessions(device, sessions):
            sessionTable(device, sessions)
        case let .downloading(_, _, progress):
            BrandLoadingView(
                "Downloading \(DeviceSessionText.track(progress.session)), "
                    + "\(DeviceSessionText.date(progress.session)) "
                    + "(\(progress.position) of \(progress.count))…",
                value: progress.fraction,
                cancel: { Task { await model.cancelDownload() } })
        case let .finished(_, _, report):
            reportView(report)
        case let .failed(message):
            BrandStateView(role: .error, symbol: "exclamationmark.triangle.fill",
                           title: "Couldn’t reach the MyChron",
                           message: message,
                           actionLabel: "Try Again",
                           action: { model.reset(); Task { await model.loadDevices() } })
        }
    }

    private func deviceList(_ devices: [Device]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack {
                Text("MyChron devices")
                    .font(.token(theme.typography.title))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                Button("Search Again") { Task { await model.loadDevices() } }
            }
            if !model.onDeviceNetwork {
                Label(DevicePanelModel.joinNetworkHint, systemImage: "wifi.exclamationmark")
                    .font(.token(theme.typography.callout))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
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

    private func sessionTable(_ device: Device, _ sessions: [DeviceSession]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            HStack {
                Text(device.name)
                    .font(.token(theme.typography.title))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Spacer()
                Button("Refresh") { Task { await model.refresh() } }
                Button("Devices") { Task { await model.loadDevices() } }
            }
            if sessions.isEmpty {
                BrandStateView(symbol: "tray", title: "No sessions on this device")
            } else {
                Table(sessions, selection: $selection) {
                    TableColumn("Date") { Text(DeviceSessionText.date($0)) }
                    TableColumn("Track") { Text(DeviceSessionText.track($0)) }
                    TableColumn("Laps") { Text("\($0.lapCount)") }.width(40)
                    TableColumn("Best lap") { Text(DeviceSessionText.bestLap($0)) }
                    TableColumn("Duration") { Text(DeviceSessionText.duration($0)) }.width(70)
                    TableColumn("Size") { Text(DeviceSessionText.size($0)) }.width(70)
                    TableColumn("Driver") { Text($0.driver) }
                }
                HStack {
                    Text("Downloads are copied into your library. Sessions stay on the device.")
                        .font(.token(theme.typography.caption))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                    Spacer()
                    Button("Select All") { selection = Set(sessions.map(\.id)) }
                    // Only rows still in this table count: a selection can
                    // outlive a Refresh or a switch of device.
                    let chosen = sessions.filter { selection.contains($0.id) }
                    Button(downloadLabel(count: chosen.count)) {
                        Task { await model.download(chosen) }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func downloadLabel(count: Int) -> String {
        let base = ControlLabel.downloadSession.label(locale: locale)
        return count > 1 ? "\(base) (\(count))" : base
    }

    private func reportView(_ report: DownloadReport) -> some View {
        let imported = report.imported.count
        let title = report.failed.isEmpty && report.notDownloaded.isEmpty
            ? "Downloaded \(imported) session\(imported == 1 ? "" : "s") to your library"
            : "Downloaded \(imported) of \(imported + report.retryable.count) sessions"
        var lines = report.failed.map { "\(DeviceSessionText.date($0.session)): \($0.message)" }
        if !report.notDownloaded.isEmpty {
            lines.append("\(report.notDownloaded.count) not downloaded (cancelled).")
        }
        return VStack(spacing: theme.spacing.md) {
            BrandStateView(role: report.failed.isEmpty ? .success : .error,
                           symbol: report.failed.isEmpty ? "checkmark.circle.fill"
                                                         : "exclamationmark.triangle.fill",
                           title: title,
                           message: lines.isEmpty ? nil : lines.joined(separator: "\n"))
            HStack {
                Button("Back to Sessions") { selection = []; model.showSessions() }
                if !report.retryable.isEmpty {
                    Button("Retry \(report.retryable.count)") { Task { await model.retry() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }
}
#endif
