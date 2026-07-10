import SwiftUI
import DetachKit

@MainActor
struct RootView: View {
    let detachPath: String
    let pollInterval: Double

    @State private var store: SessionStore
    @State private var selectedID: String?

    init(detachPath: String, pollInterval: Double) {
        self.detachPath = detachPath
        self.pollInterval = pollInterval
        _store = State(initialValue: SessionStore(
            cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath))))
    }

    private var selectedSession: Session? {
        store.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if store.state == .cliMissing && store.sessions.isEmpty {
                OnboardingView(detachPath: detachPath)
            } else {
                NavigationSplitView {
                    SidebarView(store: store, selectedID: $selectedID)
                } detail: {
                    if let session = selectedSession {
                        SessionDetailView(session: session, store: store, detachPath: detachPath)
                            .id(session.id)
                    } else {
                        ContentUnavailableView(
                            "Выбери сессию",
                            systemImage: "terminal",
                            description: Text("Слева — все detach-сессии обоих провайдеров"))
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { store.startPolling(interval: pollInterval) }
        .onDisappear { store.stopPolling() }
    }
}
