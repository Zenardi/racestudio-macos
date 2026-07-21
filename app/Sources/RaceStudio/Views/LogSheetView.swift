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
                TextField("Air temp (°C)", text: number(\.weather.airTempC))
                TextField("Track temp (°C)", text: number(\.weather.trackTempC))
                TextField("Humidity (%)", text: number(\.weather.humidityPercent))
                TextField("Conditions", text: text(\.weather.conditions))
            }
            Section("Engine") {
                TextField("Make", text: text(\.engine.make))
                TextField("Displacement (cc)", text: number(\.engine.displacementCC))
                TextField("Notes", text: text(\.engine.notes))
            }
            Section("Dimensions") {
                TextField("Wheelbase (mm)", text: number(\.dimensions.wheelbaseMM))
                TextField("Front track (mm)", text: number(\.dimensions.frontTrackMM))
                TextField("Rear track (mm)", text: number(\.dimensions.rearTrackMM))
            }
            Section("Weights") {
                TextField("Total (kg)", text: number(\.weights.totalKg))
                TextField("Front (kg)", text: number(\.weights.frontKg))
                TextField("Rear (kg)", text: number(\.weights.rearKg))
            }
            Section("Fuel") {
                TextField("Capacity (L)", text: number(\.fuel.capacityL))
                TextField("Start level (L)", text: number(\.fuel.startLevelL))
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

    private func number(_ keyPath: WritableKeyPath<LogSheet, Double?>) -> Binding<String> {
        Binding(
            get: { model.sheet[keyPath: keyPath].map { $0.formatted(.number.grouping(.never)) } ?? "" },
            set: { model.sheet[keyPath: keyPath] = Double($0) })
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
