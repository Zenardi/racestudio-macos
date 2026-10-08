import SwiftUI
import RaceStudioCore

/// The **Export Video with Overlay** sheet (issue 9.14): what to export, the
/// overlay and its widgets' switches (issue 9.19), the output settings, the
/// live estimate, and *Export…*.
///
/// Thin: every choice, rule and string is ``ExportSheetModel``'s; this lays
/// them out. A choice that doesn't apply stays in its menu, disabled, with the
/// reason beside it; a lap the video doesn't hold in full is disabled in the
/// lap list with its reason.
struct ExportSheet: View {
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var scheme
    @ObservedObject var model: ExportSheetModel
    let onExport: () -> Void
    let onCancel: () -> Void
    let onSyncFirst: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: theme.spacing.md) {
            Text(L10n.string(.exportSheetTitle))
                .font(.token(theme.typography.title))
                .accessibilityAddTraits(.isHeader)
            if let warning = model.syncWarning() { syncWarning(warning) }
            Form {
                rangePicker
                if model.range == .selectedLaps { lapPicker }
                overlayPicker
                widgetSwitches
                outputPickers
                LabeledContent(L10n.string(.exportSheetEstimate)) {
                    Text(model.estimateText())
                        .font(.token(theme.typography.readout))
                        .foregroundStyle(theme.palette.textPrimary.color(scheme))
                }
            }
            if let message = model.validationMessage() {
                Label(message, systemImage: "exclamationmark.circle")
                    .foregroundStyle(theme.palette.negative.color(scheme))
                    .font(.token(theme.typography.callout))
            }
            HStack {
                Spacer()
                Button(L10n.string(.exportControlCancel), action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(L10n.string(.exportControlExport), action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canExport)
            }
        }
        .padding(theme.spacing.lg)
        .frame(width: 520)
    }

    // MARK: - Sections

    private func syncWarning(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: theme.spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.palette.negative.color(scheme))
                .accessibilityHidden(true)
            Text(warning)
                .font(.token(theme.typography.callout))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(L10n.string(.exportControlSyncFirst), action: onSyncFirst)
        }
        .padding(theme.spacing.sm)
        .background(theme.palette.surfaceElevated.color(scheme))
        .cornerRadius(theme.radius.sm)
        // `.contain`, not `.combine`: VoiceOver reads the warning and still
        // reaches Sync First as its own button.
        .accessibilityElement(children: .contain)
    }

    private var rangePicker: some View {
        Picker(L10n.string(.exportSheetRange), selection: $model.range) {
            ForEach(model.rangeOptions) { option in
                Text(option.reason().map { "\(option.title()) — \($0)" } ?? option.title())
                    .tag(option.choice)
                    .disabled(!option.isAvailable)
            }
        }
    }

    private var lapPicker: some View {
        Section(L10n.string(.exportSheetLaps)) {
            ForEach(model.lapItems) { item in
                Toggle(isOn: Binding(get: { model.pickedLaps.contains(item.lap) },
                                     set: { _ in model.togglePick(item.lap) })) {
                    HStack {
                        Text(item.title())
                            .font(.token(theme.typography.body))
                        if item.isBest {
                            Image(systemName: "star.fill")
                                .accessibilityLabel(L10n.string(.exportRangeBestLap))
                        }
                        if let reason = item.reason() {
                            Text(reason)
                                .font(.token(theme.typography.caption))
                                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                        }
                    }
                }
                .disabled(!item.isCovered)
                .help(item.reason() ?? "")
            }
            if let hint = model.lapsHint() {
                Text(hint)
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
        }
    }

    private var overlayPicker: some View {
        Picker(L10n.string(.exportSheetOverlay), selection: $model.overlay) {
            ForEach(model.overlayOptions, id: \.self) { choice in
                Text(choice.title()).tag(choice)
            }
        }
    }

    /// The chosen overlay's widgets, each switched on or off for this export;
    /// one the session can't feed is disabled, with the reason beside it.
    private var widgetSwitches: some View {
        Section {
            ForEach(model.widgetItems) { item in
                Toggle(isOn: Binding(get: { item.isOn }, set: { model.setWidget(item.id, isOn: $0) })) {
                    HStack {
                        Text(item.title())
                            .font(.token(theme.typography.body))
                        if let reason = item.reason() {
                            Text(reason)
                                .font(.token(theme.typography.caption))
                                .foregroundStyle(theme.palette.textSecondary.color(scheme))
                        }
                    }
                }
                .disabled(!item.canSwitchOn)
                .help(item.reason() ?? "")
            }
            if let note = model.noOverlayMessage() {
                Text(note)
                    .font(.token(theme.typography.caption))
                    .foregroundStyle(theme.palette.textSecondary.color(scheme))
            }
        } header: {
            HStack {
                Text(L10n.string(.exportSheetWidgets))
                Spacer()
                Button(L10n.string(.exportControlShowAll), action: model.showAllWidgets)
                Button(L10n.string(.exportControlHideAll), action: model.hideAllWidgets)
            }
        }
    }

    @ViewBuilder private var outputPickers: some View {
        Picker(L10n.string(.exportSheetResolution), selection: $model.settings.resolution) {
            ForEach(ExportResolution.allCases, id: \.self) { resolution in
                Text(model.resolutionTitle(resolution)).tag(resolution)
            }
        }
        Picker(L10n.string(.exportSheetCodec), selection: $model.settings.codec) {
            ForEach(ExportCodec.allCases, id: \.self) { codec in
                Text(codec.title()).tag(codec)
            }
        }
        Toggle(L10n.string(.exportSheetAudio), isOn: Binding(
            get: { model.footageHasAudio && model.settings.audio == .keep },
            set: { model.settings.audio = $0 ? .keep : .drop }))
            .disabled(!model.footageHasAudio)
        Toggle(L10n.string(.exportSheetOutsideSession), isOn: Binding(
            get: { model.settings.outsideSession == .noData },
            set: { model.settings.outsideSession = $0 ? .noData : .hidden }))
    }
}
