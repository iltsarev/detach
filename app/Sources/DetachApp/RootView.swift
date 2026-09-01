import SwiftUI
import DetachKit

@MainActor
struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openSettings) private var openSettings
    @AppStorage(AppFontSize.storageKey, store: AppSettings.defaults)
    private var fontPointSize = AppFontSize.defaultValue
    @AppStorage(AppSettings.notificationsEnabledKey, store: AppSettings.defaults)
    private var notificationsEnabled = false
    @AppStorage(AppSettings.tipsEnabledKey, store: AppSettings.defaults)
    private var tipsEnabled = true
    let detachPath: String
    let installation: InstallationStore
    /// App-level shared store: its event stream outlives this window, so
    /// notifications and the menu bar stay current after close.
    let store: SessionStore
    @ObservedObject var navigation: MainNavigation
    @ObservedObject var shortcuts: SessionShortcutRegistry
    @ObservedObject var notifications: SessionNotificationService
    @ObservedObject var tips: TipSession
    @ObservedObject var settingsNavigation: SettingsNavigation

    @State private var selectedID: String?
    @State private var shortcutAssignments: [SessionShortcutAssignment] = []

    private var selectedSession: Session? {
        store.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        Group {
// quality-coverage:begin ui-e2e-instrumentation
            if (installation.hasDistributionPayload
                    || installation.presentsUIE2EOnboarding)
                && installation.onboardingStep != .mainApp {
                OnboardingView(store: installation)
// quality-coverage:end ui-e2e-instrumentation
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
                            selectedID: $selectedID,
                            navigation: navigation,
                            shortcutAssignments: shortcutAssignments)
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
        .task(id: detachPath) {
            // The store outlives this window; rewire it to the active CLI and
            // keep notifications fed from the same event source. The
            // transition detector baselines on its first successful snapshot,
            // so historical sessions never fire as fresh notifications.
            store.onSnapshot = { [weak notifications, weak shortcuts] sessions in
                shortcuts?.reconcile(sessions)
                await notifications?.observe(sessions)
            }
            await store.configure(cli: ProcessDetachCLI(
                executable: URL(fileURLWithPath: detachPath)))
            await installation.bootstrap()
        }
        .task(id: notificationsEnabled) {
            guard AppSettings.uiE2E == nil else { return }
            await notifications.configure(enabled: notificationsEnabled)
        }
// quality-coverage:begin ui-e2e-instrumentation
        .task {
            await UIE2ETestDriver.runIfRequested(
                installation: installation,
                store: store,
                shortcuts: shortcuts)
        }
// quality-coverage:end ui-e2e-instrumentation
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                guard AppSettings.uiE2E == nil else { return }
                await store.resynchronize()
                await installation.refreshContext()
                await notifications.refreshAuthorizationStatus()
            }
        }
        // A menu-bar action can set the request before reopening this window.
        // Process the initial value as well as later changes so that request is
        // not lost while no RootView exists.
        .onChange(of: navigation.requestedSessionID, initial: true) { _, requested in
            guard let requested else { return }
            selectedID = requested
            navigation.requestedSessionID = nil
        }
        .onChange(of: store.sessions, initial: true) { _, sessions in
            shortcuts.reconcile(sessions)
        }
        .onReceive(shortcuts.$assignments) { assignments in
            shortcutAssignments = assignments
        }
// quality-coverage:begin ui-e2e-instrumentation
#if !DEBUG
        .background {
            if AppSettings.uiE2E != nil {
                UIE2EAccessibilityBridge(
                    store: store,
                    selectedID: selectedID)
                    .frame(width: 0, height: 0)
            }
        }
#endif
// quality-coverage:end ui-e2e-instrumentation
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("detach-dashboard")
    }
}
