import SwiftUI
import AppKit
import RaceStudioCore

/// The app's **Home / dashboard** startup page: a brand-tokenized landing shown
/// when RaceStudio opens, so a user sees their library at a glance and — first run
/// or returning — knows exactly how to start and how to analyze.
///
/// Thin, like the rest of the shell: the onboarding copy (``StartGuide``) and the
/// at-a-glance stats (``LibraryDashboard``) come from `RaceStudioCore`; this view
/// only lays them out with the ``Theme`` tokens and wires the quick actions. The
/// leaf rows are extracted into small `View` structs so a re-render of the page
/// doesn't rebuild every tile, and the dashboard/recent scan is memoized so it
/// runs only when the library actually changes — not on every re-render.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var library: LibraryBrowserModel
    private let onImport: () -> Void
    private let onBrowseLibrary: () -> Void
    private let onOpen: (SessionSummary) -> Void

    /// Memoized from the *unfiltered* library. Seeded in `init` (so a returning
    /// user never sees a flash of the empty-library state) and refreshed by
    /// `onChange` only when `allSessions` actually changes.
    @State private var dashboard: LibraryDashboard
    @State private var recent: [SessionSummary]

    init(library: LibraryBrowserModel,
         onImport: @escaping () -> Void,
         onBrowseLibrary: @escaping () -> Void,
         onOpen: @escaping (SessionSummary) -> Void) {
        _library = ObservedObject(wrappedValue: library)
        self.onImport = onImport
        self.onBrowseLibrary = onBrowseLibrary
        self.onOpen = onOpen
        _dashboard = State(initialValue: LibraryDashboard(sessions: library.allSessions))
        _recent = State(initialValue: Array(library.allSessions.prefix(6)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing.xl) {
                hero
                if dashboard.isEmpty {
                    firstRun
                } else {
                    statsRow
                    recentSessions
                }
                tipSection(title: "How to start", tips: StartGuide.gettingStarted)
                tipSection(title: "How to analyze", tips: StartGuide.analysisTips)
            }
            .padding(theme.spacing.xxl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .brandCanvas()
        .onChange(of: library.allSessions) { newSessions in
            dashboard = LibraryDashboard(sessions: newSessions)
            recent = Array(newSessions.prefix(6))
        }
    }

    // MARK: - Hero + quick actions

    private var hero: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(spacing: theme.spacing.md) {
                // The app's own icon (the 7.4 AppIcon wired into the bundle),
                // rendered from the running app rather than a generic symbol.
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 44, height: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                    Text("RaceStudio")
                        .font(.token(theme.typography.largeTitle))
                        .foregroundStyle(theme.palette.textPrimary.color(scheme))
                    Text("Telemetry analysis for AiM loggers")
                        .font(.token(theme.typography.callout))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                }
            }
            HStack(spacing: theme.spacing.sm) {
                Button(action: onImport) {
                    Label("Import Session", systemImage: "square.and.arrow.down")
                        .foregroundStyle(theme.palette.onAccent.color(scheme))
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.palette.accent.color(scheme))
                Button(action: onBrowseLibrary) { Label("Browse Library", systemImage: "square.grid.2x2") }
                    .buttonStyle(.bordered)
                    .tint(theme.palette.accent.color(scheme))
            }
        }
    }

    // MARK: - First-run (empty library)

    private var firstRun: some View {
        BrandStateView(symbol: "tray",
                       title: "Your library is empty",
                       message: "Import a .xrk / .xrz telemetry file to get started — "
                              + "then open it to explore laps, channels, and the racing line.",
                       actionLabel: "Import a session…", action: onImport)
        .frame(minHeight: 200)
        .brandGlassCard(cornerRadius: theme.radius.lg)
    }

    // MARK: - Dashboard stat tiles

    private var statsRow: some View {
        HStack(spacing: theme.spacing.md) {
            HomeStatTile(symbol: "square.stack.3d.up", value: "\(dashboard.sessionCount)", label: "Sessions")
            HomeStatTile(symbol: "mappin.and.ellipse", value: "\(dashboard.venueCount)", label: "Venues")
            HomeStatTile(symbol: "car.side", value: "\(dashboard.vehicleCount)", label: "Vehicles")
            HomeStatTile(symbol: "timer", value: "\(dashboard.totalLaps)", label: "Laps")
        }
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            sectionHeader("Recent sessions")
            VStack(spacing: theme.spacing.xs) {
                ForEach(recent) { summary in
                    Button { onOpen(summary) } label: { HomeRecentRow(summary: summary) }
                        .buttonStyle(.plain)
                        .disabled(!summary.isAvailable)
                }
            }
        }
    }

    // MARK: - Tip sections

    private func tipSection(title: String, tips: [StartTip]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            sectionHeader(title)
            VStack(spacing: theme.spacing.sm) {
                ForEach(tips) { tip in HomeTipRow(tip: tip) }
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.token(theme.typography.title))
            .foregroundStyle(theme.palette.textPrimary.color(scheme))
    }
}

// MARK: - Leaf views (extracted so a page re-render doesn't rebuild every tile)

/// One dashboard statistic — an accent icon, a big value, and a caption label.
private struct HomeStatTile: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let symbol: String
    let value: String
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.xs) {
            Image(systemName: symbol)
                .font(.token(theme.typography.headline))
                .foregroundStyle(theme.palette.accent.color(scheme))
                .accessibilityHidden(true)
            Text(value)
                .font(.token(theme.typography.title))
                .foregroundStyle(theme.palette.textPrimary.color(scheme))
            Text(label)
                .font(.token(theme.typography.caption))
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(theme.spacing.md)
        .brandGlassCard(cornerRadius: theme.radius.md)
        .accessibilityElement(children: .combine)
    }
}

/// One recent-session row — a quick-open target labelling a session by venue,
/// who/when, and lap count. Rendered inside a `Button` by the parent.
private struct HomeRecentRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let summary: SessionSummary

    var body: some View {
        HStack(spacing: theme.spacing.md) {
            Image(systemName: summary.isAvailable ? "chart.xyaxis.line" : "exclamationmark.triangle.fill")
                .foregroundStyle(summary.isAvailable
                    ? theme.palette.accent.color(scheme)
                    : theme.palette.negative.color(scheme))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                Text(summary.venue.isEmpty ? "Unknown venue" : summary.venue)
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Text(subtitle)
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
            Spacer()
            Text("\(summary.lapCount) lap\(summary.lapCount == 1 ? "" : "s")")
                .font(.token(theme.typography.caption))
                .foregroundStyle(theme.palette.textSecondary.color(scheme))
        }
        .padding(theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandGlassCard(cornerRadius: theme.radius.md)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let who = [summary.vehicle, summary.driver].filter { !$0.isEmpty }.joined(separator: " • ")
        let when = summary.date.formatted(date: .abbreviated, time: .shortened)
        return who.isEmpty ? when : "\(who) · \(when)"
    }
}

/// One onboarding tip — an accent icon, a title, and a one-line detail.
private struct HomeTipRow: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    let tip: StartTip

    var body: some View {
        HStack(alignment: .top, spacing: theme.spacing.md) {
            Image(systemName: tip.symbol)
                .font(.token(theme.typography.title))
                .foregroundStyle(theme.palette.accent.color(scheme))
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                Text(tip.title)
                    .font(.token(theme.typography.headline))
                    .foregroundStyle(theme.palette.textPrimary.color(scheme))
                Text(tip.detail)
                    .font(.token(theme.typography.callout))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(theme.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .brandGlassCard(cornerRadius: theme.radius.md)
        .accessibilityElement(children: .combine)
    }
}
