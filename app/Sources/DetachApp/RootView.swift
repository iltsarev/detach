import SwiftUI
import DetachKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let detachPath: String
    let pollInterval: Double
    let installation: InstallationStore

    @State private var store: SessionStore
    @State private var selectedID: String?

    init(detachPath: String, pollInterval: Double, installation: InstallationStore) {
        self.detachPath = detachPath
        self.pollInterval = pollInterval
        self.installation = installation
        _store = State(initialValue: SessionStore(
            cli: ProcessDetachCLI(executable: URL(fileURLWithPath: detachPath))))
    }

    private var selectedSession: Session? {
        store.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if installation.hasDistributionPayload && installation.phase != .ready {
                OnboardingView(store: installation)
            } else if store.state == .cliMissing && store.sessions.isEmpty {
                ContentUnavailableView(
                    "detach CLI не найден",
                    systemImage: "terminal",
                    description: Text("Проверь путь \(detachPath) в настройках."))
            } else {
                NavigationSplitView {
                    SidebarView(store: store, selectedID: $selectedID)
                } detail: {
                    if let session = selectedSession {
                        SessionDetailView(session: session, store: store, detachPath: detachPath)
                            .id(session.id)
                    } else {
                        ContentUnavailableView {
                            Label {
                                Text("Выбери сессию")
                            } icon: {
                                Image(systemName: "terminal").foregroundStyle(Brand.gradient)
                            }
                        } description: {
                            Text("Слева — все detach-сессии обоих провайдеров")
                        }
                    }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 440)
        .task { await installation.bootstrap() }
        .task(id: pollInterval) { store.startPolling(interval: pollInterval) }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await installation.refreshContext() }
        }
        .onDisappear { store.stopPolling() }
    }
}
