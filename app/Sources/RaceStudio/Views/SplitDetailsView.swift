import SwiftUI
import RaceStudioCore

// MARK: - Split details / editor (issue 8.11)

/// The split-editing surface beneath the Split Times table: one row per split with
/// its name, type (corner / straight), lock, and merge / divide actions. Every edit
/// flows through ``SplitReportModel`` (which re-groups the base grid), so the table,
/// best laps, and graph recompute immediately — no session re-read.
///
/// Thin by design: the layout invariants and the recompute all live in
/// `RaceStudioCore`; this view only renders the controls and forwards taps.
struct SplitDetailsPanel: View {
    @ObservedObject var report: SplitReportModel
    /// The current report — its ``SplitReport/splits`` drive the editor rows and its
    /// best-theoretical components label each split with the lap that owns it.
    let built: SplitReport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Splits").font(.caption.bold())
                Spacer()
                Text("\(report.splitCount) splits").font(.caption2).foregroundColor(.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            Divider()
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(report.layout.splits) { split in
                        splitRow(split)
                        Divider()
                    }
                }
                .padding(8)
            }
        }
        .frame(minHeight: 120)
    }

    /// One split's editor row: a lock toggle, an inline-editable name, a type picker,
    /// and the divide / merge actions. Locked splits refuse divide / merge (the model
    /// enforces it), so those buttons are disabled while locked.
    private func splitRow(_ split: Split) -> some View {
        HStack(spacing: 8) {
            Button {
                report.toggleLock(split.id)
            } label: {
                Image(systemName: split.locked ? "lock.fill" : "lock.open")
                    .foregroundColor(split.locked ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(split.locked ? "Unlock split" : "Lock split")

            TextField("Name", text: Binding(
                get: { split.name },
                set: { report.rename(split.id, to: $0) }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)

            Picker("", selection: Binding(
                get: { split.kind },
                set: { report.setKind(split.id, to: $0) })) {
                ForEach(SplitKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .fixedSize()
            .labelsHidden()

            if let owner = bestLap(for: split) {
                Text("best: Lap \(owner.index + 1)")
                    .font(.caption2).foregroundColor(.secondary)
            }

            Spacer()

            Button("Divide") { report.divide(split.id) }
                .disabled(split.locked || split.cellCount < 2)
            Button("Merge") { report.merge(split.id) }
                .disabled(split.locked || report.layout.splits.count < 2)
        }
        .font(.caption)
    }

    /// The lap that drove the fastest time for `split` (from the best-theoretical
    /// components), or `nil` when there is no data.
    private func bestLap(for split: Split) -> LapID? {
        built.bestTheoretical.perSplit.first { $0.splitID == split.id }?.lap
    }
}
