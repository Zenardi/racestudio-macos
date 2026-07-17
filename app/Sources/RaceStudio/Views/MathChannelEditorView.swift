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
        .accessibilityLabel("Math-channel editor")
    }

    /// The inline diagnostic for an invalid expression: a monospaced caret line
    /// under the offending span (aligned with the field's monospaced glyphs) and
    /// the engine's message.
    @ViewBuilder private var diagnostic: some View {
        if case let .invalid(diagnostic) = model.state {
            VStack(alignment: .leading, spacing: 2) {
                if let caret = caretLine(for: diagnostic.span) {
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
            TimeDistancePlotView(traces: [trace], mode: .time, renderer: .swiftCharts)
                .frame(minHeight: 160)
        }
    }

    /// A caret string (`"   ^"`) placing a `^` under the diagnostic's character
    /// span, clamped to the current text length so it never runs past the field.
    private func caretLine(for span: Range<Int>?) -> String? {
        guard let span else { return nil }
        let start = min(max(span.lowerBound, 0), text.count)
        let length = max(1, min(span.count, max(1, text.count - start)))
        return String(repeating: " ", count: start) + String(repeating: "^", count: length)
    }
}
