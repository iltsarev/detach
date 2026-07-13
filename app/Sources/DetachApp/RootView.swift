import SwiftUI
import DetachKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AppFontSize.storageKey) private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = false
    let detachPath: String
    let pollInterval: Double
    let installation: InstallationStore
    @ObservedObject var notifications: SessionNotificationService

    @State private var store: SessionStore
    @State private var selectedID: String?

    init(
        detachPath: String,
        pollInterval: Double,
        installation: InstallationStore,
        notifications: SessionNotificationService
    ) {
        self.detachPath = detachPath
        self.pollInterval = pollInterval
        self.installation = installation
        self.notifications = notifications
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
                    SidebarView(
                        store: store,
                        detachPath: detachPath,
                        selectedID: $selectedID)
                } detail: {
                    if store.sessions.isEmpty && store.state == .ok {
                        EmptySessionsView()
                    } else if let session = selectedSession {
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
        .appFontSize(fontPointSize)
        .frame(
            minWidth: AppFontSize.minimumWindowSize(for: fontPointSize).width,
            minHeight: AppFontSize.minimumWindowSize(for: fontPointSize).height)
        .task(id: pollInterval) { store.startPolling(interval: pollInterval) }
        .task(id: "\(detachPath)|\(pollInterval)") {
            // A packaged update can replace the CLI during bootstrap. Wait for
            // that handoff before establishing the notification baseline so a
            // historical completed turn is not mistaken for a new one.
            await installation.bootstrap()
            guard !installation.hasDistributionPayload ||
                    installation.distributionMatchesBundle else { return }
            notifications.configureMonitoring(
                detachPath: detachPath,
                interval: pollInterval)
        }
        .task(id: notificationsEnabled) {
            await notifications.configure(enabled: notificationsEnabled)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await installation.refreshContext()
                await notifications.refreshAuthorizationStatus()
            }
        }
        .onDisappear { store.stopPolling() }
    }
}
