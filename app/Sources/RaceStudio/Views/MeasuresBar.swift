import SwiftUI
import RaceStudioCore

/// The analysis window's bottom bar (issue 8.3), brand-tokenized (issue 7.5): the
/// cursor scrubber and the value-at-cursor for every selected channel.
///
/// The scrubber used to be a bare slider over absolute session time with a
/// `t = 123.45 s` readout. With two or more laps selected that gave the user nothing
/// to work with — dragging swept the whole recording including unselected laps, the
/// readout was in session seconds rather than "15 s into lap 2", the track showed no
/// lap boundaries, and one absolute cursor said nothing about where in each selected
/// lap it landed, which is the entire reason to select several.
///
/// It now has two modes. **Session** sweeps the recording with lap boundaries marked
/// on the track. **Lap** scrubs an offset *within* a lap and shows the equivalent
/// point in every selected lap, so the channel readouts above compare like with
/// like. Thin, as before: every conversion, readout, and tick position is computed
/// by `RaceStudioCore.LapScrub`.
struct MeasuresBar: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: AnalysisWindowModel
    @ObservedObject var cursor: LinkedCursor
    /// The requested scrub mode. Persisted, and downgraded by ``LapScrub`` whenever
    /// there is no lap to anchor to, so the control is never inert.
    @AppStorage("analysis.scrubMode") private var requestedMode = ScrubMode.session.rawValue

    private var scrub: LapScrub {
        model.scrub(mode: ScrubMode(rawValue: requestedMode) ?? .session)
    }

    var body: some View {
        let scrub = self.scrub
        VStack(spacing: theme.spacing.sm) {
            scrubber(scrub)
            if !scrub.alignedTimes.isEmpty { alignedLaps(scrub) }
            measures
        }
        .padding(theme.spacing.sm)
        .frame(maxWidth: .infinity)
        // Translucent glass bar (macOS-13-safe Material) — it sits over the plots,
        // so the blurred content behind gives the most effective glass look.
        .background(.regularMaterial)
    }

    // MARK: - Scrubber

    /// Mode control, lap-relative readout, and the slider with lap-boundary marks.
    /// Hidden when the session has no positive-width extent (decided in Core).
    @ViewBuilder private func scrubber(_ scrub: LapScrub) -> some View {
        if let range = scrub.range {
            HStack(spacing: theme.spacing.md) {
                modePicker(scrub)
                Text(scrub.readout)
                    .font(.token(theme.typography.readout))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
                    .frame(width: 180, alignment: .leading)
                    .monospacedDigit()
                Slider(value: Binding(get: { scrub.value },
                                      set: { cursor.moveTime(scrub.time(for: $0)) }),
                       in: range)
                    .tint(theme.palette.accent.color(scheme))
                    .background(LapTickTrack(positions: scrub.lapTicks,
                                             color: theme.palette.separator.color(scheme)))
            }
            .help(scrub.help)
        }
    }

    /// Session/Lap control. Lap mode is offered only once a lap is selected — the
    /// offsets have nothing to anchor to otherwise.
    @ViewBuilder private func modePicker(_ scrub: LapScrub) -> some View {
        Picker("", selection: $requestedMode) {
            ForEach(ScrubMode.allCases, id: \.rawValue) { mode in
                Text(mode.title).tag(mode.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(!scrub.canScrubByLap && scrub.mode == .session)
        .help(scrub.canScrubByLap
              ? "Scrub the whole session, or the same point within every selected lap"
              : "Select a lap to scrub lap-by-lap")
    }

    /// Where the cursor lands in each selected lap. A lap shorter than the offset has
    /// no such point, and is marked rather than silently showing its last sample.
    private func alignedLaps(_ scrub: LapScrub) -> some View {
        HStack(spacing: theme.spacing.md) {
            ForEach(scrub.alignedTimes, id: \.lapNumber) { aligned in
                HStack(spacing: theme.spacing.xs / 2) {
                    Text("Lap \(aligned.lapNumber)")
                        .font(.token(theme.typography.caption))
                        .foregroundStyle(theme.palette.textSecondary.color(scheme))
                    Text(TimecodeFormatter.string(from: aligned.time))
                        .font(.token(theme.typography.readout))
                        .monospacedDigit()
                        .foregroundStyle(aligned.isBeyondLap
                            ? theme.palette.textSecondary.color(scheme)
                            : theme.palette.textPrimary.color(scheme))
                    if aligned.isBeyondLap {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.token(theme.typography.caption))
                            // Dimmed, like an extrapolated measure: a caveat about
                            // what the data can answer, not an error.
                            .foregroundStyle(theme.palette.textSecondary.color(scheme))
                            .help("This lap is shorter than the cursor's offset — "
                                  + "there is no such point in it")
                    }
                }
            }
            Spacer()
        }
    }

    // MARK: - Value at cursor

    private var measures: some View {
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
}

/// Faint vertical marks where each lap begins along the scrub track — the cue that
/// turns an anonymous slider into a readable session timeline.
///
/// Positions are normalised `0...1` by ``LapScrub/lapTicks``. The track is inset to
/// approximate the slider thumb's travel, so a mark sits near the value it denotes;
/// it is an orientation cue, not a hit target.
private struct LapTickTrack: View {
    let positions: [Double]
    let color: Color

    /// Half the slider thumb's width — the travel lost at each end.
    private static let thumbInset: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let usable = max(geometry.size.width - Self.thumbInset * 2, 1)
            ForEach(Array(positions.enumerated()), id: \.offset) { _, position in
                Rectangle()
                    .fill(color)
                    .frame(width: 1, height: geometry.size.height * 0.55)
                    .offset(x: Self.thumbInset + usable * position,
                            y: geometry.size.height * 0.225)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
