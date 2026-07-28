import SwiftUI
import RaceStudioCore

/// The app's **Home / dashboard** startup page: a brand-tokenized landing shown
/// when RaceStudio opens, so a user sees their library at a glance and — first run
/// or returning — knows exactly how to start and how to analyze.
///
/// Thin, like the rest of the shell: the onboarding copy (``StartGuide``) and the
/// at-a-glance stats (``LibraryDashboard``) come from `RaceStudioCore`; this view
/// only lays them out with the ``Theme`` tokens and wires the quick actions. The
/// full library browser is one click away via **Browse Library**.
struct HomeView: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var library: LibraryBrowserModel
    let onImport: () -> Void
    let onBrowseLibrary: () -> Void
    let onOpen: (SessionSummary) -> Void

    // The whole library (never the browser's filtered view), so the dashboard's
    // stats and recents are correct regardless of any active search/scope/facet.
    private var dashboard: LibraryDashboard { LibraryDashboard(sessions: library.allSessions) }
    private var recent: [SessionSummary] { Array(library.allSessions.prefix(6)) }

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
    }

    // MARK: - Hero + quick actions

    private var hero: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            HStack(spacing: theme.spacing.md) {
                Image(systemName: "flag.checkered")
                    .font(.token(theme.typography.largeTitle))
                    .foregroundStyle(theme.palette.accent.color(scheme))
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
        .background(theme.palette.surface.color(scheme),
                    in: RoundedRectangle(cornerRadius: theme.radius.lg))
    }

    // MARK: - Dashboard stat tiles

    private var statsRow: some View {
        HStack(spacing: theme.spacing.md) {
            statTile("Sessions", "\(dashboard.sessionCount)", "square.stack.3d.up")
            statTile("Venues", "\(dashboard.venueCount)", "mappin.and.ellipse")
            statTile("Vehicles", "\(dashboard.vehicleCount)", "car.side")
            statTile("Laps", "\(dashboard.totalLaps)", "timer")
        }
    }

    private func statTile(_ label: String, _ value: String, _ symbol: String) -> some View {
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
        .background(theme.palette.surface.color(scheme),
                    in: RoundedRectangle(cornerRadius: theme.radius.md))
        .overlay(RoundedRectangle(cornerRadius: theme.radius.md)
            .strokeBorder(theme.palette.separator.color(scheme)))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Recent sessions

    private var recentSessions: some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            sectionHeader("Recent sessions")
            VStack(spacing: theme.spacing.xs) {
                ForEach(recent) { summary in
                    Button { onOpen(summary) } label: { recentRow(summary) }
                        .buttonStyle(.plain)
                        .disabled(!summary.isAvailable)
                }
            }
        }
    }

    private func recentRow(_ summary: SessionSummary) -> some View {
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
                Text(recentSubtitle(summary))
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
        .background(theme.palette.surface.color(scheme),
                    in: RoundedRectangle(cornerRadius: theme.radius.md))
        .contentShape(Rectangle())
    }

    private func recentSubtitle(_ summary: SessionSummary) -> String {
        let parts = [summary.vehicle, summary.driver].filter { !$0.isEmpty }
        let who = parts.joined(separator: " • ")
        let when = summary.date.formatted(date: .abbreviated, time: .shortened)
        return who.isEmpty ? when : "\(who) · \(when)"
    }

    // MARK: - Tip sections

    private func tipSection(title: String, tips: [StartTip]) -> some View {
        VStack(alignment: .leading, spacing: theme.spacing.sm) {
            sectionHeader(title)
            VStack(spacing: theme.spacing.sm) {
                ForEach(tips) { tip in tipRow(tip) }
            }
        }
    }

    private func tipRow(_ tip: StartTip) -> some View {
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
        .background(theme.palette.surface.color(scheme),
                    in: RoundedRectangle(cornerRadius: theme.radius.md))
        .accessibilityElement(children: .combine)
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.token(theme.typography.title))
            .foregroundStyle(theme.palette.textPrimary.color(scheme))
    }
}
