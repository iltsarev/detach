import SwiftUI
import AppKit
import DetachKit

@MainActor
enum AppRuntimeActivationSequence {
    static func run(
        activatePayload: () async -> Void,
        activateSessionSource: () async -> Void
    ) async {
        await activatePayload()
        await activateSessionSource()
    }
}

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
    let sessionLogSnapshots: SessionLogSnapshotCache
    let terminalScreens: SessionTerminalScreenCache
    @ObservedObject var navigation: MainNavigation
    @ObservedObject var shortcuts: SessionShortcutRegistry
    @ObservedObject var notifications: SessionNotificationService
    @ObservedObject var tips: TipSession
    @ObservedObject var settingsNavigation: SettingsNavigation

    @State private var selectedID: String?
    @State private var shortcutAssignments: [SessionShortcutAssignment] = []
    @State private var initialSetupComplete = false

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
                            SessionDetailSwitcher(
                                session: session,
                                store: store,
                                detachPath: detachPath,
                                sessionLogSnapshots: sessionLogSnapshots,
                                terminalScreens: terminalScreens)
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
            initialSetupComplete = false
            installation.onPowerSnapshot = { [weak notifications] snapshot in
                await notifications?.observePower(snapshot)
            }
            installation.startPowerObservation()
            // The store outlives this window; rewire it to the active CLI and
            // keep notifications fed from the same event source. The
            // transition detector baselines on its first successful snapshot,
            // so historical sessions never fire as fresh notifications.
            store.onSnapshot = { [weak notifications] sessions in
                notifications?.observeFromSessionStore(sessions)
            }
            // Activate the immutable payload before starting any long-lived
            // source. Otherwise an upgrade leaves the app's watcher on the
            // previous payload until the whole app is restarted.
            await AppRuntimeActivationSequence.run(
                activatePayload: { await installation.bootstrap() },
                activateSessionSource: {
                    sessionLogSnapshots.configure(
                        cli: ProcessDetachCLI(
                            executable: URL(fileURLWithPath: detachPath)),
                        configurationID: detachPath,
                        sessions: store.sessions)
                    terminalScreens.configure(
                        cli: ProcessDetachCLI(
                            executable: URL(fileURLWithPath: detachPath)),
                        configurationID: detachPath,
                        sessions: store.sessions)
                    await store.configure(cli: ProcessDetachCLI(
                        executable: URL(fileURLWithPath: detachPath)))
                })
            initialSetupComplete = true
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
                sessionLogSnapshots: sessionLogSnapshots,
                shortcuts: shortcuts)
        }
// quality-coverage:end ui-e2e-instrumentation
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, initialSetupComplete else { return }
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
            // A cached presentation snapshot is already present on the first
            // body pass. Warm passive screens and logs while typed truth
            // refreshes; both caches remain bounded and leave no live process.
            sessionLogSnapshots.schedulePrefetch(for: sessions)
            terminalScreens.schedulePrefetch(for: sessions)
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

/// Keeps only the last passive terminal or log frame inside the new detail's
/// log surface until that target confirms its first drawable frame. The new
/// metadata and actions determine layout immediately, with no hidden PTY.
@MainActor
struct SessionDetailSwitcher: View {
    let session: Session
    let store: SessionStore
    let detachPath: String
    let sessionLogSnapshots: SessionLogSnapshotCache
    let terminalScreens: SessionTerminalScreenCache

    @State private var transition: SessionDetailTransitionState
    @State private var deadlineTask: Task<Void, Never>?

    init(
        session: Session,
        store: SessionStore,
        detachPath: String,
        sessionLogSnapshots: SessionLogSnapshotCache,
        terminalScreens: SessionTerminalScreenCache
    ) {
        self.session = session
        self.store = store
        self.detachPath = detachPath
        self.sessionLogSnapshots = sessionLogSnapshots
        self.terminalScreens = terminalScreens
        _transition = State(initialValue: SessionDetailTransitionState(
            presented: session))
    }

    var body: some View {
        SessionDetailView(
            session: transition.presented,
            store: store,
            detachPath: detachPath,
            terminalScreens: terminalScreens,
            cachedLog: cachedLog(for: transition.presented),
            retainedFrame: transition.outgoing.flatMap {
                transitionFrame(outgoing: $0)
            },
            onPresentationReady: {
                completeTransition(
                    sessionID: transition.presented.id,
                    generation: transition.generation)
            })
        .onChange(of: session) { _, updated in
            guard let generation = transition.present(updated) else { return }
            scheduleDeadline(
                sessionID: updated.id,
                generation: generation)
        }
        .onDisappear {
            deadlineTask?.cancel()
            deadlineTask = nil
        }
    }

    private func cachedLog(for layer: Session) -> LogPoller? {
        guard SessionLogSnapshotCache.shouldCache(layer) else { return nil }
        return sessionLogSnapshots.poller(for: layer)
    }

    private func retainedFrame(for layer: Session) -> SessionDetailRetainedFrame? {
        if SessionLogSnapshotCache.shouldCache(layer) {
            let attributed = sessionLogSnapshots.poller(for: layer).attributed
            return attributed.length > 0 ? .text(attributed) : nil
        }
        return nil
    }

    private func transitionFrame(
        outgoing: Session
    ) -> SessionDetailRetainedFrame? {
        let target = transition.presented
        // A non-live target already has its final NSTextView presentation.
        // A live target prefers a real SwiftTerm capture. If it has never been
        // shown, the outgoing live capture still has identical terminal
        // typography, colors, and edges while the target fallback mounts.
        if SessionLogSnapshotCache.shouldCache(target) {
            return retainedFrame(for: target) ?? retainedFrame(for: outgoing)
        }
        // A live target owns the same visible SwiftTerm across live switches,
        // or installs a passive SwiftTerm text screen inside a new PTY host.
        // Neither path needs a separate SwiftUI raster/text cover.
        return nil
    }

    private func completeTransition(sessionID: String, generation: UInt64) {
        guard sessionID == transition.presented.id,
              generation == transition.generation,
              transition.outgoing != nil else { return }
        // Draw the installed target hierarchy behind the retained passive
        // frame before state removes it. This keeps the handoff atomic at the
        // AppKit display boundary, not only in SwiftUI's logical tree.
        NSApp.mainWindow?.contentView?.layoutSubtreeIfNeeded()
        NSApp.mainWindow?.displayIfNeeded()
        _ = transition.complete(
            sessionID: sessionID,
            generation: generation)
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    private func scheduleDeadline(sessionID: String, generation: UInt64) {
        deadlineTask?.cancel()
        deadlineTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = transition.complete(
                sessionID: sessionID,
                generation: generation)
            deadlineTask = nil
        }
    }
}

struct SessionDetailTransitionState: Equatable {
    private(set) var presented: Session
    private(set) var outgoing: Session?
    private(set) var generation: UInt64 = 0

    mutating func present(_ session: Session) -> UInt64? {
        guard session.id != presented.id else {
            presented = session
            return nil
        }
        if outgoing == nil { outgoing = presented }
        presented = session
        generation &+= 1
        return generation
    }

    @discardableResult
    mutating func complete(
        sessionID: String,
        generation: UInt64
    ) -> Bool {
        guard sessionID == presented.id,
              generation == self.generation,
              outgoing != nil else { return false }
        outgoing = nil
        return true
    }
}
