import SwiftUI
import DetachKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppFontSize.storageKey) private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.notificationsEnabledKey) private var notificationsEnabled = false
    @AppStorage(AppSettings.tipsEnabledKey) private var tipsEnabled = true
    let detachPath: String
    let pollInterval: Double
    let installation: InstallationStore
    /// App-level shared store: the window only adjusts its cadence and never
    /// stops it, so notifications and the menu bar stay fed after close.
    let store: SessionStore
    @ObservedObject var navigation: MainNavigation
    @ObservedObject var notifications: SessionNotificationService
    @ObservedObject var tips: TipSession
    @ObservedObject var settingsNavigation: SettingsNavigation

    @State private var selectedID: String?

    private var selectedSession: Session? {
        store.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
            if installation.hasDistributionPayload
                && installation.onboardingStep != .mainApp {
                OnboardingView(store: installation)
            } else if store.state == .cliMissing && store.sessions.isEmpty {
                ContentUnavailableView(
                    L10n.string("detach CLI not found"),
                    systemImage: "terminal",
                    description: Text(L10n.format("Check the %@ path in Settings.", detachPath)))
            } else {
                VStack(spacing: 0) {
                    NavigationSplitView {
                        SidebarView(
                            store: store,
                            detachPath: detachPath,
                            selectedID: $selectedID,
                            navigation: navigation)
                    } detail: {
                        if store.sessions.isEmpty && store.state == .ok {
                            EmptySessionsView()
                        } else if let session = selectedSession {
                            SessionDetailView(session: session, store: store, detachPath: detachPath)
                                .id(session.id)
                        } else {
                            ContentUnavailableView {
                                Label {
                                    Text(L10n.string("Select a session"))
                                } icon: {
                                    Image(systemName: "terminal").foregroundStyle(Brand.gradient)
                                }
                            } description: {
                                Text(L10n.string("All detach sessions from both providers are on the left"))
                            }
                        }
                    }

                    if tipsEnabled,
                       !tips.isDismissed,
                       store.state != .cliMissing,
                       let tip = tips.currentTip {
                        TipsBar(
                            tip: tip,
                            openSettings: { destination in
                                settingsNavigation.select(destination)
                                openSettings()
                            },
                            showNext: tips.showNext,
                            dismiss: tips.dismissUntilNextLaunch)
                    }
                }
            }
        }
        .appFontSize(fontPointSize)
        .frame(
            minWidth: AppFontSize.minimumWindowSize(for: fontPointSize).width,
            minHeight: AppFontSize.minimumWindowSize(for: fontPointSize).height)
        .task(id: pollInterval) { store.startPolling(interval: pollInterval) }
        .task(id: detachPath) {
            // The store outlives this window; rewire it to the active CLI and
            // keep notifications fed from the same single poller. The
            // transition detector baselines on its first successful snapshot,
            // so historical sessions never fire as fresh notifications.
            store.onSnapshot = { [weak notifications] sessions in
                await notifications?.observe(sessions)
            }
            await store.configure(cli: ProcessDetachCLI(
                executable: URL(fileURLWithPath: detachPath)))
            await installation.bootstrap()
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
        .onChange(of: navigation.requestedSessionID) { _, requested in
            guard let requested else { return }
            selectedID = requested
            navigation.requestedSessionID = nil
        }
        .onAppear { store.updateCadence(foreground: true) }
        .onDisappear { store.updateCadence(foreground: false) }
    }
}
