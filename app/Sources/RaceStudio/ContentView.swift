import SwiftUI
import UniformTypeIdentifiers
import RaceStudioCore

/// Root view for a document window.
///
/// It renders the `SessionStore` state (issues 2.2–2.5): a drop prompt when
/// idle, a determinate progress bar with a Cancel button while loading, the
/// session summary once loaded, and an error alert on failure. Drag-and-drop of
/// `.xrk`/`.xrz` is forwarded to the shared `AppModel`; all logic lives in
/// `RaceStudioCore`, so this view carries none of its own.
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
            SessionSummaryView(viewModel: SessionSummaryViewModel(session: viewModel.session))
        case let .loading(progress):
            loadingView(progress)
        case .idle, .failed:
            Text("Drop a .xrk or .xrz file, or use File ▸ Open")
                .foregroundColor(.secondary)
                .padding()
        }
    }

    private func loadingView(_ progress: DecodeProgress) -> some View {
        VStack(spacing: 12) {
            ProgressView(value: progress.fraction) {
                Text("Decoding…")
            }
            .frame(width: 240)
            Button("Cancel") { store.cancel() }
        }
        .padding()
    }
}
