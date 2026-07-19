import SwiftUI
import RaceStudioCore

/// The Math Channels panel (issue 8.8): the live ``MathChannelEditorView`` (4.6)
/// for a draft expression, a name/unit + Add control that commits it as a defined
/// channel, the list of defined channels (with removal and a preview of the
/// selected one), and the function-library reference.
///
/// Deliberately **thin**: validation, the reject-with-parser-message rule, trace
/// capture, and the library content all live in
/// `RaceStudioCore.MathChannelsManagerModel` / `MathFunctionLibrary`; this view
/// only lays out the regions and forwards edits.
struct MathChannelsPanel: View {
    @ObservedObject var manager: MathChannelsManagerModel
    /// The nested draft editor, observed here too so the Add button's enabled state
    /// re-renders when its debounced validation completes (the panel observes
    /// `manager`, which does not publish the editor's changes).
    @ObservedObject var editor: MathChannelEditorModel
    /// The function-library reference — a pure value of the immutable channel names,
    /// built once rather than per render.
    let library: MathFunctionLibrary

    @State private var name = ""
    @State private var unit = ""
    /// Bumped after each add / reference insert so the embedded editor re-seeds its
    /// field from the (manager-owned) draft text.
    @State private var draftGeneration = 0
    /// The defined channel whose preview trace is shown, if any.
    @State private var previewedChannel: String?
    /// True while an add is in flight, so a fast second tap can't spawn a duplicate.
    @State private var isAdding = false

    init(manager: MathChannelsManagerModel, channelNames: [String]) {
        self.manager = manager
        self._editor = ObservedObject(wrappedValue: manager.editor)
        self.library = MathFunctionLibrary(channelNames: channelNames)
    }

    var body: some View {
        HStack(spacing: 0) {
            authoringColumn
            Divider()
            referenceColumn.frame(width: 220)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Authoring (editor + add + list)

    private var authoringColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Math channel").font(.headline)
            identityFields
            MathChannelEditorView(model: manager.editor).id(draftGeneration)
            addControls
            Divider()
            definedList
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var identityFields: some View {
        HStack(spacing: 8) {
            TextField("Name, e.g. Accel", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("Unit", text: $unit)
                .textFieldStyle(.roundedBorder)
                .frame(width: 80)
        }
    }

    private var addControls: some View {
        HStack(spacing: 12) {
            Button("Add channel") { commit() }
                .disabled(!canAdd || isAdding)
            if let rejection = manager.rejection {
                Text(rejection.message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            Spacer()
        }
    }

    /// The defined channels, each removable and tappable to preview its trace.
    private var definedList: some View {
        Group {
            if manager.channels.isEmpty {
                Text("No math channels yet. Add one above.")
                    .font(.caption).foregroundColor(.secondary)
            } else {
                List {
                    ForEach(manager.channels) { defined in definedRow(defined) }
                        .onDelete { manager.remove(atOffsets: $0) }
                }
                .frame(minHeight: 120)
                previewPlot
            }
        }
    }

    private func definedRow(_ defined: DefinedMathChannel) -> some View {
        Button { previewedChannel = defined.id } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(defined.definition.name).font(.body.bold())
                        if !defined.definition.unit.isEmpty {
                            Text(defined.definition.unit).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Text(defined.definition.expression)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Spacer()
                if previewedChannel == defined.id {
                    Image(systemName: "eye").font(.caption).foregroundColor(.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The evaluated trace of the previewed channel, drawn in time mode (a math
    /// channel is time-keyed) — showing it is a real channel over the session.
    @ViewBuilder private var previewPlot: some View {
        if let id = previewedChannel,
           let defined = manager.channels.first(where: { $0.id == id }),
           !defined.trace.samples.isEmpty {
            // `.id` so switching the previewed channel builds a fresh plot rather
            // than reusing the prior one's viewport @State.
            TimeDistancePlotView(traces: [defined.trace], mode: .time, renderer: .swiftCharts)
                .frame(minHeight: 140)
                .id(defined.id)
        }
    }

    // MARK: - Function-library reference

    private var referenceColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Reference").font(.headline)
                Text("Tap to insert at the end of the expression.")
                    .font(.caption2).foregroundColor(.secondary)
                ForEach(MathReferenceCategory.allCases) { category in
                    section(category, entries: library.entries(for: category))
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func section(_ category: MathReferenceCategory,
                                      entries: [MathFunctionEntry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(category.title.uppercased())
                    .font(.caption2.bold()).foregroundColor(.secondary)
                ForEach(entries) { entry in referenceRow(entry) }
            }
        }
    }

    private func referenceRow(_ entry: MathFunctionEntry) -> some View {
        Button { insert(entry) } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.symbol).font(.system(.caption, design: .monospaced))
                Text(entry.summary).font(.caption2).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    /// Whether the draft is a valid, named expression ready to add.
    private var canAdd: Bool {
        guard case .valid = editor.state else { return false }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Commit the draft; on success clear the name/unit fields and re-seed the
    /// editor field (the manager clears the draft text). The in-flight guard plus a
    /// disabled button stop a fast second tap from adding a duplicate.
    private func commit() {
        guard !isAdding else { return }
        isAdding = true
        let expression = editor.text
        let channelName = name
        let channelUnit = unit
        Task { @MainActor in
            if await manager.add(name: channelName, unit: channelUnit, expression: expression) {
                name = ""
                unit = ""
                draftGeneration += 1
            }
            isAdding = false
        }
    }

    /// Insert a reference token at the end of the draft, then re-seed the field.
    private func insert(_ entry: MathFunctionEntry) {
        editor.update(text: editor.text + entry.insertion)
        draftGeneration += 1
    }
}

/// A no-session fallback ``ExpressionEvaluating`` for the Math panel when the
/// loader vends no evaluator (a non-FFI build/preview): every expression is
/// rejected rather than crashing, so the panel stays interactive.
struct NoSessionEvaluator: ExpressionEvaluating {
    func evaluate(_ expression: String) async throws -> [MathSample] {
        throw ExpressionEngineError.other(message: "Load a session to evaluate math channels.")
    }
}
