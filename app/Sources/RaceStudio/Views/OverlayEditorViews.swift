import SwiftUI
import AppKit
import RaceStudioCore

// MARK: - Editing on the video

/// The overlay editor's layer over the video rect (issue 9.12): every visible
/// widget outlined (dashed when this session can't feed it), the selected one
/// with eight handles. Drag a widget to move it, a handle to resize it; a click
/// on nothing deselects.
///
/// Thin: hit-testing, the 1% grid, the safe area, the minimum size and the
/// history are ``OverlayEditorModel``'s. Positions are fractions of this view,
/// which the panel lays exactly on the visible video rect.
struct OverlayEditCanvas: View {
    @ObservedObject var editor: OverlayEditorModel
    let aspect: OverlayAspect
    let availability: [OverlayWidget.ID: WidgetAvailability]
    @State private var isDragging = false

    private static let handleSize: CGFloat = 9

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(moveGesture(size: size))
                ForEach(editor.editableWidgets(for: aspect), id: \.id) { widget in
                    outline(widget, size: size)
                }
                if let selected = editor.selection, let frame = editor.frame(of: selected, in: aspect) {
                    ForEach(OverlayResizeHandle.allCases, id: \.self) { handle in
                        handleView(handle, frame: frame, size: size)
                    }
                }
            }
        }
    }

    private func rect(_ frame: NormalizedRect, in size: CGSize) -> CGRect {
        CGRect(x: frame.x * size.width, y: frame.y * size.height,
               width: frame.width * size.width, height: frame.height * size.height)
    }

    private func outline(_ widget: ResolvedOverlayWidget, size: CGSize) -> some View {
        let box = rect(widget.frame, in: size)
        let selected = editor.selection == widget.id
        let drawable = availability[widget.id]?.isDrawable ?? true
        return Rectangle()
            .stroke(selected ? Color.accentColor : Color.white.opacity(0.85),
                    style: StrokeStyle(lineWidth: selected ? 2 : 1, dash: drawable ? [] : [4, 3]))
            .background(Color.accentColor.opacity(selected ? 0.12 : 0))
            .frame(width: box.width, height: box.height)
            .overlay(alignment: .topLeading) {
                Text(widget.widget.kind.title())
                    .font(.caption2)
                    .padding(2)
                    .background(.black.opacity(0.55))
                    .foregroundStyle(.white)
            }
            .offset(x: box.minX, y: box.minY)
            .allowsHitTesting(false)
            .help(availability[widget.id]?.reason?.label() ?? widget.widget.kind.title())
    }

    private func handleView(_ handle: OverlayResizeHandle, frame: NormalizedRect, size: CGSize) -> some View {
        let box = rect(frame, in: size)
        let x = handle.movesLeading ? box.minX : handle.movesTrailing ? box.maxX : box.midX
        let y = handle.movesTop ? box.minY : handle.movesBottom ? box.maxY : box.midY
        return Rectangle()
            .fill(Color.white)
            .overlay(Rectangle().stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: Self.handleSize, height: Self.handleSize)
            .offset(x: x - Self.handleSize / 2, y: y - Self.handleSize / 2)
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                editor.resize(handle, by: normalized(value.translation, in: size), aspect: aspect)
            }.onEnded { _ in editor.endGesture() })
    }

    private func moveGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    let start = CGPoint(x: value.startLocation.x / max(size.width, 1),
                                        y: value.startLocation.y / max(size.height, 1))
                    editor.select(at: start, aspect: aspect)
                    editor.beginGesture()
                }
                editor.drag(by: normalized(value.translation, in: size))
            }
            .onEnded { _ in
                isDragging = false
                editor.endGesture()
            }
    }

    private func normalized(_ translation: CGSize, in size: CGSize) -> CGSize {
        CGSize(width: translation.width / max(size.width, 1), height: translation.height / max(size.height, 1))
    }
}

// MARK: - Arrow-key nudges

/// Arrow keys nudge the selected widget while the editor is open — 1%, or 5%
/// with ⇧ — unless a text field is being typed in. Watches the window's key
/// events (SwiftUI on macOS 13 has no key handler) and claims only the arrows
/// it used.
struct KeyNudgeMonitor: NSViewRepresentable {
    /// Nudge by whole grid steps; returns whether a widget moved.
    let onNudge: (_ dx: Int, _ dy: Int, _ large: Bool) -> Bool

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onNudge = onNudge
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onNudge = onNudge
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onNudge: (Int, Int, Bool) -> Bool = { _, _, _ in false }
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, event.window === self.window, !(event.window?.firstResponder is NSText),
                      let step = Self.step(for: event.keyCode) else { return event }
                return self.onNudge(step.dx, step.dy, event.modifierFlags.contains(.shift)) ? nil : event
            }
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// The arrow keys' virtual key codes, top-left origin like the layout.
        private static func step(for keyCode: UInt16) -> (dx: Int, dy: Int)? {
            switch keyCode {
            case 123: return (-1, 0)
            case 124: return (1, 0)
            case 125: return (0, 1)
            case 126: return (0, -1)
            default: return nil
            }
        }
    }
}

// MARK: - Inspector

/// The overlay editor's side panel (issue 9.12): Show HUD, the preset menu,
/// the units, a toggle per widget (with why one wouldn't draw), and the
/// selected widget's options — the pedal full scales among them.
struct OverlayEditorInspector: View {
    @ObservedObject var editor: OverlayEditorModel
    let presets: [OverlayLayout]
    let availability: [OverlayWidget.ID: WidgetAvailability]

    var body: some View {
        Form {
            Toggle(L10n.string(.controlShowHUD), isOn: Binding(
                get: { editor.layout.isEnabled }, set: { editor.setShowsHUD($0) }))
            Menu(L10n.string(.overlayEditorPreset) + ": " + editor.layout.name) {
                ForEach(Array(presets.enumerated()), id: \.offset) { _, preset in
                    Button(preset.name) { editor.apply(preset) }
                }
            }
            Picker(L10n.string(.overlayEditorUnits), selection: Binding(
                get: { editor.layout.units }, set: { editor.setUnits($0) })) {
                Text(L10n.string(.overlayUnitsMetric)).tag(UnitSystem.metric)
                Text(L10n.string(.overlayUnitsImperial)).tag(UnitSystem.imperial)
            }
            Section(L10n.string(.overlayEditorWidgets)) {
                ForEach(editor.layout.widgets) { widget in
                    widgetRow(widget)
                }
            }
            Section(L10n.string(.overlayEditorOptions)) {
                OverlayWidgetOptionsEditor(editor: editor)
            }
            Text(L10n.string(.overlayEditorHint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func widgetRow(_ widget: OverlayWidget) -> some View {
        HStack {
            Toggle(widget.kind.title(), isOn: Binding(
                get: { widget.isVisible }, set: { editor.setVisible($0, for: widget.id) }))
            Spacer()
            if let reason = availability[widget.id]?.reason {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help(reason.label())
                    .accessibilityLabel(reason.label())
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { editor.select(widget.id) }
        .listRowBackground(editor.selection == widget.id ? Color.accentColor.opacity(0.15) : Color.clear)
    }
}

/// The selected widget's own settings (``OverlayWidgetKind/editableOptions``),
/// each an undoable step.
private struct OverlayWidgetOptionsEditor: View {
    @ObservedObject var editor: OverlayEditorModel

    var body: some View {
        if let id = editor.selection, let widget = editor.layout.widgets.first(where: { $0.id == id }) {
            if widget.kind.editableOptions.isEmpty {
                Text(L10n.string(.overlayEditorNoOptions)).foregroundStyle(.secondary)
            } else {
                ForEach(widget.kind.editableOptions, id: \.self) { option in
                    TextField(option.title(), value: Binding(
                        get: { widget.options[keyPath: option.keyPath] },
                        set: { editor.setOption(option, to: $0, for: id) }), format: .number)
                }
            }
        } else {
            Text(L10n.string(.overlayEditorNoSelection)).foregroundStyle(.secondary)
        }
    }
}
