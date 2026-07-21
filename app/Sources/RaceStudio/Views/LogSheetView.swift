import SwiftUI
import RaceStudioCore

/// The RS3 Log Sheet editor (issue 8.17): a grouped form over the session/setup
/// metadata — weather, engine, dimensions, weights, fuel, gearing, and notes.
///
/// All state lives in `RaceStudioCore.LogSheetModel.sheet`; edits bind straight to
/// it, so the sheet is captured into the project on save and reapplied on open (the
/// 5.4 `ProjectStore` round-trip). The view is deliberately thin — no logic beyond
/// field bindings.
struct LogSheetPanel: View {
    @ObservedObject var model: LogSheetModel

    var body: some View {
        Form {
            Section("Weather") {
                OptionalNumberField("Air temp (°C)", value: number(\.weather.airTempC))
                OptionalNumberField("Track temp (°C)", value: number(\.weather.trackTempC))
                OptionalNumberField("Humidity (%)", value: number(\.weather.humidityPercent))
                TextField("Conditions", text: text(\.weather.conditions))
            }
            Section("Engine") {
                TextField("Make", text: text(\.engine.make))
                OptionalNumberField("Displacement (cc)", value: number(\.engine.displacementCC))
                TextField("Notes", text: text(\.engine.notes))
            }
            Section("Dimensions") {
                OptionalNumberField("Wheelbase (mm)", value: number(\.dimensions.wheelbaseMM))
                OptionalNumberField("Front track (mm)", value: number(\.dimensions.frontTrackMM))
                OptionalNumberField("Rear track (mm)", value: number(\.dimensions.rearTrackMM))
            }
            Section("Weights") {
                OptionalNumberField("Total (kg)", value: number(\.weights.totalKg))
                OptionalNumberField("Front (kg)", value: number(\.weights.frontKg))
                OptionalNumberField("Rear (kg)", value: number(\.weights.rearKg))
            }
            Section("Fuel") {
                OptionalNumberField("Capacity (L)", value: number(\.fuel.capacityL))
                OptionalNumberField("Start level (L)", value: number(\.fuel.startLevelL))
                TextField("Type", text: text(\.fuel.type))
            }
            Section("Gearing") {
                TextField("Final drive", text: text(\.gearing.finalDrive))
                TextField("Primary drive", text: text(\.gearing.primaryDrive))
                TextField("Ratios (comma-separated)", text: ratios)
            }
            Section("Notes") {
                TextField("Notes", text: text(\.notes), axis: .vertical)
                    .lineLimit(3, reservesSpace: true)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bindings (two-way onto the model's sheet)

    private func text(_ keyPath: WritableKeyPath<LogSheet, String>) -> Binding<String> {
        Binding(get: { model.sheet[keyPath: keyPath] },
                set: { model.sheet[keyPath: keyPath] = $0 })
    }

    private func number(_ keyPath: WritableKeyPath<LogSheet, Double?>) -> Binding<Double?> {
        Binding(get: { model.sheet[keyPath: keyPath] },
                set: { model.sheet[keyPath: keyPath] = $0 })
    }

    private var ratios: Binding<String> {
        Binding(
            get: { model.sheet.gearing.ratios.joined(separator: ", ") },
            set: { newText in
                model.sheet.gearing.ratios = newText
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            })
    }
}

/// A text field over an optional `Double`. It holds its own editing buffer so
/// intermediate input (a lone `-`, a trailing `.`) is preserved instead of being
/// erased the instant it fails to parse, and it seeds/parses **locale-invariantly**
/// (period decimal, matching `Double(_:)`), so a value shown as `21.5` reparses
/// rather than silently nil-ing on a comma-decimal locale. Empty text means "not
/// entered" (`nil`); an external change to `value` (e.g. loading a project) re-seeds.
private struct OptionalNumberField: View {
    let title: String
    @Binding var value: Double?
    @State private var text: String

    init(_ title: String, value: Binding<Double?>) {
        self.title = title
        self._value = value
        self._text = State(initialValue: Self.format(value.wrappedValue))
    }

    var body: some View {
        TextField(title, text: $text)
            .onChange(of: text) { newText in
                let trimmed = newText.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    value = nil
                } else if let parsed = Double(trimmed) {
                    value = parsed
                }
                // Otherwise the user is mid-edit ("-", "1.") — keep the last value.
            }
            .onChange(of: value) { newValue in
                // Re-seed only when `value` changed underneath us (a project load),
                // not for edits we just wrote — else the two onChanges would loop.
                if Double(text.trimmingCharacters(in: .whitespaces)) != newValue {
                    text = Self.format(newValue)
                }
            }
    }

    /// Period-decimal, no grouping — the exact form `Double(_:)` parses.
    private static func format(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.grouping(.never).locale(Locale(identifier: "en_US_POSIX")))
    }
}
