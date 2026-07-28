import SwiftUI
import RaceStudioCore

/// The analysis window's bottom bar (issue 8.3), brand-tokenized (issue 7.5): a
/// cursor scrubber that moves the shared ``LinkedCursor`` along the time axis, and
/// the value-at-cursor for every selected channel. Extracted from
/// ``AnalysisWindowView`` so each file stays within the lint's length budget.
///
/// Thin: the measures and the scrub range are derived in
/// `RaceStudioCore.AnalysisWindowModel`; this only lays them out with brand tokens.
struct MeasuresBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var cursor: LinkedCursor

    var body: some View {
        VStack(spacing: theme.spacing.sm) {
            scrubber
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: theme.spacing.lg) {
                    ForEach(model.measures) { measure in
                        VStack(alignment: .leading, spacing: theme.spacing.xs / 2) {
                            Text(measure.channel.name)
                                .font(.token(theme.typography.caption))
                                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                            Text(measure.formatted)
                                .font(.token(theme.typography.readout))
                                .foregroundStyle(measure.readout.extrapolated
                                    ? theme.palette.textSecondary.color(scheme)
                                    : theme.palette.textPrimary.color(scheme))
                        }
                    }
                }
            }
        }
        .padding(theme.spacing.sm)
        .frame(maxWidth: .infinity)
        // Translucent glass bar (macOS-13-safe Material) — it sits over the plots,
        // so the blurred content behind gives the most effective glass look.
        .background(.regularMaterial)
    }

    /// A slider bound to the cursor's time position over its scrub range; hidden
    /// when the session has no positive-width extent (decided in Core).
    @ViewBuilder private var scrubber: some View {
        if let range = cursor.scrubRange {
            HStack(spacing: theme.spacing.md) {
                Text(String(format: "t = %.2f s", cursor.timePosition))
                    .font(.token(theme.typography.readout))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
                    .frame(width: 96, alignment: .leading)
                Slider(value: Binding(get: { cursor.timePosition },
                                      set: { cursor.moveTime($0) }),
                       in: range)
                    .tint(theme.palette.accent.color(scheme))
            }
        }
    }
}
