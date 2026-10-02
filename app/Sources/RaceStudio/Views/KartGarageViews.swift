import SwiftUI
import RaceStudioCore

/// The kart garage in the library (thin views over ``LibraryBrowserModel``): the
/// sidebar section listing karts, the session header's kart picker, and the
/// sheet that adds or edits a kart. Every decision — assignment, the per-track
/// default, filtering, saving — lives in `RaceStudioCore`.

/// What the kart editor is editing: a new kart (optionally to be assigned to a
/// session once saved), or an existing one.
struct KartEditTarget: Identifiable {
    let kart: Kart
    let isNew: Bool
    /// The session to assign the kart to once it is saved, if any.
    let assignTo: String?
    var id: String { kart.id }

    static func new(assignTo sessionID: String? = nil) -> KartEditTarget {
        KartEditTarget(kart: Kart(name: ""), isNew: true, assignTo: sessionID)
    }
}

/// The sidebar's "Garage" section: tap a kart to show only its sessions (tap
/// again to show all), right-click to edit or delete it, or add a new one.
struct GarageSection: View {
    @ObservedObject var library: LibraryBrowserModel
    @Binding var editing: KartEditTarget?

    var body: some View {
        Section("Garage") {
            ForEach(library.karts) { kart in
                let active = library.kartFilter == kart.id
                Button {
                    library.setKartFilter(active ? nil : kart.id)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Label(kart.displayName, systemImage: "steeringwheel")
                            .fontWeight(active ? .semibold : .regular)
                        if !kart.specification.isEmpty, kart.specification != kart.displayName {
                            Text(kart.specification)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.leading, 24)
                        }
                    }
                }
                .buttonStyle(.plain)
                .help(active ? "Showing this kart's sessions — click to show all"
                             : "Show only sessions driven on this kart")
                .contextMenu {
                    Button("Edit Kart…") { editing = KartEditTarget(kart: kart, isNew: false, assignTo: nil) }
                    Button("Delete Kart", role: .destructive) { library.deleteKart(id: kart.id) }
                }
            }
            Button {
                editing = .new()
            } label: {
                Label("Add Kart…", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
    }
}

/// The session header's kart picker: the assigned kart, or "Assign Kart".
/// Choosing one also makes it the default for new sessions from this track.
struct KartPicker: View {
    @ObservedObject var library: LibraryBrowserModel
    let summary: SessionSummary
    @Binding var editing: KartEditTarget?

    var body: some View {
        let current = summary.kartID.flatMap(library.kart(id:))
        Menu {
            ForEach(library.karts) { kart in
                Button {
                    library.assignKart(kart.id, toSession: summary.id)
                } label: {
                    if kart.id == current?.id {
                        Label(kart.displayName, systemImage: "checkmark")
                    } else {
                        Text(kart.displayName)
                    }
                }
            }
            if !library.karts.isEmpty { Divider() }
            Button("New Kart…") { editing = .new(assignTo: summary.id) }
            if current != nil {
                Button("No Kart") { library.assignKart(nil, toSession: summary.id) }
            }
        } label: {
            Label(current?.displayName ?? "Assign Kart", systemImage: "steeringwheel")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(current.map { "\($0.displayName): \($0.specification). Sessions from this track default to it." }
              ?? "Choose the kart this session was driven on")
    }
}

/// Add or edit a kart: name, category, chassis, engine and power.
struct KartEditorSheet: View {
    @ObservedObject var library: LibraryBrowserModel
    let target: KartEditTarget
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var category = ""
    @State private var chassis = ""
    @State private var engine = ""
    @State private var power = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(target.isNew ? "New Kart" : "Edit Kart")
                .font(.headline)
            Form {
                TextField("Name", text: $name, prompt: Text("e.g. Race kart"))
                TextField("Category", text: $category, prompt: Text("e.g. F4"))
                TextField("Chassis", text: $chassis, prompt: Text("e.g. Thunder"))
                TextField("Engine", text: $engine, prompt: Text("e.g. RBC Honda"))
                TextField("Power (HP)", text: $power, prompt: Text("e.g. 18"))
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(target.isNew ? "Add" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(edited.displayName == "Unnamed kart")
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            name = target.kart.name
            category = target.kart.category
            chassis = target.kart.chassis
            engine = target.kart.engine
            power = target.kart.powerText.map { String($0.dropLast(3)) } ?? ""
        }
    }

    /// The kart as typed; power accepts a decimal point or comma.
    private var edited: Kart {
        let hp = Double(power.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespaces))
        return Kart(id: target.kart.id, name: name, category: category, chassis: chassis,
                    engine: engine, powerHP: hp)
    }

    private func save() {
        library.saveKart(edited)
        if let sessionID = target.assignTo {
            library.assignKart(target.kart.id, toSession: sessionID)
        }
        dismiss()
    }
}
