import SwiftUI
import UniformTypeIdentifiers
import RaceStudioCore

/// Root view for a document window.
///
/// It renders the `SessionStore` state (issues 2.2–2.5): a drop prompt when
/// idle, a determinate progress bar with a Cancel button while loading, the
/// analysis window once loaded (issue 8.3), and an error alert on failure.
/// Drag-and-drop of `.xrk`/`.xrz` is forwarded to the shared `AppModel`; all
/// logic lives in `RaceStudioCore`, so this view carries none of its own.
struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: SessionStore
    @State private var presentedError: ImportError?

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.xrk, .xrz], isTargeted: nil) { providers in
                model.receiveDrop(providers)
            }
            .onChange(of: store.state) { newState in
                if case let .failed(error) = newState { presentedError = error }
            }
            .alert(
                presentedError?.title ?? "Import Failed",
                isPresented: Binding(
                    get: { presentedError != nil },
                    set: { if !$0 { presentedError = nil } }),
                presenting: presentedError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { error in
                Text([error.message, error.recoverySuggestion].compactMap { $0 }.joined(separator: "\n\n"))
            }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state {
        case let .loaded(viewModel):
            // Rebuild the window's model only when a *different* session loads,
            // so selection/cursor survive unrelated re-renders of the same one.
            AnalysisWindowView(viewModel: viewModel)
                .id(windowIdentity(of: viewModel))
        case let .loading(progress):
            loadingView(progress)
        case .idle, .failed:
            Text("Drop a .xrk or .xrz file, or use File ▸ Open")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    /// A stable per-session key for the window's `@StateObject`: the live analysis
    /// pump's object identity in production (a fresh instance per load), falling
    /// back to the decoded session's content for the analysis-less loaders — so
    /// two such sessions never collide on a constant `nil` and leave a stale model.
    private func windowIdentity(of viewModel: SessionViewModel) -> String {
        if let analysis = viewModel.analysis {
            return "pump:\(ObjectIdentifier(analysis).hashValue)"
        }
        let metadata = viewModel.session.metadata
        return "session:\(metadata.datetimeUtc)|\(metadata.vehicle)|\(metadata.track)|"
            + "\(metadata.driver)|\(viewModel.session.channels.count)|\(viewModel.session.laps.count)"
    }

    private func loadingView(_ progress: DecodeProgress) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fraction) {
                Text(label(for: progress.phase))
            }
            .frame(width: 240)
            Button("Cancel") { store.cancel() }
        }
        .padding()
    }

    private func label(for phase: DecodeProgress.Phase) -> String {
        switch phase {
        case .reading: return "Reading…"
        case .decoding: return "Decoding…"
        case .finalizing: return "Finalizing…"
        case .complete: return "Finishing…"
        }
    }
}
