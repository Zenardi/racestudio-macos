import SwiftUI
import RaceStudioCore

/// The math-channel editor (issue 4.6): an expression field with live
/// validation, an inline diagnostic (message + a caret under the offending
/// character span), and an embedded 4.1 preview plot of the evaluated channel.
///
/// Thin: all validation, debounce / last-write-wins, engine-error → diagnostic
/// mapping, and the preview `ChannelTrace` live in `RaceStudioCore`
/// (`MathChannelEditorModel`); this view only renders that state and forwards
/// keystrokes.
public struct MathChannelEditorView: View {
    @ObservedObject private var model: MathChannelEditorModel
    @State private var text: String

    public init(model: MathChannelEditorModel) {
        _model = ObservedObject(wrappedValue: model)
        _text = State(initialValue: model.text)
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Expression, e.g. 2 * RPM + 1", text: $text)
                .font(.system(.body, design: .monospaced))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .onChange(of: text) { model.update(text: $0) }

            diagnostic
            previewPlot
        }
        .padding(12)
        .accessibilityLabel(L10n.string(.chartMathEditor))
    }

    /// The inline diagnostic for an invalid expression: a monospaced caret line
    /// under the offending span (aligned with the field's monospaced glyphs) and
    /// the engine's message. The caret is computed and clamped in Core.
    @ViewBuilder private var diagnostic: some View {
        if case let .invalid(diagnostic) = model.state {
            VStack(alignment: .leading, spacing: 2) {
                if let caret = diagnostic.caret(forTextLength: text.count) {
                    Text(caret)
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                }
                Text(diagnostic.message)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
    }

    /// The 4.1 preview plot for a valid expression, drawn in time mode (a math
    /// channel is time-keyed). Hidden until there is something to show.
    @ViewBuilder private var previewPlot: some View {
        if let trace = model.preview, !trace.samples.isEmpty {
            // A math channel is time-keyed (the preview trace mirrors distance to
            // time), so the plot is shown in time mode.
            TimeDistancePlotView(traces: [trace], mode: .time, renderer: .swiftCharts)
                .frame(minHeight: 160)
        }
    }
}
